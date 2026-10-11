import { DatabaseSync } from 'node:sqlite';

export type Db = DatabaseSync;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  method TEXT NOT NULL,
  selected_count INTEGER NOT NULL DEFAULT 0,
  unavailable_count INTEGER NOT NULL DEFAULT 0,
  library_count INTEGER,
  started_at INTEGER NOT NULL,
  completed_at INTEGER
);

-- One row per distinct file content stored in the backup.
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  sha256 TEXT NOT NULL UNIQUE,
  path TEXT NOT NULL,
  original_name TEXT NOT NULL,
  size INTEGER NOT NULL,
  mime TEXT,
  captured_at TEXT,
  date_source TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  verified_at INTEGER,
  verify_status TEXT NOT NULL DEFAULT 'ok'
);

-- One row per transfer attempt (including duplicates and failures).
CREATE TABLE IF NOT EXISTS uploads (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  device_id TEXT NOT NULL REFERENCES devices(id),
  filename TEXT NOT NULL,
  size INTEGER NOT NULL,
  mime TEXT,
  last_modified INTEGER,
  asset_id TEXT,
  temp_path TEXT NOT NULL,
  final_path TEXT,
  sha256 TEXT,
  e2e_verified INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error TEXT,
  file_id INTEGER REFERENCES files(id),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS uploads_session ON uploads(session_id);
CREATE INDEX IF NOT EXISTS uploads_status ON uploads(status);
CREATE INDEX IF NOT EXISTS uploads_asset ON uploads(device_id, asset_id);

CREATE TABLE IF NOT EXISTS logs (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  level TEXT NOT NULL,
  code TEXT NOT NULL,
  message TEXT NOT NULL
);
`;

export function openDb(file: string): Db {
  const db = new DatabaseSync(file);
  // synchronous=FULL: a committed "verified" record must survive power loss.
  db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
  db.exec(SCHEMA);
  return db;
}

export function tx<T>(db: Db, fn: () => T): T {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

export interface FileRow {
  id: number;
  sha256: string;
  path: string;
  original_name: string;
  size: number;
  verify_status: string;
}

export interface UploadRow {
  id: string;
  session_id: string;
  device_id: string;
  filename: string;
  size: number;
  mime: string | null;
  last_modified: number | null;
  asset_id: string | null;
  temp_path: string;
  final_path: string | null;
  sha256: string | null;
  e2e_verified: number;
  status: string;
  error: string | null;
  file_id: number | null;
  created_at: number;
  updated_at: number;
}

export interface DeviceRow {
  id: string;
  name: string;
}

type Param = string | number | null;

/** node:sqlite returns loosely typed rows; these keep the casts in one place. */
export function get<T>(db: Db, sql: string, ...params: Param[]): T | undefined {
  return db.prepare(sql).get(...params) as T | undefined;
}

export function all<T>(db: Db, sql: string, ...params: Param[]): T[] {
  return db.prepare(sql).all(...params) as T[];
}

export function run(db: Db, sql: string, ...params: Param[]): void {
  db.prepare(sql).run(...params);
}
