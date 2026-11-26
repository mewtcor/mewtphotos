// HTTP layer: versioned JSON API for senders (/api/v1/...), loopback-only admin API for the
// dashboard (/api/v1/admin/...), live events, and the built web UI.
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { rm, stat, statfs } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import type { Readable } from 'node:stream';
import fastifyStatic from '@fastify/static';
import Fastify, { LogController, type FastifyInstance, type FastifyRequest } from 'fastify';
import QRCode from 'qrcode';
import { z } from 'zod';
import {
  API, AssetCheck, CHUNK_SIZE, PairRequest, SessionComplete, SessionCreate, SettingsUpdate, UploadCreate, UploadFinish,
  type AssetCount, type AssetHeld, type ClientStatus, type Overview, type PairingInfo, type Settings, type UploadState, type VerifyReport,
} from '../shared/schemas.ts';
import { loadSettings, saveSettings, validateDestination } from './config.ts';
import { all, get, run, type Db, type DeviceRow } from './db.ts';
import { appendChunk, cancelUpload, createUpload, currentOffset, finishUpload, getUpload, recover, sessionSummary, type Ctx } from './engine.ts';
import { hashToken, HttpError, isLocalNetworkAddress, isLoopback, newToken, Pairing } from './security.ts';
import { verifyBackup } from './verify.ts';

export const VERSION = '0.1.0';
const SHORTCUT_SESSION_WINDOW_MS = 30 * 60 * 1000;
/** Timing of "stop when the dashboard is closed"; mutable so tests need not wait. */
export const autoStop = {
  /** How long after the last dashboard tab disappears before stopping (covers a page refresh). */
  graceMs: 20_000,
  /** How often to look again while a phone is still busy. */
  recheckMs: 30_000,
  /** A phone that talked to the server this recently is treated as mid-backup. */
  deviceQuietMs: 5 * 60_000,
};

export interface AppOptions {
  db: Db;
  port: number;
  /** Address the iPhone connects to; null = dashboard only (no network found). */
  lanIp: string | null;
  logFile?: string;
  webDir?: string;
  /** Run as a headless 24/7 server: never auto-stop when dashboard tabs close. */
  daemon?: boolean;
  /** Called when the app should shut itself down (dashboard closed, or Stop pressed). */
  onStopRequest?: (reason: string) => void;
  /** Test seam for disk-full behaviour. */
  freeBytes?: (dir: string) => Promise<number>;
}

export interface BuiltApp {
  app: FastifyInstance;
  ctx: Ctx;
  pairing: Pairing;
  /** Binds 127.0.0.1 (dashboard) and, when available, the LAN address (iPhone). */
  listen(): Promise<number>;
}

function makeServer(handler: http.RequestListener): http.Server {
  const server = http.createServer(handler);
  server.requestTimeout = 6 * 60 * 60 * 1000; // a single large video may legitimately take a long time
  return server;
}

const Id = z.uuid();
const idParam = (req: FastifyRequest) => Id.parse((req.params as { id?: string }).id);

export async function buildApp(opts: AppOptions): Promise<BuiltApp> {
  const { db } = opts;
  let handler: http.RequestListener | undefined;
  let lanServer: http.Server | undefined;
  let boundPort = opts.port;

  const app = Fastify({
    serverFactory: (h) => {
      handler = h;
      return makeServer(h);
    },
    // Our own events are logged via ctx.log; per-request logs would bury them (one line per chunk).
    logger: opts.logFile ? { level: 'info', file: opts.logFile } : false,
    logController: new LogController({ disableRequestLogging: true }),
    forceCloseConnections: true,
    bodyLimit: 1024 * 1024, // JSON bodies only; file bytes arrive as streams
  });

  // ---- shared state ------------------------------------------------------
  let settings: Settings = loadSettings(db);
  const emitter = new EventEmitter();
  emitter.setMaxListeners(50);
  const pairing = new Pairing();
  const startedAt = Date.now();
  let restartRequired = false;
  let verifyRunning = false;
  let lastDeviceActivity = 0;
  let dashboards = 0;
  let stopTimer: NodeJS.Timeout | undefined;

  const ctx: Ctx = {
    db,
    settings: () => settings,
    log(level, code, message) {
      run(db, 'INSERT INTO logs (ts, level, code, message) VALUES (?, ?, ?, ?)', Date.now(), level, code, message);
      app.log[level]({ code }, message);
      emitter.emit('event', 'change', null);
    },
    emit: (event, data) => void emitter.emit('event', event, data ?? null),
    freeBytes: opts.freeBytes ?? (async (dir) => {
      const s = await statfs(dir);
      return s.bavail * s.bsize;
    }),
    active: new Set(),
    placing: Promise.resolve(),
    bytesIn: 0,
  };

  run(db, 'DELETE FROM logs WHERE id <= (SELECT MAX(id) FROM logs) - 5000');
  await recover(ctx);

  // ---- timers ------------------------------------------------------------
  let lastBytes = 0;
  let wasMoving = false;
  const speedTimer = setInterval(() => {
    const delta = ctx.bytesIn - lastBytes;
    lastBytes = ctx.bytesIn;
    if (delta > 0 || wasMoving) ctx.emit('speed', { bytesPerSecond: delta });
    wasMoving = delta > 0;
  }, 1000);
  const networkTimer = setInterval(() => {
    if (!opts.lanIp || restartRequired) return;
    const present = Object.values(os.networkInterfaces()).some((addrs) => addrs?.some((a) => a.address === opts.lanIp));
    if (!present) {
      restartRequired = true;
      ctx.log('error', 'restart_required', `This computer's network address changed (was ${opts.lanIp}). Server restart required: close and relaunch the backup app, then reconnect the iPhone.`);
    }
  }, 15_000);
  speedTimer.unref();
  networkTimer.unref();
  app.addHook('onClose', async () => {
    clearInterval(speedTimer);
    clearInterval(networkTimer);
    clearTimeout(stopTimer);
    lanServer?.closeAllConnections();
    await new Promise<void>((resolve) => (lanServer ? lanServer.close(() => resolve()) : resolve()));
  });

  // ---- request guards ----------------------------------------------------
  app.addHook('onRequest', async (req, reply) => {
    if (!isLocalNetworkAddress(req.ip)) throw new HttpError(403, 'forbidden_network', 'This server only accepts connections from the local network.');
    // A web page on another origin must not be able to drive this API from the user's browser.
    const origin = req.headers.origin;
    if (origin) {
      let originHost = '';
      try {
        originHost = new URL(origin).host;
      } catch {
        // unparseable origin is rejected below
      }
      if (originHost !== req.headers.host) throw new HttpError(403, 'bad_origin', 'Cross-origin requests are not allowed.');
    }
    reply.header('x-content-type-options', 'nosniff');
    reply.header('content-security-policy', "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'");
    if (req.url.startsWith('/api/')) reply.header('cache-control', 'no-store');
  });

  function requireDevice(req: FastifyRequest): DeviceRow {
    const token = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
    const device = token && get<DeviceRow>(db, 'SELECT id, name FROM devices WHERE token_hash = ? AND revoked_at IS NULL', hashToken(token));
    if (!device) throw new HttpError(401, 'unauthorized', 'This device is not paired. Scan the QR code on the Windows dashboard.');
    lastDeviceActivity = Date.now();
    run(db, 'UPDATE devices SET last_seen_at = ? WHERE id = ? AND COALESCE(last_seen_at, 0) < ?', Date.now(), device.id, Date.now() - 60_000);
    return device;
  }

  /** The dashboard has no password: it is reachable only from this computer itself. */
  function requireAdmin(req: FastifyRequest): void {
    let hostname = '';
    try {
      hostname = new URL(`http://${req.headers.host}`).hostname;
    } catch {
      // rejected below
    }
    const localHost = hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]';
    if (!isLoopback(req.ip) || !localHost) {
      throw new HttpError(403, 'admin_local_only', 'The dashboard is only available on the Windows computer itself.');
    }
  }

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.code, message: err.message, ...err.extra });
    if (err instanceof z.ZodError) return reply.code(400).send({ error: 'invalid_request', message: z.prettifyError(err) });
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) {
      app.log.error(err);
      return reply.code(500).send({ error: 'internal_error', message: 'Internal server error.' });
    }
    return reply.code(status).send({ error: 'bad_request', message: (err as Error).message });
  });

  // File bytes of any content type are handed to the route as a stream (never buffered in RAM).
  app.addContentTypeParser('*', (_req, payload, done) => done(null, payload));

  // ---- sender API --------------------------------------------------------
  app.get(`${API}/health`, async () => ({ ok: true, name: 'mewtphotos', apiVersion: 1 }));

  app.post(`${API}/pair`, async (req) => {
    const body = PairRequest.parse(req.body);
    pairing.consume(body.code, req.ip);
    const token = newToken();
    const id = randomUUID();
    run(db, 'INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)', id, body.deviceName, hashToken(token), Date.now());
    ctx.log('info', 'paired', `Paired a new device: "${body.deviceName}".`);
    return { token, deviceId: id };
  });

  function startVerify(): void {
    if (verifyRunning) throw new HttpError(409, 'verify_running', 'A verification is already running.');
    verifyRunning = true;
    void verifyBackup(db, settings.destination, (done, total) => ctx.emit('verify', { done, total }))
      .then((report) => {
        const bad = report.missing.length + report.corrupt.length + report.databaseProblems.length;
        ctx.log(bad ? 'error' : 'info', 'verify_finished', bad
          ? `Verification found problems: ${report.missing.length} missing, ${report.corrupt.length} corrupted, ${report.databaseProblems.length} database issue(s).`
          : `Verification passed: all ${report.ok} stored files match their recorded SHA-256.`);
      })
      .catch((err: unknown) => ctx.log('error', 'verify_failed', `Verification could not finish: ${err instanceof Error ? err.message : String(err)}`))
      .finally(() => {
        verifyRunning = false;
        ctx.emit('change');
      });
  }

  app.get(`${API}/status`, async (req): Promise<ClientStatus> => {
    const device = requireDevice(req);
    const freeBytes = await ctx.freeBytes(settings.destination).catch(() => 0);
    const stats = get<{ files: number; bytes: number }>(db, 'SELECT COUNT(*) AS files, COALESCE(SUM(size), 0) AS bytes FROM files')!;
    const lastVerifyRow = get<{ value: string }>(db, `SELECT value FROM settings WHERE key = 'lastVerify'`);
    const lastVerifyAt = lastVerifyRow ? ((JSON.parse(lastVerifyRow.value) as VerifyReport).finishedAt ?? null) : null;
    return {
      deviceName: device.name,
      serverName: os.hostname(),
      chunkSize: CHUNK_SIZE,
      concurrency: settings.concurrency,
      maxFileBytes: settings.maxFileBytes,
      freeBytes,
      storedFiles: stats.files,
      storedBytes: stats.bytes,
      verifyRunning,
      lastVerifyAt,
    };
  });

  app.post(`${API}/verify`, async (req, reply) => {
    requireDevice(req);
    startVerify();
    return reply.code(202).send({ started: true });
  });

  function ownSession(req: FastifyRequest, device: DeviceRow): string {
    const id = idParam(req);
    if (!get(db, 'SELECT id FROM sessions WHERE id = ? AND device_id = ?', id, device.id)) throw new HttpError(404, 'unknown_session', 'Unknown backup session.');
    return id;
  }

  app.post(`${API}/sessions`, async (req) => {
    const device = requireDevice(req);
    const body = SessionCreate.parse(req.body);
    const id = randomUUID();
    run(db, 'INSERT INTO sessions (id, device_id, method, selected_count, library_count, started_at) VALUES (?, ?, ?, ?, ?, ?)', id, device.id, body.method, body.selectedCount, body.libraryCount ?? null, Date.now());
    ctx.emit('change');
    return sessionSummary(db, id);
  });

  app.get(`${API}/sessions/:id`, async (req) => sessionSummary(db, ownSession(req, requireDevice(req))));

  app.post(`${API}/sessions/:id/complete`, async (req) => {
    const id = ownSession(req, requireDevice(req));
    const body = SessionComplete.parse(req.body ?? {});
    run(db, 'UPDATE sessions SET completed_at = ?, unavailable_count = ? WHERE id = ?', Date.now(), body.unavailableCount, id);
    ctx.emit('change');
    return sessionSummary(db, id);
  });

  app.post(`${API}/uploads`, async (req) => createUpload(ctx, requireDevice(req), UploadCreate.parse(req.body)));

  app.get(`${API}/uploads/:id`, async (req, reply): Promise<UploadState> => {
    const upload = getUpload(ctx, idParam(req), requireDevice(req).id);
    const offset = upload.status === 'receiving' ? await currentOffset(upload) : upload.size;
    reply.header('upload-offset', offset);
    return { uploadId: upload.id, status: upload.status as UploadState['status'], offset, size: upload.size };
  });

  // With no Content-Type header Fastify skips body parsing; the raw request is then the stream.
  const bodyStream = (req: FastifyRequest) => (req.body ?? req.raw) as Readable;

  app.patch(`${API}/uploads/:id`, async (req, reply) => {
    const upload = getUpload(ctx, idParam(req), requireDevice(req).id);
    const offset = z.coerce.number().int().min(0).parse(req.headers['upload-offset']);
    const newOffset = await appendChunk(ctx, upload, offset, bodyStream(req));
    reply.header('upload-offset', newOffset);
    return { offset: newOffset };
  });

  app.post(`${API}/uploads/:id/finish`, async (req) => {
    const upload = getUpload(ctx, idParam(req), requireDevice(req).id);
    return finishUpload(ctx, upload, UploadFinish.parse(req.body ?? {}).sha256);
  });

  app.delete(`${API}/uploads/:id`, async (req) => {
    await cancelUpload(ctx, getUpload(ctx, idParam(req), requireDevice(req).id));
    return { ok: true };
  });

  // One request per file, for Apple Shortcuts and simple clients. Not resumable: a failed
  // request must be sent again from the start.
  const OneShotQuery = z.object({ filename: z.string().min(1).max(255), sessionId: z.uuid().optional(), sha256: UploadFinish.shape.sha256 });
  app.post(`${API}/files`, async (req) => {
    const device = requireDevice(req);
    const query = OneShotQuery.parse(req.query);
    const size = z.coerce.number().int().min(1).safeParse(req.headers['content-length']);
    if (!size.success) throw new HttpError(411, 'length_required', 'Send the file as the request body with a Content-Length header.');

    let sessionId = query.sessionId;
    if (!sessionId) {
      // Shortcuts sends files one by one; group a run of them into one session.
      const recent = get<{ id: string }>(db, `SELECT id FROM sessions WHERE device_id = ? AND method = 'shortcut' AND started_at > ? ORDER BY started_at DESC LIMIT 1`, device.id, Date.now() - SHORTCUT_SESSION_WINDOW_MS);
      sessionId = recent?.id ?? randomUUID();
      if (!recent) run(db, `INSERT INTO sessions (id, device_id, method, started_at) VALUES (?, ?, 'shortcut', ?)`, sessionId, device.id, Date.now());
      run(db, 'UPDATE sessions SET selected_count = selected_count + 1 WHERE id = ?', sessionId);
    }
    const mimeType = String(req.headers['content-type'] ?? '').slice(0, 100);
    const created = await createUpload(ctx, device, { sessionId, filename: query.filename, size: size.data, mimeType, sha256: query.sha256 });
    if (created.status !== 'receiving') return created;
    const upload = getUpload(ctx, created.uploadId, device.id);
    try {
      await appendChunk(ctx, upload, 0, bodyStream(req));
      return await finishUpload(ctx, upload, query.sha256);
    } catch (err) {
      const code = err instanceof HttpError ? err.code : 'write_failed';
      run(db, `UPDATE uploads SET status = 'failed', error = ?, updated_at = ? WHERE id = ? AND status = 'receiving'`, code === 'incomplete' ? 'incomplete: connection closed before the whole file arrived' : code, Date.now(), upload.id);
      await rm(upload.temp_path, { force: true });
      ctx.emit('change');
      throw err;
    }
  });

  /** A recorded file counts only while it still sits on disk at the recorded size (SRV-03). */
  async function storedOnDisk(sha256: string): Promise<boolean> {
    const file = get<{ path: string; size: number }>(db, `SELECT path, size FROM files WHERE sha256 = ? AND verify_status = 'ok'`, sha256);
    return !!file && (await stat(file.path).then((s) => s.isFile() && s.size === file.size, () => false));
  }

  // "Do you already have this content?" for simple clients (Apple Shortcuts) that can hash a
  // file but cannot easily build the JSON for /assets/check. Known = recorded, passed its last
  // verification, and still on disk at the recorded size.
  app.get(`${API}/files/:sha256`, async (req) => {
    requireDevice(req);
    const sha256 = z.string().regex(/^[0-9a-fA-F]{64}$/).parse((req.params as { sha256?: string }).sha256).toLowerCase();
    const file = get<{ path: string }>(db, `SELECT path FROM files WHERE sha256 = ? AND verify_status = 'ok'`, sha256);
    // `status` duplicates `known` as text because Shortcuts compares text more reliably than booleans.
    return (await storedOnDisk(sha256)) && file ? { known: true, status: 'stored', path: file.path } : { known: false, status: 'missing' };
  });

  // Lets a sender with stable asset identifiers or hashes skip what is already recorded. An item counts only
  // while its stored copy is still on disk at the recorded size (SRV-03): a record alone is not enough.
  app.post(`${API}/assets/check`, async (req) => {
    const device = requireDevice(req);
    const { items } = AssetCheck.parse(req.body);
    const known = await Promise.all(
      items.map(async (item) => {
        if (item.sha256 && (await storedOnDisk(item.sha256))) return true;
        if (!item.assetId) return false;
        const rows = all<{ sha256: string }>(
          db,
          `SELECT f.sha256 FROM uploads u JOIN files f ON f.id = u.file_id
           WHERE u.device_id = ? AND u.asset_id = ? AND u.status IN ('verified', 'duplicate')`,
          device.id, item.assetId,
        );
        for (const row of rows) if (await storedOnDisk(row.sha256)) return true;
        return false;
      }),
    );
    return { known };
  });

  // The asset identifiers this iPhone's photos the PC holds. Same rule as /assets/check: an asset counts only
  // while a stored copy is still on disk at the recorded size.
  async function heldAssetIds(deviceId: string): Promise<Set<string>> {
    const rows = all<{ asset_id: string; sha256: string }>(
      db,
      `SELECT DISTINCT u.asset_id, f.sha256 FROM uploads u JOIN files f ON f.id = u.file_id
       WHERE u.device_id = ? AND u.asset_id IS NOT NULL AND u.status IN ('verified', 'duplicate')`,
      deviceId,
    );
    const held = new Set<string>();
    for (const row of rows) {
      if (!held.has(row.asset_id) && (await storedOnDisk(row.sha256))) held.add(row.asset_id);
    }
    return held;
  }

  // How many of this iPhone's photos the PC holds, so the app can show its own total next to the PC's (REP-02).
  app.get(`${API}/assets/count`, async (req): Promise<AssetCount> => {
    const device = requireDevice(req);
    return { stored: (await heldAssetIds(device.id)).size };
  });

  // Every held identifier, so the app can compare its library with the PC and list what is missing (coverage).
  app.get(`${API}/assets/held`, async (req): Promise<AssetHeld> => {
    const device = requireDevice(req);
    return { assetIds: [...(await heldAssetIds(device.id))] };
  });

  // ---- admin API (this computer only) ------------------------------------
  const lanUrl = () => (opts.lanIp ? `http://${opts.lanIp}:${boundPort}` : null);

  app.get(`${API}/admin/overview`, async (req): Promise<Overview> => {
    requireAdmin(req);
    const count = (sql: string) => get<{ n: number }>(db, sql)!.n;
    const lastVerify = get<{ value: string }>(db, `SELECT value FROM settings WHERE key = 'lastVerify'`);
    return {
      server: { lanUrl: lanUrl(), port: boundPort, startedAt, restartRequired, version: VERSION },
      settings,
      storage: {
        freeBytes: await ctx.freeBytes(settings.destination).catch(() => 0),
        backupBytes: count('SELECT COALESCE(SUM(size), 0) AS n FROM files'),
      },
      totals: {
        files: count('SELECT COUNT(*) AS n FROM files'),
        bytes: count('SELECT COALESCE(SUM(size), 0) AS n FROM files'),
        duplicates: count(`SELECT COUNT(*) AS n FROM uploads WHERE status = 'duplicate'`),
        failed: count(`SELECT COUNT(*) AS n FROM uploads WHERE status = 'failed'`),
        endToEndVerified: count(`SELECT COUNT(*) AS n FROM uploads WHERE status = 'verified' AND e2e_verified = 1`),
      },
      sessions: all<{ id: string }>(db, 'SELECT id FROM sessions ORDER BY started_at DESC LIMIT 30').map((s) => sessionSummary(db, s.id)!),
      failures: all(db, `SELECT u.id, u.filename, COALESCE(u.error, 'unknown') AS error, u.updated_at AS at, d.name AS device FROM uploads u JOIN devices d ON d.id = u.device_id WHERE u.status = 'failed' ORDER BY u.updated_at DESC LIMIT 100`),
      logs: all(db, 'SELECT ts, level, code, message FROM logs ORDER BY id DESC LIMIT 200'),
      devices: all(db, 'SELECT id, name, created_at AS createdAt, last_seen_at AS lastSeenAt FROM devices WHERE revoked_at IS NULL ORDER BY created_at DESC'),
      lastVerify: lastVerify ? (JSON.parse(lastVerify.value) as VerifyReport) : null,
      verifyRunning,
    };
  });

  app.get(`${API}/admin/pairing`, async (req): Promise<PairingInfo> => {
    requireAdmin(req);
    const { code, expiresAt } = pairing.current();
    // The code rides in the URL fragment, which browsers never send to a server or log.
    const url = lanUrl() && `${lanUrl()}/#pair=${code}`;
    return { code, expiresAt, url, qrSvg: url ? await QRCode.toString(url, { type: 'svg', margin: 1 }) : null };
  });

  app.put(`${API}/admin/settings`, async (req) => {
    requireAdmin(req);
    const body = SettingsUpdate.parse(req.body);
    const next: Settings = { ...settings, ...body };
    if (body.destination !== undefined) next.destination = await validateDestination(body.destination);
    saveSettings(db, next);
    if (next.destination !== settings.destination) ctx.log('info', 'destination_changed', `Backup folder changed to ${next.destination}. Files already backed up stay where they are.`);
    settings = next;
    ctx.emit('change');
    return settings;
  });

  app.post(`${API}/admin/verify`, async (req, reply) => {
    requireAdmin(req);
    startVerify();
    return reply.code(202).send({ started: true });
  });

  app.delete(`${API}/admin/devices/:id`, async (req) => {
    requireAdmin(req);
    run(db, 'UPDATE devices SET revoked_at = ? WHERE id = ?', Date.now(), idParam(req));
    ctx.log('info', 'device_removed', 'A paired device was removed; it must pair again to upload.');
    return { ok: true };
  });

  // Closing the dashboard stops the app, but never out from under a backup: it waits while
  // any dashboard tab is open, a file is being written, or a phone was active moments ago.
  function stopIfDashboardGone(): void {
    clearTimeout(stopTimer);
    if (opts.daemon || dashboards > 0 || !settings.stopWithDashboard || !opts.onStopRequest) return;
    const phoneBusy = ctx.active.size > 0 || verifyRunning || Date.now() - lastDeviceActivity < autoStop.deviceQuietMs;
    if (phoneBusy) {
      stopTimer = setTimeout(stopIfDashboardGone, autoStop.recheckMs);
      return;
    }
    ctx.log('info', 'auto_stop', 'The dashboard was closed and no backup is running, so the app is stopping.');
    opts.onStopRequest('The dashboard was closed');
  }

  app.post(`${API}/admin/shutdown`, async (req) => {
    requireAdmin(req);
    ctx.log('info', 'stop_requested', 'Stop was pressed on the dashboard.');
    setTimeout(() => opts.onStopRequest?.('Stop was pressed on the dashboard'), 100); // after this reply is sent
    return { stopping: true };
  });

  app.get(`${API}/admin/events`, (req, reply) => {
    requireAdmin(req);
    dashboards++;
    clearTimeout(stopTimer);
    reply.hijack();
    reply.raw.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
    reply.raw.write(': connected\n\n'); // flushes the headers so the browser knows the stream is open
    const send = (event: string, data: unknown) => void reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    const ping = setInterval(() => reply.raw.write(': ping\n\n'), 25_000);
    emitter.on('event', send);
    req.raw.on('close', () => {
      emitter.off('event', send);
      clearInterval(ping);
      dashboards--;
      if (dashboards === 0) stopTimer = setTimeout(stopIfDashboardGone, autoStop.graceMs);
    });
  });

  // ---- web UI ------------------------------------------------------------
  const webDir = opts.webDir ?? path.join(import.meta.dirname, '..', 'web', 'dist');
  const hasWeb = existsSync(path.join(webDir, 'index.html'));
  if (hasWeb) await app.register(fastifyStatic, { root: webDir });
  app.setNotFoundHandler((req, reply) => {
    if (req.method !== 'GET' || req.url.startsWith('/api/')) return reply.code(404).send({ error: 'not_found', message: 'Not found.' });
    if (!hasWeb) return reply.code(503).type('text/plain').send('The web interface has not been built yet. Run "npm run build" in the project folder and restart.');
    return reply.sendFile('index.html'); // single-page app: / and /dashboard share one file
  });

  async function listen(): Promise<number> {
    await app.listen({ host: '127.0.0.1', port: opts.port });
    boundPort = (app.server.address() as { port: number }).port;
    if (opts.lanIp && handler) {
      const server = makeServer(handler);
      await new Promise<void>((resolve, reject) => {
        server.once('error', reject);
        server.listen(boundPort, opts.lanIp!, () => {
          server.off('error', reject);
          resolve();
        });
      });
      lanServer = server;
    }
    return boundPort;
  }

  return { app, ctx, pairing, listen };
}
