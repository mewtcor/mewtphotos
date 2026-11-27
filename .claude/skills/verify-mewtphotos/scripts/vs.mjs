// Verification helper for MewtPhotos: run an isolated server, drive the phone API against it,
// capture evidence, tear down. Usage (from the repo root):
//   node .claude/skills/verify-mewtphotos/scripts/vs.mjs launch [--port 8899]
//   node .claude/skills/verify-mewtphotos/scripts/vs.mjs doctor
//   node .claude/skills/verify-mewtphotos/scripts/vs.mjs upload
//   node .claude/skills/verify-mewtphotos/scripts/vs.mjs stop
// State lives in .verify/ (gitignored). Evidence survives `stop`; everything else is removed.
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..', '..', '..', '..');
const verifyDir = path.join(root, '.verify');
const statePath = path.join(verifyDir, 'state.json');
const API = '/api/v1';
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const readState = () => {
  if (!existsSync(statePath)) fail('No instance launched by this skill (.verify/state.json missing). Run `launch` first.');
  return JSON.parse(readFileSync(statePath, 'utf8'));
};
function fail(msg) {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
}
const pidAlive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
const freePort = (preferred) =>
  new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', () => resolve(freePort(preferred + 1)));
    srv.listen(preferred, '127.0.0.1', () => srv.close(() => resolve(preferred)));
  });

async function call(state, method, url, { body, headers = {}, token, raw } = {}) {
  const h = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  if (body !== undefined && !raw) h['content-type'] = 'application/json';
  const res = await fetch(`http://127.0.0.1:${state.port}${url}`, {
    method,
    headers: h,
    body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {}
  return { status: res.status, json, text };
}

// A tiny valid JPEG whose bytes are unique per run (random COM segment), so a repeat run is never a duplicate.
function makeJpeg() {
  const base = Buffer.from(
    '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k=',
    'base64',
  );
  const comment = randomBytes(16);
  const com = Buffer.concat([Buffer.from([0xff, 0xfe, 0x00, comment.length + 2]), comment]);
  return Buffer.concat([base.subarray(0, 2), com, base.subarray(2)]);
}

async function launch(args) {
  if (existsSync(statePath)) {
    const old = JSON.parse(readFileSync(statePath, 'utf8'));
    if (pidAlive(old.pid)) fail(`An instance from this skill is already running (pid ${old.pid}, port ${old.port}). Run \`stop\` first.`);
    rmSync(statePath);
  }
  const wanted = Number(args[args.indexOf('--port') + 1]) || 8899;
  const port = await freePort(wanted);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const run = path.join(verifyDir, 'run');
  const data = path.join(run, 'data');
  const backup = path.join(run, 'backup');
  rmSync(run, { recursive: true, force: true });
  mkdirSync(data, { recursive: true });
  mkdirSync(backup, { recursive: true });
  const evidence = path.join(verifyDir, 'evidence', stamp);
  mkdirSync(evidence, { recursive: true });
  const out = openSync(path.join(evidence, 'server.out.log'), 'a');
  const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', 'server/main.ts', '--no-open'], {
    cwd: root,
    // MEWTPHOTOS_HOST='' keeps the server on loopback only: nothing is exposed to the LAN during verification.
    env: { ...process.env, MEWTPHOTOS_PORT: String(port), MEWTPHOTOS_DATA_DIR: data, MEWTPHOTOS_HOST: '' },
    stdio: ['ignore', out, out],
    detached: true,
    windowsHide: true,
  });
  child.unref();
  const state = { pid: child.pid, port, run, data, backup, evidence };
  writeFileSync(statePath, JSON.stringify(state, null, 2));
  for (let i = 0; i < 60; i++) {
    const h = await call(state, 'GET', `${API}/health`).catch(() => null);
    if (h?.json?.name === 'mewtphotos') break;
    if (!pidAlive(child.pid)) fail(`Server exited during startup. See ${path.join(evidence, 'server.out.log')}`);
    if (i === 59) fail('Server did not answer /health within 30s.');
    await sleep(500);
  }
  // Ready means usable: point the backup folder into the scratch dir and stop the app auto-stopping
  // when a dashboard tab closes (the browser drive would otherwise kill the server).
  const put = await call(state, 'PUT', `${API}/admin/settings`, { body: { destination: backup, stopWithDashboard: false } });
  if (put.status !== 200) fail(`Could not configure the instance: ${put.status} ${put.text}`);
  console.log(JSON.stringify({ ready: true, ...state, dashboard: `http://127.0.0.1:${port}/dashboard` }, null, 2));
}

async function doctor() {
  const state = readState();
  const problems = [];
  if (!pidAlive(state.pid)) problems.push(`pid ${state.pid} is not running`);
  const health = await call(state, 'GET', `${API}/health`).catch(() => null);
  if (health?.json?.name !== 'mewtphotos') problems.push(`port ${state.port} does not answer as mewtphotos`);
  const ov = await call(state, 'GET', `${API}/admin/overview`).catch(() => null);
  if (!ov || ov.status !== 200) problems.push('admin overview unavailable');
  else {
    if (path.resolve(ov.json.settings.destination) !== path.resolve(state.backup)) problems.push(`backup folder is ${ov.json.settings.destination}, expected ${state.backup} (not our instance?)`);
    if (ov.json.server.lanUrl) problems.push(`server is bound to the LAN (${ov.json.server.lanUrl}); relaunch so only loopback is exposed`);
  }
  if (problems.length) fail(problems.join('; '));
  console.log(JSON.stringify({ ok: true, pid: state.pid, port: state.port, files: ov.json.totals.files }, null, 2));
}

async function upload() {
  const state = readState();
  const steps = [];
  const check = (name, ok, detail) => {
    steps.push({ name, ok: !!ok, detail });
    if (!ok) {
      writeFileSync(path.join(state.evidence, 'upload.json'), JSON.stringify({ passed: false, steps }, null, 2));
      fail(`${name}: ${JSON.stringify(detail)}`);
    }
  };

  const pairing = await call(state, 'GET', `${API}/admin/pairing`);
  check('read pairing code from admin', pairing.status === 200 && pairing.json.code, pairing.status);
  const pair = await call(state, 'POST', `${API}/pair`, { body: { code: pairing.json.code, deviceName: 'verify-mewtphotos' } });
  check('pair a device', pair.status === 200 && pair.json.token, pair.json);
  const token = pair.json.token;

  const session = await call(state, 'POST', `${API}/sessions`, { token, body: { method: 'native', selectedCount: 1 } });
  check('create session', session.status === 200, session.json);
  const sessionId = session.json.id;

  const jpeg = makeJpeg();
  const hash = sha256(jpeg);
  const filename = `verify-${hash.slice(0, 8)}.jpg`;
  const created = await call(state, 'POST', `${API}/uploads`, { token, body: { sessionId, filename, size: jpeg.length, mimeType: 'image/jpeg' } });
  check('create upload', created.status === 200 && created.json.status === 'receiving', created.json);
  const uploadId = created.json.uploadId;
  const patched = await call(state, 'PATCH', `${API}/uploads/${uploadId}`, {
    token,
    raw: true,
    body: jpeg,
    headers: { 'content-type': 'application/offset+octet-stream', 'upload-offset': '0' },
  });
  check('send bytes', patched.status === 200 && patched.json.offset === jpeg.length, patched.json);
  const finished = await call(state, 'POST', `${API}/uploads/${uploadId}/finish`, { token, body: { sha256: hash } });
  check('server returns verified', finished.status === 200 && finished.json.status === 'verified' && finished.json.sha256 === hash && finished.json.endToEndVerified === true, finished.json);

  // Side effects, not just the response: the file is on disk inside the backup folder with the same hash.
  const stored = finished.json.path;
  const inside = path.resolve(stored).startsWith(path.resolve(state.backup) + path.sep);
  check('file placed inside the backup folder', inside && existsSync(stored), stored);
  check('stored bytes hash to the original', sha256(readFileSync(stored)) === hash && statSync(stored).size === jpeg.length, stored);
  const known = await call(state, 'GET', `${API}/files/${hash}`, { token });
  check('server knows the hash', known.json?.known === true, known.json);

  // Same content in a NEW session must be reported duplicate, never as a second verified copy.
  // (Re-announcing a hash inside the same session is an idempotent replay and is not counted.)
  const session2 = await call(state, 'POST', `${API}/sessions`, { token, body: { method: 'native', selectedCount: 1 } });
  check('create second session', session2.status === 200, session2.json);
  const again = await call(state, 'POST', `${API}/uploads`, { token, body: { sessionId: session2.json.id, filename: `copy-${filename}`, size: jpeg.length, sha256: hash } });
  check('repeat upload is a duplicate', again.status === 200 && again.json.status === 'duplicate', again.json);
  const complete2 = await call(state, 'POST', `${API}/sessions/${session2.json.id}/complete`, { token, body: {} });
  check('complete second session', complete2.status === 200 && complete2.json.duplicates === 1, complete2.json);

  const complete = await call(state, 'POST', `${API}/sessions/${sessionId}/complete`, { token, body: {} });
  check('complete session', complete.status === 200, complete.json);
  const ov = await call(state, 'GET', `${API}/admin/overview`);
  check('overview counts one file, one duplicate, no failures', ov.json.totals.files === 1 && ov.json.totals.duplicates === 1 && ov.json.totals.failed === 0, ov.json.totals);

  const evidence = { passed: true, filename, sha256: hash, storedPath: stored, session: complete.json, totals: ov.json.totals, steps };
  writeFileSync(path.join(state.evidence, 'upload.json'), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify({ passed: true, evidence: path.join(state.evidence, 'upload.json'), totals: ov.json.totals }, null, 2));
}

async function stop() {
  if (!existsSync(statePath)) {
    console.log('Nothing to stop.');
    return;
  }
  const state = JSON.parse(readFileSync(statePath, 'utf8'));
  // Only the pid we started. Never kill by process name: the user's real backup app is also "node".
  if (pidAlive(state.pid)) {
    await call(state, 'POST', `${API}/admin/shutdown`).catch(() => null);
    for (let i = 0; i < 20 && pidAlive(state.pid); i++) await sleep(250);
    if (pidAlive(state.pid)) {
      try {
        process.kill(state.pid);
      } catch {}
      for (let i = 0; i < 20 && pidAlive(state.pid); i++) await sleep(250);
    }
  }
  if (pidAlive(state.pid)) fail(`pid ${state.pid} still running; end it manually.`);
  rmSync(state.run, { recursive: true, force: true }); // scratch data + backup folder; evidence stays
  rmSync(statePath, { force: true });
  console.log(JSON.stringify({ stopped: true, evidenceKept: state.evidence }, null, 2));
}

const [cmd, ...rest] = process.argv.slice(2);
const commands = { launch, doctor, upload, stop };
if (!commands[cmd]) fail(`usage: vs.mjs ${Object.keys(commands).join('|')}`);
await commands[cmd](rest);
