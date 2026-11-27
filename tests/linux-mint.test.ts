// Tests for redesign status telemetry, authenticated /verify, Linux Mint daemon mode, and DB path migration.
import { mkdtemp } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { API, type ClientStatus } from '../shared/schemas.ts';
import { autoStop } from '../server/app.ts';
import { loadSettings } from '../server/config.ts';
import { get, openDb, run } from '../server/db.ts';
import { migrateDbPaths, rewriteBackupPath } from '../server/migrate.ts';
import { startServer, type TestServer } from './helpers.ts';

const open: TestServer[] = [];
afterEach(async () => {
  for (const s of open.splice(0)) await s.app.close();
});

async function server(...args: Parameters<typeof startServer>): Promise<TestServer> {
  const s = await startServer(...args);
  open.push(s);
  return s;
}

describe('client status telemetry & authenticated verify', () => {
  it('returns archive storedFiles, storedBytes, verifyRunning, and lastVerifyAt in GET /status', async () => {
    const s = await server();
    const initial = (await s.phone({ method: 'GET', url: `${API}/status` })).json() as ClientStatus;
    expect(initial.storedFiles).toBe(0);
    expect(initial.storedBytes).toBe(0);
    expect(initial.verifyRunning).toBe(false);
    expect(initial.lastVerifyAt).toBeNull();

    const payload = Buffer.from('photo bytes for archive telemetry');
    const session = await s.newSession(1);
    const done = await s.upload(session, 'IMG_9001.JPG', payload);
    expect(done.body.status).toBe('verified');

    const after = (await s.phone({ method: 'GET', url: `${API}/status` })).json() as ClientStatus;
    expect(after.storedFiles).toBe(1);
    expect(after.storedBytes).toBe(payload.length);
  });

  it('POST /verify requires device authentication and runs archive verification when paired', async () => {
    const s = await server();
    const unauth = await s.app.inject({ method: 'POST', url: `${API}/verify`, remoteAddress: '192.168.1.50' });
    expect(unauth.statusCode).toBe(401);

    const session = await s.newSession(1);
    await s.upload(session, 'IMG_9002.JPG', Buffer.from('verify me'));

    const res = await s.phone({ method: 'POST', url: `${API}/verify` });
    expect(res.statusCode).toBe(202);
    expect(res.json()).toEqual({ started: true });

    // Wait briefly for the fast in-memory verification of 1 tiny file to complete.
    let status: ClientStatus | undefined;
    for (let i = 0; i < 40; i++) {
      status = (await s.phone({ method: 'GET', url: `${API}/status` })).json() as ClientStatus;
      if (!status.verifyRunning && status.lastVerifyAt !== null) break;
      await new Promise((r) => setTimeout(r, 25));
    }
    expect(status?.verifyRunning).toBe(false);
    expect(typeof status?.lastVerifyAt).toBe('number');
  });

  it('POST /files supports native metadata (assetId, hidden, pairId, pairName, lastModified) and duplicate draining', async () => {
    const s = await server();
    const session = await s.newSession(2);
    const videoBytes = Buffer.from('live photo companion video');
    const photoBytes = Buffer.from('live photo still image');
    const videoHash = (await import('./helpers.ts')).sha256(videoBytes);
    const photoHash = (await import('./helpers.ts')).sha256(photoBytes);

    const comp = await s.phone({
      method: 'POST',
      url: `${API}/files?filename=IMG_5001.MOV&sessionId=${session}&sha256=${videoHash}&hidden=1&lastModified=1700000000000&pairId=asset-5001&pairName=IMG_5001.HEIC`,
      headers: { 'content-type': 'video/quicktime', 'content-length': String(videoBytes.length) },
      payload: videoBytes,
    });
    expect(comp.statusCode).toBe(200);
    expect(comp.json()).toMatchObject({ status: 'verified', endToEndVerified: true });

    const main = await s.phone({
      method: 'POST',
      url: `${API}/files?filename=IMG_5001.HEIC&sessionId=${session}&sha256=${photoHash}&assetId=asset-5001&hidden=1&lastModified=1700000000000&pairId=asset-5001&pairName=IMG_5001.MOV`,
      headers: { 'content-type': 'image/heic', 'content-length': String(photoBytes.length) },
      payload: photoBytes,
    });
    expect(main.statusCode).toBe(200);
    const mainBody = main.json() as { status: string; path: string };
    expect(mainBody.status).toBe('verified');
    expect(mainBody.path).toContain('Hidden');

    // Sending the exact same file again via one-shot reports duplicate cleanly.
    const dup = await s.phone({
      method: 'POST',
      url: `${API}/files?filename=IMG_5001.HEIC&sessionId=${session}&sha256=${photoHash}&assetId=asset-5001&hidden=1`,
      headers: { 'content-type': 'image/heic', 'content-length': String(photoBytes.length) },
      payload: photoBytes,
    });
    expect(dup.statusCode).toBe(200);
    expect(dup.json()).toMatchObject({ status: 'duplicate' });

    // Asset is now reported as held by /assets/held.
    const held = (await s.phone({ method: 'GET', url: `${API}/assets/held` })).json() as { assetIds: string[] };
    expect(held.assetIds).toContain('asset-5001');
  });
});

describe('24/7 daemon mode', () => {
  it('never triggers onStopRequest when daemon mode is enabled even if stopWithDashboard is true', async () => {
    let stopCalled = false;
    const savedGrace = autoStop.graceMs;
    autoStop.graceMs = 20;
    try {
      const s = await server({ stopWithDashboard: true }, { daemon: true, onStopRequest: () => { stopCalled = true; } });
      // Open and close a dashboard SSE connection on loopback.
      const port = await s.listen();
      const tab = await new Promise<http.ClientRequest>((resolve, reject) => {
        const req = http.get({ host: '127.0.0.1', port, path: `${API}/admin/events` }, (res) => {
          res.resume();
          resolve(req);
        });
        req.on('error', reject);
      });
      tab.destroy();
      await new Promise((r) => setTimeout(r, 120));
      expect(stopCalled).toBe(false);
    } finally {
      autoStop.graceMs = savedGrace;
    }
  });
});

describe('Windows to Linux Mint DB path migration', () => {
  it('rewrites Windows drive paths to POSIX paths case-insensitively and ignores unrelated prefixes', () => {
    expect(
      rewriteBackupPath('C:\\Users\\Mewt\\Pictures\\iPhone Backup\\2026\\10\\IMG_8281.DNG', 'c:\\users\\mewt\\pictures\\iphone backup\\', '/srv/mewtphotos/backup/'),
    ).toBe('/srv/mewtphotos/backup/2026/10/IMG_8281.DNG');
    expect(
      rewriteBackupPath('D:\\Other\\IMG_1.JPG', 'C:\\Users\\Mewt\\Pictures\\iPhone Backup', '/srv/mewtphotos/backup'),
    ).toBeNull();
  });

  it('migrates files, uploads, and settings atomically and respects dryRun', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'mp-migrate-'));
    const db = openDb(path.join(dir, 'mewtphotos.db'));
    try {
      run(db, `INSERT INTO settings (key, value) VALUES ('settings', ?)`, JSON.stringify({
        destination: 'C:\\Users\\Mewt\\Pictures\\iPhone Backup',
        organizeByDate: true,
        maxFileBytes: 1024,
        quotaBytes: 0,
        minFreeBytes: 0,
        concurrency: 2,
        stopWithDashboard: true,
      }));
      run(db, `INSERT INTO devices (id, name, token_hash, created_at) VALUES ('d1', 'iPhone', 'hash1', 1)`);
      run(db, `INSERT INTO sessions (id, device_id, method, started_at) VALUES ('s1', 'd1', 'native', 1)`);
      run(db, `INSERT INTO files (sha256, path, original_name, size, date_source, created_at) VALUES ('a', 'C:\\Users\\Mewt\\Pictures\\iPhone Backup\\2026\\10\\IMG_1.HEIC', 'IMG_1.HEIC', 100, 'exif', 1)`);
      run(db, `INSERT INTO files (sha256, path, original_name, size, date_source, created_at) VALUES ('b', 'E:\\Archive\\IMG_2.HEIC', 'IMG_2.HEIC', 100, 'exif', 1)`);
      run(db, `INSERT INTO uploads (id, session_id, device_id, filename, size, temp_path, final_path, status, created_at, updated_at) VALUES ('u1', 's1', 'd1', 'IMG_1.HEIC', 100, 'C:\\Users\\Mewt\\Pictures\\iPhone Backup\\.incoming\\u1.part', 'C:\\Users\\Mewt\\Pictures\\iPhone Backup\\2026\\10\\IMG_1.HEIC', 'verified', 1, 1)`);

      const dry = migrateDbPaths(db, {
        fromPrefix: 'C:\\Users\\Mewt\\Pictures\\iPhone Backup',
        toPrefix: '/srv/mewtphotos/backup',
        dryRun: true,
        disableStopWithDashboard: true,
      });
      expect(dry).toEqual({
        filesUpdated: 1,
        filesUnmatched: 1,
        uploadsFinalUpdated: 1,
        uploadsTempUpdated: 1,
        settingsUpdated: true,
        dryRun: true,
      });
      // Dry run must leave DB untouched
      expect(get<{ path: string }>(db, `SELECT path FROM files WHERE sha256 = 'a'`)?.path).toBe('C:\\Users\\Mewt\\Pictures\\iPhone Backup\\2026\\10\\IMG_1.HEIC');

      const applied = migrateDbPaths(db, {
        fromPrefix: 'C:\\Users\\Mewt\\Pictures\\iPhone Backup',
        toPrefix: '/srv/mewtphotos/backup',
        disableStopWithDashboard: true,
      });
      expect(applied.filesUpdated).toBe(1);
      expect(applied.filesUnmatched).toBe(1);
      expect(get<{ path: string }>(db, `SELECT path FROM files WHERE sha256 = 'a'`)?.path).toBe('/srv/mewtphotos/backup/2026/10/IMG_1.HEIC');
      expect(get<{ path: string }>(db, `SELECT path FROM files WHERE sha256 = 'b'`)?.path).toBe('E:\\Archive\\IMG_2.HEIC');
      expect(get<{ final_path: string; temp_path: string }>(db, `SELECT final_path, temp_path FROM uploads WHERE id = 'u1'`)).toEqual({
        final_path: '/srv/mewtphotos/backup/2026/10/IMG_1.HEIC',
        temp_path: '/srv/mewtphotos/backup/.incoming/u1.part',
      });
      const settings = JSON.parse(get<{ value: string }>(db, `SELECT value FROM settings WHERE key = 'settings'`)!.value) as { destination: string; stopWithDashboard: boolean };
      expect(settings.destination).toBe('/srv/mewtphotos/backup');
      expect(settings.stopWithDashboard).toBe(false);
    } finally {
      db.close();
    }
  });

  it('uses MEWTPHOTOS_BACKUP_DIR when initializing settings for a fresh database', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'mp-backupdir-'));
    const db = openDb(path.join(dir, 'fresh.db'));
    const prev = process.env.MEWTPHOTOS_BACKUP_DIR;
    process.env.MEWTPHOTOS_BACKUP_DIR = '/Media/iphonePhotosBackup';
    try {
      const settings = loadSettings(db);
      expect(settings.destination).toBe('/Media/iphonePhotosBackup');
    } finally {
      if (prev === undefined) delete process.env.MEWTPHOTOS_BACKUP_DIR;
      else process.env.MEWTPHOTOS_BACKUP_DIR = prev;
      db.close();
    }
  });
});
