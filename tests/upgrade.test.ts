// Phase 3 server changes: the database upgrade (SRV-06) and the free-space answer (SRV-07).
import { mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it } from 'vitest';
import { API } from '../shared/schemas.ts';
import { all, get, openDb } from '../server/db.ts';
import { startServer, type TestServer } from './helpers.ts';

const open: TestServer[] = [];
afterEach(async () => {
  for (const s of open.splice(0)) await s.app.close();
});

describe('database upgrade', () => {
  it('an old database opens, keeps its rows, and gains the new columns', async () => {
    const file = path.join(await mkdtemp(path.join(os.tmpdir(), 'photosync-upgrade-')), 'old.db');
    // The uploads table as the previous version wrote it: no hidden, pair_id or pair_name columns.
    const old = new DatabaseSync(file);
    old.exec(`
      CREATE TABLE uploads (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, device_id TEXT NOT NULL, filename TEXT NOT NULL,
        size INTEGER NOT NULL, mime TEXT, last_modified INTEGER, asset_id TEXT, temp_path TEXT NOT NULL,
        final_path TEXT, sha256 TEXT, e2e_verified INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL,
        error TEXT, file_id INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      );
      INSERT INTO uploads (id, session_id, device_id, filename, size, temp_path, status, created_at, updated_at)
        VALUES ('u1', 's1', 'd1', 'IMG_1.JPG', 10, '/tmp/x', 'verified', 1, 1);
    `);
    old.close();

    const db = openDb(file);
    const columns = all<{ name: string }>(db, 'PRAGMA table_info(uploads)').map((c) => c.name);
    expect(columns).toEqual(expect.arrayContaining(['hidden', 'pair_id', 'pair_name']));
    expect(get<{ filename: string }>(db, 'SELECT filename FROM uploads WHERE id = ?', 'u1')?.filename).toBe('IMG_1.JPG');
    expect(get<{ user_version: number }>(db, 'PRAGMA user_version')?.user_version).toBe(1);
    db.close();

    // A second open changes nothing: the step has already run.
    openDb(file).close();
  });
});

describe('free space', () => {
  it('the status answer reports the free bytes on the backup drive', async () => {
    const s = await startServer({}, { freeBytes: async () => 123_456 });
    open.push(s);
    const res = await s.phone({ method: 'GET', url: `${API}/status` });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ freeBytes: 123_456 });
  });
});
