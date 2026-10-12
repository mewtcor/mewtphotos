import { createHash, randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { API, COVERAGE_NOTICE, UPLOAD_CONTENT_TYPE, type Overview, type SessionSummary } from '../shared/schemas.ts';
import { autoStop } from '../server/app.ts';
import { get, run, type UploadRow } from '../server/db.ts';
import { recover, timeouts } from '../server/engine.ts';
import { verifyBackup } from '../server/verify.ts';
import { PHONE_IP, rawRequest, sha256, startServer, type TestServer } from './helpers.ts';

const open: TestServer[] = [];
async function server(...args: Parameters<typeof startServer>): Promise<TestServer> {
  const s = await startServer(...args);
  open.push(s);
  return s;
}
afterEach(async () => {
  for (const s of open.splice(0)) {
    await s.app.close();
    try {
      s.db.close();
    } catch {
      // already closed by the test
    }
    await rm(s.root, { recursive: true, force: true });
  }
});

/** Files in the backup folder, excluding in-progress temp data. */
async function stored(dest: string): Promise<string[]> {
  const out: string[] = [];
  const walk = async (dir: string, prefix: string) => {
    for (const e of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
      if (e.name === '.incoming') continue;
      if (e.isDirectory()) await walk(path.join(dir, e.name), `${prefix}${e.name}/`);
      else out.push(prefix + e.name);
    }
  };
  await walk(dest, '');
  return out.sort();
}
const chunkHeaders = (offset: number) => ({ 'content-type': UPLOAD_CONTENT_TYPE, 'upload-offset': String(offset) });

describe('uploading', () => {
  it('stores a file byte-for-byte and reports it verified end to end', async () => {
    const s = await server();
    const data = randomBytes(300_000);
    const res = await s.upload(await s.newSession(), 'IMG_0001.HEIC', data);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'verified', sha256: sha256(data), endToEndVerified: true });
    expect(await readFile(path.join(s.dest, 'IMG_0001.HEIC'))).toEqual(data);
    expect(existsSync(res.body.path)).toBe(true);
  });

  it('marks a file as server-hashed only when the sender gives no hash', async () => {
    const s = await server();
    const res = await s.upload(await s.newSession(), 'a.jpg', randomBytes(1000), { claimSha: null });
    expect(res.body).toMatchObject({ status: 'verified', endToEndVerified: false });
  });

  it('rejects a corrupted upload and stores nothing', async () => {
    const s = await server();
    const session = await s.newSession();
    const res = await s.upload(session, 'a.jpg', randomBytes(5000), { claimSha: sha256(Buffer.from('something else')) });
    expect(res.status).toBe(422);
    expect(res.body.error).toBe('hash_mismatch');
    expect(await stored(s.dest)).toEqual([]);
    expect(await readdir(path.join(s.dest, '.incoming'))).toEqual([]);
    const summary = (await s.phone({ method: 'GET', url: `${API}/sessions/${session}` })).json() as SessionSummary;
    expect(summary).toMatchObject({ failed: 1, verified: 0 });
    expect(summary.message).not.toBe(COVERAGE_NOTICE);
  });

  it('detects duplicate content regardless of filename and keeps one copy', async () => {
    const s = await server();
    const session = await s.newSession(2);
    const data = randomBytes(40_000);
    const first = await s.upload(session, 'IMG_1.JPG', data);
    const second = await s.upload(session, 'renamed-copy.jpg', data);
    expect(second.body).toMatchObject({ status: 'duplicate', path: first.body.path });
    expect(await stored(s.dest)).toEqual(['IMG_1.JPG']);
    const summary = (await s.phone({ method: 'GET', url: `${API}/sessions/${session}` })).json() as SessionSummary;
    expect(summary).toMatchObject({ verified: 1, duplicates: 1, failed: 0 });
  });

  it('skips the transfer entirely when the sender announces a known hash', async () => {
    const s = await server();
    const session = await s.newSession();
    const data = randomBytes(2000);
    await s.upload(session, 'a.jpg', data);
    const res = await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: session, filename: 'b.jpg', size: data.length, sha256: sha256(data) } });
    expect(res.json()).toMatchObject({ status: 'duplicate' });
    expect(await readdir(path.join(s.dest, '.incoming'))).toEqual([]); // no transfer was even started
  });

  it('answers "do you already have this?" by hash, and stops saying yes once the file is gone', async () => {
    const s = await server();
    const data = randomBytes(2000);
    const check = async (hash: string) => (await s.phone({ method: 'GET', url: `${API}/files/${hash}` })).json() as { known: boolean };
    expect(await check(sha256(data))).toEqual({ known: false, status: 'missing' });
    const stored = await s.upload(await s.newSession(), 'a.jpg', data);
    expect(await check(sha256(data).toUpperCase())).toEqual({ known: true, status: 'stored', path: stored.body.path });
    await rm(stored.body.path);
    expect(await check(sha256(data))).toEqual({ known: false, status: 'missing' });
    expect((await s.phone({ method: 'GET', url: `${API}/files/not-a-hash` })).statusCode).toBe(400);
  });

  it('stores the file again if the earlier copy was deleted from disk', async () => {
    const s = await server();
    const session = await s.newSession();
    const data = randomBytes(3000);
    const first = await s.upload(session, 'a.jpg', data);
    await rm(first.body.path);
    const again = await s.upload(session, 'a.jpg', data);
    expect(again.body.status).toBe('verified');
    expect(await readFile(again.body.path)).toEqual(data);
  });

  it('keeps both files when the same filename has different contents', async () => {
    const s = await server();
    const session = await s.newSession(3);
    const [a, b, c] = [randomBytes(1000), randomBytes(1000), randomBytes(1234)];
    await s.upload(session, 'image.jpg', a);
    await s.upload(session, 'image.jpg', b);
    await s.upload(session, 'IMAGE.JPG', c); // Windows filenames are case-insensitive
    expect((await stored(s.dest)).map((n) => n.toLowerCase()).sort()).toEqual(['image (2).jpg', 'image (3).jpg', 'image.jpg']);
    expect(await readFile(path.join(s.dest, 'image.jpg'))).toEqual(a);
    expect(await readFile(path.join(s.dest, 'image (2).jpg'))).toEqual(b);
  });

  it('never overwrites a file that was already in the folder', async () => {
    const s = await server();
    const precious = Buffer.from('an existing file the app knows nothing about');
    await s.upload(await s.newSession(), 'warmup.jpg', randomBytes(10)); // creates the folder
    await writeFile(path.join(s.dest, 'IMG_9.jpg'), precious);
    await s.upload(await s.newSession(), 'IMG_9.jpg', randomBytes(500));
    expect(await readFile(path.join(s.dest, 'IMG_9.jpg'))).toEqual(precious);
    expect(await stored(s.dest)).toContain('IMG_9 (2).jpg');
  });

  it('rejects unsupported file types', async () => {
    const s = await server();
    const res = await s.upload(await s.newSession(), 'malware.exe', randomBytes(100));
    expect(res.status).toBe(415);
    expect(await stored(s.dest)).toEqual([]);
  });

  it('confines hostile filenames to the backup folder', async () => {
    const s = await server();
    const res = await s.upload(await s.newSession(), '..\\..\\..\\escape.jpg', randomBytes(100));
    expect(res.status).toBe(200);
    expect(await stored(s.dest)).toEqual(['escape.jpg']);
    expect(existsSync(path.join(s.root, 'escape.jpg'))).toBe(false);
    // upload ids are validated too
    const bad = await s.phone({ method: 'GET', url: `${API}/uploads/..%2F..%2Fsecret` });
    expect(bad.statusCode).toBe(400);
  });

  it('refuses files over the size limit, over quota, or when the disk is full', async () => {
    const big = await server({ maxFileBytes: 1000 });
    expect((await big.upload(await big.newSession(), 'a.jpg', randomBytes(2000))).status).toBe(413);

    const quota = await server({ quotaBytes: 1500 });
    const session = await quota.newSession();
    expect((await quota.upload(session, 'a.jpg', randomBytes(1000))).status).toBe(200);
    expect((await quota.upload(session, 'b.jpg', randomBytes(1000))).status).toBe(507);

    const full = await server({ minFreeBytes: 500 }, { freeBytes: async () => 1200 });
    const res = await full.upload(await full.newSession(), 'a.jpg', randomBytes(1000));
    expect(res.status).toBe(507);
    expect(res.body.error).toBe('insufficient_space');
    expect(await stored(full.dest)).toEqual([]);
    const overview = (await full.app.inject({ method: 'GET', url: `${API}/admin/overview` })).json() as Overview;
    expect(overview.logs.some((l) => l.code === 'insufficient_space')).toBe(true);
  });

  it('organises by embedded capture date, with a recorded fallback', async () => {
    const s = await server({ organizeByDate: true });
    const session = await s.newSession(3);

    // MOV: ftyp + moov/mvhd with a creation time
    const atom = (type: string, body: Buffer) => {
      const head = Buffer.alloc(8);
      head.writeUInt32BE(body.length + 8, 0);
      head.write(type, 4, 'latin1');
      return Buffer.concat([head, body]);
    };
    const mvhd = Buffer.alloc(100);
    mvhd.writeUInt32BE(Date.UTC(2023, 5, 15, 12) / 1000 + 2082844800, 4);
    const mov = Buffer.concat([atom('ftyp', Buffer.from('qt  ')), atom('mdat', randomBytes(500)), atom('moov', atom('mvhd', mvhd))]);
    expect((await s.upload(session, 'clip.MOV', mov)).body.path).toContain(path.join('2023', '06', 'clip.MOV'));

    // JPEG: SOI + APP1/Exif with DateTimeOriginal + EOI
    const tiff = Buffer.alloc(8 + 18 + 18 + 20);
    tiff.write('II*\0', 0, 'latin1');
    tiff.writeUInt32LE(8, 4);
    tiff.writeUInt16LE(1, 8); // IFD0: one entry -> Exif IFD pointer
    tiff.writeUInt16LE(0x8769, 10); tiff.writeUInt16LE(4, 12); tiff.writeUInt32LE(1, 14); tiff.writeUInt32LE(26, 18);
    tiff.writeUInt16LE(1, 26); // Exif IFD: one entry -> DateTimeOriginal
    tiff.writeUInt16LE(0x9003, 28); tiff.writeUInt16LE(2, 30); tiff.writeUInt32LE(20, 32); tiff.writeUInt32LE(44, 36);
    tiff.write('2021:11:03 08:09:10\0', 44, 'latin1');
    const app1 = Buffer.concat([Buffer.from('Exif\0\0', 'latin1'), tiff]);
    const len = Buffer.alloc(2);
    len.writeUInt16BE(app1.length + 2);
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe1]), len, app1, Buffer.from([0xff, 0xd9])]);
    const photo = await s.upload(session, 'photo.jpg', jpeg);
    expect(photo.body.path).toContain(path.join('2021', '11', 'photo.jpg'));
    expect(await readFile(photo.body.path)).toEqual(jpeg); // organising never alters content

    // No metadata: falls back to the sender's modification time, and says so
    const plain = await s.upload(session, 'plain.png', randomBytes(64), { lastModified: Date.UTC(2019, 0, 20, 12) });
    expect(plain.body.path).toContain(path.join('2019', '01', 'plain.png'));
    const sources = Object.fromEntries(s.db.prepare('SELECT original_name, date_source FROM files').all().map((r) => [r.original_name, r.date_source]));
    expect(sources).toEqual({ 'clip.MOV': 'quicktime', 'photo.jpg': 'exif', 'plain.png': 'file-modified' });
  });
});

describe('interrupted transfers', () => {
  it('does not treat a partial upload as a backup, and resumes it', async () => {
    const s = await server();
    const session = await s.newSession();
    const data = randomBytes(100_000);
    const create = { sessionId: session, filename: 'video.mov', size: data.length, lastModified: 1_700_000_000_000 };
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: create })).json() as { uploadId: string };
    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(0, 40_000), headers: chunkHeaders(0) });

    const early = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: {} });
    expect(early.statusCode).toBe(409);
    expect(early.json()).toMatchObject({ error: 'incomplete', offset: 40_000 });
    expect(await stored(s.dest)).toEqual([]);

    // a wrong offset is refused and tells the client where to continue
    const wrong = await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(50_000), headers: chunkHeaders(50_000) });
    expect(wrong.statusCode).toBe(409);
    expect(wrong.json()).toMatchObject({ error: 'offset_mismatch', offset: 40_000 });

    // re-selecting the same file (even in a new session) finds the partial upload
    const again = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { ...create, sessionId: await s.newSession() } })).json();
    expect(again).toMatchObject({ uploadId, offset: 40_000 });

    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(40_000), headers: chunkHeaders(40_000) });
    const done = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(done.json()).toMatchObject({ status: 'verified', endToEndVerified: true });
    expect(await readFile(path.join(s.dest, 'video.mov'))).toEqual(data);
  });

  it('rejects more data than the declared size', async () => {
    const s = await server();
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'a.jpg', size: 100 } })).json() as { uploadId: string };
    const res = await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: randomBytes(500), headers: chunkHeaders(0) });
    expect(res.statusCode).toBe(413);
  });

  it('makes finishing and retrying safe to repeat', async () => {
    const s = await server();
    const session = await s.newSession();
    const data = randomBytes(9000);
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: session, filename: 'a.jpg', size: data.length } })).json() as { uploadId: string };
    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data, headers: chunkHeaders(0) });
    const finish = () => s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: {} });
    const [first, second] = [await finish(), await finish()]; // e.g. the first response was lost
    expect(second.json()).toEqual(first.json());
    expect(await stored(s.dest)).toEqual(['a.jpg']);

    // a failed attempt followed by a successful retry leaves the session clean
    const other = randomBytes(700);
    expect((await s.upload(session, 'b.jpg', other, { claimSha: sha256(Buffer.from('x')) })).status).toBe(422);
    expect((await s.upload(session, 'b.jpg', other)).status).toBe(200);
    const summary = (await s.phone({ method: 'GET', url: `${API}/sessions/${session}` })).json() as SessionSummary;
    expect(summary).toMatchObject({ verified: 2, failed: 0 });
  });

  it('keeps received bytes when the connection drops mid-chunk', async () => {
    const s = await server();
    const port = await s.listen();
    const data = randomBytes(4 * 1024 * 1024);
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'cut.mp4', size: data.length } })).json() as { uploadId: string };

    await rawRequest(port, { method: 'PATCH', path: `${API}/uploads/${uploadId}`, headers: { authorization: `Bearer ${s.token}`, ...chunkHeaders(0), 'content-length': data.length } }, (req) => {
      req.write(data.subarray(0, 1024 * 1024));
      setTimeout(() => req.destroy(), 300);
    }).catch(() => undefined);
    await new Promise((r) => setTimeout(r, 300));

    const state = (await s.phone({ method: 'GET', url: `${API}/uploads/${uploadId}` })).json() as { offset: number; status: string };
    expect(state.status).toBe('receiving');
    expect(state.offset).toBeLessThan(data.length);
    expect(await stored(s.dest)).toEqual([]);

    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(state.offset), headers: chunkHeaders(state.offset) });
    const done = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(done.json()).toMatchObject({ status: 'verified' });
    const overview = (await s.app.inject({ method: 'GET', url: `${API}/admin/overview` })).json() as Overview;
    expect(overview.logs.some((l) => l.code === 'client_disconnected')).toBe(true);
  });

  it('asks the phone to wait while the earlier attempt is still open, then resumes it', async () => {
    const s = await server();
    const port = await s.listen();
    const data = randomBytes(50_000);
    const create = { sessionId: await s.newSession(), filename: 'busy.jpg', size: data.length, lastModified: 1_700_000_000_000 };
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: create })).json() as { uploadId: string };
    timeouts.chunkIdleMs = 500;
    try {
      const stalled = rawRequest(port, { method: 'PATCH', path: `${API}/uploads/${uploadId}`, headers: { authorization: `Bearer ${s.token}`, ...chunkHeaders(0), 'content-length': data.length } }, (req) => {
        req.write(data.subarray(0, 10_000));
      }).catch(() => undefined);
      await new Promise((resolve) => setTimeout(resolve, 100));
      const busy = await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { ...create, sessionId: await s.newSession() } });
      expect(busy.statusCode).toBe(409);
      expect(busy.json()).toMatchObject({ error: 'upload_busy' });
      await stalled;
    } finally {
      timeouts.chunkIdleMs = 60_000;
    }
    const again = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: create })).json();
    expect(again).toMatchObject({ uploadId, offset: 10_000 });
  });

  it('abandons a stalled chunk, logs a timeout, and lets it resume', async () => {
    const s = await server();
    const port = await s.listen();
    const data = randomBytes(50_000);
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'slow.jpg', size: data.length } })).json() as { uploadId: string };
    timeouts.chunkIdleMs = 250;
    try {
      // sends part of the chunk, then goes silent without closing the connection
      await rawRequest(port, { method: 'PATCH', path: `${API}/uploads/${uploadId}`, headers: { authorization: `Bearer ${s.token}`, ...chunkHeaders(0), 'content-length': data.length } }, (req) => {
        req.write(data.subarray(0, 10_000));
      }).catch(() => undefined);
    } finally {
      timeouts.chunkIdleMs = 60_000;
    }
    const overview = (await s.app.inject({ method: 'GET', url: `${API}/admin/overview` })).json() as Overview;
    expect(overview.logs.some((l) => l.code === 'upload_timeout')).toBe(true);
    const state = (await s.phone({ method: 'GET', url: `${API}/uploads/${uploadId}` })).json() as { offset: number; status: string };
    expect(state).toMatchObject({ status: 'receiving', offset: 10_000 });
    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(state.offset), headers: chunkHeaders(state.offset) });
    const done = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(done.json()).toMatchObject({ status: 'verified' });
  });

  it('tells a real client why a chunk was refused instead of dropping the connection', async () => {
    const s = await server();
    const port = await s.listen();
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'a.jpg', size: 100 } })).json() as { uploadId: string };
    const res = await rawRequest(port, { method: 'PATCH', path: `${API}/uploads/${uploadId}`, headers: { authorization: `Bearer ${s.token}`, ...chunkHeaders(0), 'content-length': 300_000 } }, (req) => {
      req.end(randomBytes(300_000));
    });
    expect(res.status).toBe(413);
    expect(JSON.parse(res.body)).toMatchObject({ error: 'too_much_data' });
  });

  it('streams a large file in one request without corrupting it', async () => {
    const s = await server();
    const port = await s.listen();
    const total = 96 * 1024 * 1024;
    const piece = randomBytes(1024 * 1024);
    const hash = createHash('sha256');
    const rssBefore = process.memoryUsage().rss;
    const res = await rawRequest(port, { method: 'POST', path: `${API}/files?filename=big.mov`, headers: { authorization: `Bearer ${s.token}`, 'content-type': 'video/quicktime', 'content-length': total } }, async (req) => {
      for (let sent = 0; sent < total; sent += piece.length) {
        hash.update(piece);
        if (!req.write(piece)) await new Promise((r) => req.once('drain', r));
      }
      req.end();
    });
    expect(res.status).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ status: 'verified', sha256: hash.digest('hex') });
    // bounded memory: the 96 MB body must not have been buffered
    expect(process.memoryUsage().rss - rssBefore).toBeLessThan(64 * 1024 * 1024);
  });

  it('fails a one-shot upload that ends early, storing nothing', async () => {
    const s = await server();
    const port = await s.listen();
    await rawRequest(port, { method: 'POST', path: `${API}/files?filename=cut.jpg`, headers: { authorization: `Bearer ${s.token}`, 'content-type': 'image/jpeg', 'content-length': 500_000 } }, (req) => {
      req.write(randomBytes(100_000));
      setTimeout(() => req.destroy(), 200);
    }).catch(() => undefined);
    await new Promise((r) => setTimeout(r, 300));
    expect(await stored(s.dest)).toEqual([]);
    expect(get<{ status: string }>(s.db, 'SELECT status FROM uploads')?.status).toBe('failed');
  });
});

describe('restarts and recovery', () => {
  it('survives a server shutdown in the middle of a transfer', async () => {
    const s = await server();
    const port = await s.listen();
    const data = randomBytes(6 * 1024 * 1024);
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'movie.mov', size: data.length } })).json() as { uploadId: string };
    const inFlight = rawRequest(port, { method: 'PATCH', path: `${API}/uploads/${uploadId}`, headers: { authorization: `Bearer ${s.token}`, ...chunkHeaders(0), 'content-length': data.length } }, (req) => {
      req.write(data.subarray(0, 2 * 1024 * 1024));
    }).catch(() => undefined);
    await new Promise((r) => setTimeout(r, 300));
    await s.app.close(); // server stops while the phone is still sending
    await inFlight;
    expect(await stored(s.dest)).toEqual([]);

    const s2 = await server({}, {}, s); // same database and folder, fresh process state
    const state = (await s2.phone({ method: 'GET', url: `${API}/uploads/${uploadId}` })).json() as { offset: number; status: string };
    expect(state.status).toBe('receiving');
    await s2.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data.subarray(state.offset), headers: chunkHeaders(state.offset) });
    const done = await s2.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(done.json()).toMatchObject({ status: 'verified', endToEndVerified: true });
    expect(await readFile(path.join(s2.dest, 'movie.mov'))).toEqual(data);
  });

  async function receivedButNotFinished(s: TestServer, name: string, data: Buffer): Promise<UploadRow> {
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: name, size: data.length } })).json() as { uploadId: string };
    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data, headers: chunkHeaders(0) });
    return get<UploadRow>(s.db, 'SELECT * FROM uploads WHERE id = ?', uploadId)!;
  }
  const status = (s: TestServer, id: string) => get<{ status: string }>(s.db, 'SELECT status FROM uploads WHERE id = ?', id)!.status;

  it('completes the record when a crash hit after the file was placed but before the commit', async () => {
    const s = await server();
    const data = randomBytes(5000);
    const row = await receivedButNotFinished(s, 'a.jpg', data);
    const final = path.join(s.dest, 'a.jpg');
    run(s.db, `UPDATE uploads SET status = 'finalizing', final_path = ?, sha256 = ? WHERE id = ?`, final, sha256(data), row.id);
    await rename(row.temp_path, final);

    await recover(s.ctx);
    expect(status(s, row.id)).toBe('verified');
    expect(get<{ path: string }>(s.db, 'SELECT path FROM files WHERE sha256 = ?', sha256(data))?.path).toBe(final);
    expect((await verifyBackup(s.db, s.dest)).databaseProblems).toEqual([]);
  });

  it('rolls back to resumable when a crash hit before the file was placed', async () => {
    const s = await server();
    const data = randomBytes(5000);
    const row = await receivedButNotFinished(s, 'a.jpg', data);
    run(s.db, `UPDATE uploads SET status = 'finalizing', final_path = ?, sha256 = ? WHERE id = ?`, path.join(s.dest, 'a.jpg'), sha256(data), row.id);

    await recover(s.ctx);
    expect(status(s, row.id)).toBe('receiving');
    const done = await s.phone({ method: 'POST', url: `${API}/uploads/${row.id}/finish`, payload: { sha256: sha256(data) } });
    expect(done.json()).toMatchObject({ status: 'verified' });
  });

  it('marks the upload failed if the placed file does not match after a crash', async () => {
    const s = await server();
    const data = randomBytes(5000);
    const row = await receivedButNotFinished(s, 'a.jpg', data);
    const final = path.join(s.dest, 'a.jpg');
    run(s.db, `UPDATE uploads SET status = 'finalizing', final_path = ?, sha256 = ? WHERE id = ?`, final, sha256(data), row.id);
    await rm(row.temp_path);
    await writeFile(final, data.subarray(0, 100)); // torn write

    await recover(s.ctx);
    expect(status(s, row.id)).toBe('failed');
    expect(get(s.db, 'SELECT id FROM files')).toBeUndefined();
  });

  it('cleans up orphaned temp files and keeps earlier backups untouched across restarts', async () => {
    const s = await server();
    const data = randomBytes(2000);
    await s.upload(await s.newSession(), 'keep.jpg', data);
    await writeFile(path.join(s.dest, '.incoming', '00000000-0000-4000-8000-000000000000.part'), 'junk');
    await s.app.close();
    const s2 = await server({}, {}, s);
    expect(await readdir(path.join(s2.dest, '.incoming'))).toEqual([]);
    expect(await readFile(path.join(s2.dest, 'keep.jpg'))).toEqual(data);
    const report = await verifyBackup(s2.db, s2.dest);
    expect(report).toMatchObject({ checked: 1, ok: 1, missing: [], corrupt: [], databaseProblems: [] });
  });
});

describe('verification', () => {
  it('finds corrupted, missing and untracked files', async () => {
    const s = await server();
    const session = await s.newSession(3);
    const good = await s.upload(session, 'good.jpg', randomBytes(4000));
    const flipped = await s.upload(session, 'flipped.jpg', randomBytes(4000));
    const gone = await s.upload(session, 'gone.jpg', randomBytes(4000));

    const bytes = await readFile(flipped.body.path);
    bytes[2000] = bytes[2000]! ^ 0xff; // same size, one byte changed
    await writeFile(flipped.body.path, bytes);
    await rm(gone.body.path);
    await writeFile(path.join(s.dest, 'stray.jpg'), 'copied in by hand');

    const report = await verifyBackup(s.db, s.dest);
    expect(report).toMatchObject({ checked: 3, ok: 1, corrupt: [flipped.body.path], missing: [gone.body.path], untracked: [path.join(s.dest, 'stray.jpg')] });
    expect(existsSync(good.body.path)).toBe(true);

    // a damaged copy is not accepted as "already backed up"
    const again = await s.upload(session, 'flipped.jpg', Buffer.from(bytes.map((b, i) => (i === 2000 ? b ^ 0xff : b))));
    expect(again.body.status).toBe('verified');
    expect(again.body.path).not.toBe(flipped.body.path);
  });

  it('runs from the dashboard and stores the report', async () => {
    const s = await server();
    await s.upload(await s.newSession(), 'a.jpg', randomBytes(100));
    expect((await s.app.inject({ method: 'POST', url: `${API}/admin/verify` })).statusCode).toBe(202);
    let overview: Overview;
    do {
      await new Promise((r) => setTimeout(r, 20));
      overview = (await s.app.inject({ method: 'GET', url: `${API}/admin/overview` })).json();
    } while (overview.verifyRunning);
    expect(overview.lastVerify).toMatchObject({ checked: 1, ok: 1 });
  });
});

describe('completeness reporting', () => {
  it('reports success for the selection without ever claiming whole-library coverage', async () => {
    const s = await server();
    const session = await s.newSession(2);
    await s.upload(session, 'a.jpg', randomBytes(10));
    let summary = (await s.phone({ method: 'GET', url: `${API}/sessions/${session}` })).json() as SessionSummary;
    expect(summary).toMatchObject({ selected: 2, submitted: 1, verified: 1, libraryCount: null, libraryCoverageVerified: false });
    expect(summary.message).toContain('1 of 2 selected files');
    expect(summary.message).toContain('1 never reached this computer');

    await s.upload(session, 'b.jpg', randomBytes(10));
    summary = (await s.phone({ method: 'POST', url: `${API}/sessions/${session}/complete`, payload: {} })).json() as SessionSummary;
    expect(summary.message).toBe(COVERAGE_NOTICE);
    expect(summary.libraryCoverageVerified).toBe(false);

    summary = (await s.phone({ method: 'POST', url: `${API}/sessions/${session}/complete`, payload: { unavailableCount: 1 } })).json() as SessionSummary;
    expect(summary.message).toContain('1 could not be read on the iPhone');
  });
});

describe('access control', () => {
  it('requires a paired device token', async () => {
    const s = await server();
    const anon = await s.app.inject({ method: 'POST', url: `${API}/sessions`, remoteAddress: PHONE_IP, payload: { method: 'safari', selectedCount: 1 } });
    expect(anon.statusCode).toBe(401);
    const forged = await s.phone({ method: 'GET', url: `${API}/status`, headers: { authorization: 'Bearer not-a-real-token' } });
    expect(forged.statusCode).toBe(401);
    expect((await s.phone({ method: 'GET', url: `${API}/status` })).statusCode).toBe(200);
  });

  it('pairs only with the current code and stores only a hash of the token', async () => {
    const s = await server();
    const bad = await s.app.inject({ method: 'POST', url: `${API}/pair`, remoteAddress: PHONE_IP, payload: { code: 'NOPE1234', deviceName: 'x' } });
    expect(bad.statusCode).toBe(403);
    expect(JSON.stringify(s.db.prepare('SELECT * FROM devices').all())).not.toContain(s.token);
    expect(JSON.stringify(s.db.prepare('SELECT * FROM logs').all())).not.toContain(s.token);
  });

  it('stops a removed device from uploading', async () => {
    const s = await server();
    const { id } = get<{ id: string }>(s.db, 'SELECT id FROM devices')!;
    expect((await s.app.inject({ method: 'DELETE', url: `${API}/admin/devices/${id}` })).statusCode).toBe(200);
    expect((await s.phone({ method: 'GET', url: `${API}/status` })).statusCode).toBe(401);
  });

  it("keeps one device out of another device's uploads", async () => {
    const s = await server();
    const { uploadId } = (await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId: await s.newSession(), filename: 'a.jpg', size: 10 } })).json() as { uploadId: string };
    const pair = await s.app.inject({ method: 'POST', url: `${API}/pair`, remoteAddress: '192.168.1.77', payload: { code: s.pairing.current().code, deviceName: 'Other phone' } });
    const other = (pair.json() as { token: string }).token;
    const res = await s.app.inject({ method: 'GET', url: `${API}/uploads/${uploadId}`, remoteAddress: '192.168.1.77', headers: { authorization: `Bearer ${other}` } });
    expect(res.statusCode).toBe(404);
  });

  it('serves the dashboard API to this computer only', async () => {
    const s = await server();
    expect((await s.app.inject({ method: 'GET', url: `${API}/admin/overview` })).statusCode).toBe(200);
    for (const url of ['overview', 'pairing', 'events']) {
      expect((await s.phone({ method: 'GET', url: `${API}/admin/${url}` })).statusCode, url).toBe(403);
    }
    expect((await s.phone({ method: 'PUT', url: `${API}/admin/settings`, payload: { destination: 'C:\\' } })).statusCode).toBe(403);
    // DNS-rebinding style request: loopback socket but a foreign Host header
    const rebound = await s.app.inject({ method: 'GET', url: `${API}/admin/overview`, headers: { host: 'evil.example:8787' } });
    expect(rebound.statusCode).toBe(403);
  });

  it('refuses the public internet and cross-origin browser requests', async () => {
    const s = await server();
    expect((await s.app.inject({ method: 'GET', url: `${API}/health`, remoteAddress: '203.0.113.9' })).statusCode).toBe(403);
    const csrf = await s.app.inject({ method: 'PUT', url: `${API}/admin/settings`, headers: { origin: 'https://evil.example' }, payload: { organizeByDate: false } });
    expect(csrf.statusCode).toBe(403);
  });

  it('validates a new backup folder before accepting it', async () => {
    const s = await server();
    const relative = await s.app.inject({ method: 'PUT', url: `${API}/admin/settings`, payload: { destination: 'relative\\path' } });
    expect(relative.statusCode).toBe(400);
    const moved = path.join(s.root, 'second backup');
    expect((await s.app.inject({ method: 'PUT', url: `${API}/admin/settings`, payload: { destination: moved } })).statusCode).toBe(200);
    const first = get<{ path: string }>(s.db, 'SELECT path FROM files');
    expect(first).toBeUndefined();
    const res = await s.upload(await s.newSession(), 'a.jpg', randomBytes(50));
    expect(res.body.path).toBe(path.join(moved, 'a.jpg'));
  });
});

describe('stopping with the dashboard', () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  /** Opens the dashboard's live connection, like a browser tab does. */
  const openDashboard = (port: number) =>
    new Promise<http.ClientRequest>((resolve) => {
      const req = http.get({ host: '127.0.0.1', port, path: `${API}/admin/events` }, (res) => {
        res.resume();
        resolve(req);
      });
      req.on('error', () => undefined);
    });
  const defaults = { ...autoStop };
  afterEach(() => void Object.assign(autoStop, defaults));

  it('stops once the last dashboard tab is closed, but not on a page refresh', async () => {
    let stops = 0;
    const s = await server({}, { onStopRequest: () => stops++ });
    const port = await s.listen();
    Object.assign(autoStop, { graceMs: 150, recheckMs: 100 });

    const tab = await openDashboard(port);
    tab.destroy();
    const reloaded = await openDashboard(port); // refresh: gone and back within the grace period
    await sleep(400);
    expect(stops).toBe(0);

    reloaded.destroy();
    await sleep(500);
    expect(stops).toBe(1);
  });

  it('waits while a phone is mid-backup, and never stops when the option is off', async () => {
    let stops = 0;
    const s = await server({}, { onStopRequest: () => stops++ });
    const port = await s.listen();
    Object.assign(autoStop, { graceMs: 100, recheckMs: 100 });

    await s.phone({ method: 'GET', url: `${API}/status` }); // the phone was just active
    (await openDashboard(port)).destroy();
    await sleep(400);
    expect(stops).toBe(0);
    autoStop.deviceQuietMs = 0; // ...and now it has been quiet long enough
    await sleep(400);
    expect(stops).toBe(1);

    let offStops = 0;
    const off = await server({ stopWithDashboard: false }, { onStopRequest: () => offStops++ });
    (await openDashboard(await off.listen())).destroy();
    await sleep(400);
    expect(offStops).toBe(0);
  });

  it('never stops if no dashboard was ever opened', async () => {
    let stops = 0;
    const s = await server({}, { onStopRequest: () => stops++ });
    await s.listen();
    Object.assign(autoStop, { graceMs: 50, recheckMs: 50 });
    await sleep(300);
    expect(stops).toBe(0);
  });

  it('has a Stop button that only this computer can press', async () => {
    let stops = 0;
    const s = await server({}, { onStopRequest: () => stops++ });
    expect((await s.phone({ method: 'POST', url: `${API}/admin/shutdown` })).statusCode).toBe(403);
    expect((await s.app.inject({ method: 'POST', url: `${API}/admin/shutdown` })).statusCode).toBe(200);
    await sleep(300);
    expect(stops).toBe(1);
  });
});
