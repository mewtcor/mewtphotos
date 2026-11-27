// Re-reads every stored file and compares it with the hash recorded at backup time.
import { readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { VerifyReport } from '../shared/schemas.ts';
import { all, get, run, tx, type Db, type FileRow } from './db.ts';
import { hashFile } from './engine.ts';

const MAX_UNTRACKED_LISTED = 200;
const DB_FLUSH_BATCH = 25;

export async function verifyBackup(
  db: Db,
  destination: string,
  onProgress?: (done: number, total: number) => void,
  shouldYield?: () => boolean,
): Promise<VerifyReport> {
  const report: VerifyReport = { startedAt: Date.now(), finishedAt: 0, checked: 0, ok: 0, missing: [], corrupt: [], untracked: [], databaseProblems: [] };
  const files = all<FileRow>(db, 'SELECT * FROM files ORDER BY id');
  const pendingUpdates: Array<{ id: number; status: 'ok' | 'missing' | 'corrupt'; at: number }> = [];

  const flushUpdates = () => {
    if (pendingUpdates.length === 0) return;
    tx(db, () => {
      for (const u of pendingUpdates) {
        run(db, 'UPDATE files SET verify_status = ?, verified_at = ? WHERE id = ?', u.status, u.at, u.id);
      }
    });
    pendingUpdates.length = 0;
  };

  for (const file of files) {
    // Let active uploads get disk I/O priority so verification never starves or times out a backup.
    if (shouldYield?.()) {
      flushUpdates();
      await new Promise((r) => setTimeout(r, 150));
    }
    let status: 'ok' | 'missing' | 'corrupt';
    try {
      const st = await stat(file.path);
      status = st.size === file.size && (await hashFile(file.path)) === file.sha256 ? 'ok' : 'corrupt';
    } catch {
      status = 'missing';
    }
    if (status === 'ok') report.ok++;
    else report[status].push(file.path);
    pendingUpdates.push({ id: file.id, status, at: Date.now() });
    if (pendingUpdates.length >= DB_FLUSH_BATCH) flushUpdates();
    report.checked++;
    onProgress?.(report.checked, files.length);
  }
  flushUpdates();

  // Database consistency
  const integrity = all<{ integrity_check: string }>(db, 'PRAGMA integrity_check').map((r) => r.integrity_check);
  if (integrity.join() !== 'ok') report.databaseProblems.push(`SQLite integrity check: ${integrity.join('; ')}`);
  const dangling = get<{ n: number }>(db, `SELECT COUNT(*) AS n FROM uploads u LEFT JOIN files f ON f.id = u.file_id WHERE u.status IN ('verified', 'duplicate') AND f.id IS NULL`)!.n;
  if (dangling > 0) report.databaseProblems.push(`${dangling} completed upload record(s) do not point at a stored file.`);
  const stuck = get<{ n: number }>(db, `SELECT COUNT(*) AS n FROM uploads WHERE status = 'finalizing'`)!.n;
  if (stuck > 0) report.databaseProblems.push(`${stuck} upload(s) are stuck mid-save; restart the server to repair them.`);

  // Files in the backup folder that no record describes (copied in by hand, or pre-existing).
  const tracked = new Set(files.map((f) => path.resolve(f.path).toLowerCase()));
  const walk = async (dir: string): Promise<void> => {
    for (const entry of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== '.incoming') await walk(full);
      } else if (!tracked.has(path.resolve(full).toLowerCase()) && report.untracked.length < MAX_UNTRACKED_LISTED) {
        report.untracked.push(full);
      }
    }
  };
  await walk(destination);

  report.finishedAt = Date.now();
  run(db, `INSERT INTO settings (key, value) VALUES ('lastVerify', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, JSON.stringify(report));
  return report;
}
