import { execFileSync } from 'node:child_process';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { Settings } from '../shared/schemas.ts';
import { get, run, type Db } from './db.ts';
import { HttpError } from './security.ts';

const GB = 1024 ** 3;

/** App state (database, logs) lives outside the backup folder and outside the repo. */
export function dataDir(): string {
  return process.env.PHOTOSYNC_DATA_DIR ?? path.join(process.env.LOCALAPPDATA ?? os.homedir(), 'PhotoSync');
}

/** The real Pictures known folder, which may be redirected (for example into OneDrive). */
function picturesDir(): string {
  if (process.platform === 'win32') {
    try {
      const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', "[Environment]::GetFolderPath('MyPictures')"], {
        encoding: 'utf8',
        timeout: 15_000,
        windowsHide: true,
      }).trim();
      if (out && path.isAbsolute(out)) return out;
    } catch {
      // fall through to the conventional location
    }
  }
  return path.join(os.homedir(), 'Pictures');
}

export function loadSettings(db: Db): Settings {
  const defaults = { organizeByDate: true, maxFileBytes: 50 * GB, quotaBytes: 0, minFreeBytes: 1 * GB, concurrency: 2, stopWithDashboard: true };
  const row = get<{ value: string }>(db, `SELECT value FROM settings WHERE key = 'settings'`);
  if (row) return { ...defaults, ...(JSON.parse(row.value) as Settings) };
  const settings: Settings = { ...defaults, destination: path.join(picturesDir(), 'iPhone Backup') };
  saveSettings(db, settings);
  return settings;
}

export function saveSettings(db: Db, settings: Settings): void {
  run(db, `INSERT INTO settings (key, value) VALUES ('settings', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, JSON.stringify(settings));
}

/** Creates the folder if needed and proves we can write there before accepting it. */
export async function validateDestination(dir: string): Promise<string> {
  if (!path.isAbsolute(dir)) throw new HttpError(400, 'bad_destination', 'Enter a full path such as D:\\Photos\\iPhone Backup.');
  const resolved = path.resolve(dir);
  const probe = path.join(resolved, `.photosync-write-test-${process.pid}`);
  try {
    await mkdir(resolved, { recursive: true });
    await writeFile(probe, '', { flag: 'wx' });
    await rm(probe, { force: true });
  } catch (err) {
    throw new HttpError(400, 'bad_destination', `Cannot write to that folder: ${err instanceof Error ? err.message : String(err)}`);
  }
  return resolved;
}
