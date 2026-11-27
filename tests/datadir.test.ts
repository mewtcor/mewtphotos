import { mkdirSync, mkdtempSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { dataDir, dbFile } from '../server/config.ts';

const saved = { dir: process.env.MEWTPHOTOS_DATA_DIR, local: process.env.LOCALAPPDATA };
afterEach(() => {
  for (const [key, value] of [['MEWTPHOTOS_DATA_DIR', saved.dir], ['LOCALAPPDATA', saved.local]] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

describe('data folder from the old app name', () => {
  it('moves the old folder and its database to the new names, keeping the data', () => {
    const base = mkdtempSync(path.join(os.tmpdir(), 'mp-datadir-'));
    delete process.env.MEWTPHOTOS_DATA_DIR;
    process.env.LOCALAPPDATA = base;
    mkdirSync(path.join(base, 'PhotoSync'));
    writeFileSync(path.join(base, 'PhotoSync', 'photosync.db'), 'history');
    writeFileSync(path.join(base, 'PhotoSync', 'photosync.db-wal'), 'journal');

    const dir = dataDir();
    expect(dir).toBe(path.join(base, 'MewtPhotos'));
    expect(existsSync(path.join(base, 'PhotoSync'))).toBe(false);
    const file = dbFile(dir);
    expect(path.basename(file)).toBe('mewtphotos.db');
    expect(readFileSync(file, 'utf8')).toBe('history');
    expect(readFileSync(file + '-wal', 'utf8')).toBe('journal');
    expect(existsSync(path.join(dir, 'photosync.db'))).toBe(false);
  });

  it('starts fresh when there is no old folder, and never overwrites a new one', () => {
    const base = mkdtempSync(path.join(os.tmpdir(), 'mp-datadir-'));
    delete process.env.MEWTPHOTOS_DATA_DIR;
    process.env.LOCALAPPDATA = base;
    expect(dataDir()).toBe(path.join(base, 'MewtPhotos'));

    mkdirSync(path.join(base, 'MewtPhotos'), { recursive: true });
    mkdirSync(path.join(base, 'PhotoSync'));
    writeFileSync(path.join(base, 'PhotoSync', 'old.txt'), 'x');
    expect(dataDir()).toBe(path.join(base, 'MewtPhotos'));
    expect(existsSync(path.join(base, 'PhotoSync', 'old.txt'))).toBe(true);
  });
});
