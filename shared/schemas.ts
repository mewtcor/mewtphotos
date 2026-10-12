// API contract shared by the server, the web UI and (later) a native iOS client.
import { z } from 'zod';

export const API = '/api/v1';
export const CHUNK_SIZE = 8 * 1024 * 1024;
export const UPLOAD_CONTENT_TYPE = 'application/offset+octet-stream';

/** Shown whenever a session succeeded but the sender could not enumerate the Photos library. */
export const COVERAGE_NOTICE =
  'All selected files transferred successfully. Complete iPhone photo library coverage has not been verified.';

const sha256Hex = z.string().regex(/^[0-9a-f]{64}$/, 'expected lowercase hex SHA-256');

export const PairRequest = z.object({
  code: z.string().min(1).max(32),
  deviceName: z.string().trim().min(1).max(80),
});

export const SessionCreate = z.object({
  method: z.enum(['safari', 'shortcut', 'native']),
  selectedCount: z.number().int().min(0).max(1_000_000),
  /** Only a sender that can enumerate the whole Photos library (a native app) may report this. */
  libraryCount: z.number().int().min(0).optional(),
});

export const SessionComplete = z.object({
  /** Assets the sender selected but could not read (for example iCloud-only originals). */
  unavailableCount: z.number().int().min(0).default(0),
});

export const UploadCreate = z.object({
  sessionId: z.uuid(),
  filename: z.string().min(1).max(255),
  size: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  mimeType: z.string().max(100).default(''),
  lastModified: z.number().int().min(0).optional(),
  /** Stable sender-side identifier (PhotoKit localIdentifier); browsers cannot provide one. */
  assetId: z.string().max(200).optional(),
  /** If the sender already knows the hash, a duplicate is detected before any bytes are sent. */
  sha256: sha256Hex.optional(),
});

export const UploadFinish = z.object({ sha256: sha256Hex.optional() });

export const AssetCheck = z.object({
  items: z.array(z.object({ assetId: z.string().max(200).optional(), sha256: sha256Hex.optional() })).max(5000),
});

export const SettingsUpdate = z.object({
  destination: z.string().min(3).max(500).optional(),
  organizeByDate: z.boolean().optional(),
  maxFileBytes: z.number().int().positive().optional(),
  quotaBytes: z.number().int().min(0).optional(),
  minFreeBytes: z.number().int().min(0).optional(),
  concurrency: z.number().int().min(1).max(6).optional(),
  stopWithDashboard: z.boolean().optional(),
});

export interface Settings {
  destination: string;
  /** Store under <destination>\YYYY\MM. */
  organizeByDate: boolean;
  maxFileBytes: number;
  /** Maximum total bytes of backed-up files; 0 = unlimited. */
  quotaBytes: number;
  /** Refuse uploads that would leave less than this much free disk space. */
  minFreeBytes: number;
  /** Parallel uploads used by the phone page. */
  concurrency: number;
  /** Shut the app down once the last dashboard tab is closed and no transfer is under way. */
  stopWithDashboard: boolean;
}

export type UploadStatus = 'receiving' | 'finalizing' | 'verified' | 'duplicate' | 'failed' | 'cancelled' | 'retried';

export interface UploadState {
  uploadId: string;
  status: UploadStatus;
  offset: number;
  size: number;
}

/** Returned only after the file is on disk, re-read, hashed and committed to the database. */
export interface UploadResult {
  uploadId: string;
  status: 'verified' | 'duplicate';
  sha256: string;
  /** True only when the sender supplied a hash and it matched the bytes read back from disk. */
  endToEndVerified: boolean;
  /** Location inside the backup folder (for a duplicate: where the existing copy lives). */
  path: string;
}

export interface SessionSummary {
  id: string;
  deviceName: string;
  method: 'safari' | 'shortcut' | 'native';
  startedAt: number;
  completedAt: number | null;
  /** null = the sender cannot count the Photos library (always the case for Safari and Shortcuts). */
  libraryCount: number | null;
  selected: number;
  submitted: number;
  received: number;
  verified: number;
  duplicates: number;
  failed: number;
  unavailable: number;
  inProgress: number;
  bytesStored: number;
  /** Never true in this release: no supported sender can prove whole-library coverage. */
  libraryCoverageVerified: false;
  message: string;
}

export interface VerifyReport {
  startedAt: number;
  finishedAt: number;
  checked: number;
  ok: number;
  missing: string[];
  corrupt: string[];
  untracked: string[];
  databaseProblems: string[];
}

export interface Overview {
  server: {
    lanUrl: string | null;
    port: number;
    startedAt: number;
    restartRequired: boolean;
    version: string;
  };
  settings: Settings;
  storage: { freeBytes: number; backupBytes: number };
  totals: { files: number; bytes: number; duplicates: number; failed: number; endToEndVerified: number };
  sessions: SessionSummary[];
  failures: { id: string; filename: string; error: string; at: number; device: string }[];
  logs: { ts: number; level: string; code: string; message: string }[];
  devices: { id: string; name: string; createdAt: number; lastSeenAt: number | null }[];
  lastVerify: VerifyReport | null;
  verifyRunning: boolean;
}

export interface PairingInfo {
  code: string;
  expiresAt: number;
  url: string | null;
  qrSvg: string | null;
}

export interface ClientStatus {
  deviceName: string;
  serverName: string;
  chunkSize: number;
  concurrency: number;
  maxFileBytes: number;
  /** Free bytes on the backup drive, so the app can stop before preparing a file that will not fit. */
  freeBytes: number;
}
