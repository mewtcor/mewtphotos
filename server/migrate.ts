// Rewrites stored absolute backup paths in mewtphotos.db when migrating from Windows to Linux Mint
// (or moving the backup folder to a new mount point). Preserves devices, sessions, uploads, and SHA-256 records.
import { all, get, run, tx, type Db } from './db.ts';
import type { Settings } from '../shared/schemas.ts';

export interface MigrateOptions {
  fromPrefix: string;
  toPrefix: string;
  dryRun?: boolean;
  disableStopWithDashboard?: boolean;
}

export interface MigrateReport {
  filesUpdated: number;
  filesUnmatched: number;
  uploadsFinalUpdated: number;
  uploadsTempUpdated: number;
  settingsUpdated: boolean;
  dryRun: boolean;
}

function normalizePrefix(prefix: string): string {
  return prefix.replace(/\\/g, '/').replace(/\/+$/, '');
}

/**
 * Rewrites a stored path whose prefix matches `fromPrefix` (case-insensitive for Windows drive/folder prefixes)
 * to `toPrefix` using POSIX forward slashes. Returns null when the path does not start with `fromPrefix`.
 */
export function rewriteBackupPath(stored: string, fromPrefix: string, toPrefix: string): string | null {
  const normStored = stored.replace(/\\/g, '/');
  const normFrom = normalizePrefix(fromPrefix);
  const normTo = normalizePrefix(toPrefix);
  if (!normFrom) return null;

  const lowerStored = normStored.toLowerCase();
  const lowerFrom = normFrom.toLowerCase();
  if (lowerStored === lowerFrom) return normTo;
  if (!lowerStored.startsWith(lowerFrom + '/')) return null;

  const relative = normStored.slice(normFrom.length + 1);
  return `${normTo}/${relative}`;
}

/**
 * Migrates `files.path`, `uploads.final_path`, `uploads.temp_path`, and `settings.destination` in one transaction.
 * When `dryRun` is true, counts what would change without modifying the database.
 */
export function migrateDbPaths(db: Db, opts: MigrateOptions): MigrateReport {
  const dryRun = Boolean(opts.dryRun);
  const report: MigrateReport = {
    filesUpdated: 0,
    filesUnmatched: 0,
    uploadsFinalUpdated: 0,
    uploadsTempUpdated: 0,
    settingsUpdated: false,
    dryRun,
  };

  const apply = () => {
    for (const row of all<{ id: number; path: string }>(db, 'SELECT id, path FROM files')) {
      const next = rewriteBackupPath(row.path, opts.fromPrefix, opts.toPrefix);
      if (next !== null) {
        report.filesUpdated++;
        if (!dryRun) run(db, 'UPDATE files SET path = ? WHERE id = ?', next, row.id);
      } else {
        report.filesUnmatched++;
      }
    }

    for (const row of all<{ id: string; final_path: string | null; temp_path: string }>(db, 'SELECT id, final_path, temp_path FROM uploads')) {
      if (row.final_path) {
        const nextFinal = rewriteBackupPath(row.final_path, opts.fromPrefix, opts.toPrefix);
        if (nextFinal !== null) {
          report.uploadsFinalUpdated++;
          if (!dryRun) run(db, 'UPDATE uploads SET final_path = ? WHERE id = ?', nextFinal, row.id);
        }
      }
      if (row.temp_path) {
        const nextTemp = rewriteBackupPath(row.temp_path, opts.fromPrefix, opts.toPrefix);
        if (nextTemp !== null) {
          report.uploadsTempUpdated++;
          if (!dryRun) run(db, 'UPDATE uploads SET temp_path = ? WHERE id = ?', nextTemp, row.id);
        }
      }
    }

    const settingsRow = get<{ value: string }>(db, `SELECT value FROM settings WHERE key = 'settings'`);
    if (settingsRow) {
      const parsed = JSON.parse(settingsRow.value) as Settings;
      const nextDest = rewriteBackupPath(parsed.destination, opts.fromPrefix, opts.toPrefix) ?? normalizePrefix(opts.toPrefix);
      const nextStop = opts.disableStopWithDashboard ? false : parsed.stopWithDashboard;
      if (nextDest !== parsed.destination || nextStop !== parsed.stopWithDashboard) {
        report.settingsUpdated = true;
        if (!dryRun) {
          const updated: Settings = { ...parsed, destination: nextDest, stopWithDashboard: nextStop };
          run(db, `UPDATE settings SET value = ? WHERE key = 'settings'`, JSON.stringify(updated));
        }
      }
    }
  };

  if (dryRun) {
    apply();
  } else {
    tx(db, apply);
  }
  return report;
}
