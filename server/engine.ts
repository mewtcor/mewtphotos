// The transfer engine: resumable receive -> read-back hash -> duplicate check -> atomic
// placement -> database commit. Nothing here reports success before that last step.
import { createHash, randomUUID } from 'node:crypto';
import { constants, createReadStream, createWriteStream } from 'node:fs';
import { copyFile, mkdir, open, readdir, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Transform, type Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { z } from 'zod';
import { COVERAGE_NOTICE, type SessionSummary, type Settings, type UploadCreate, type UploadResult, type UploadState } from '../shared/schemas.ts';
import { all, get, run, tx, type Db, type DeviceRow, type FileRow, type UploadRow } from './db.ts';
import { readCaptureDate, type CaptureDate } from './metadata.ts';
import { HttpError, resolveInside, safeMediaFilename } from './security.ts';

export interface Ctx {
  db: Db;
  settings(): Settings;
  /** Writes to the structured log file and to the dashboard's log table. Never pass secrets. */
  log(level: 'info' | 'warn' | 'error', code: string, message: string): void;
  /** Pushes a live event to the dashboard. */
  emit(event: string, data?: unknown): void;
  freeBytes(dir: string): Promise<number>;
  /** Upload ids with a chunk or finalization in flight (one writer per upload). */
  active: Set<string>;
  /** Tail of the placement queue; see serialize(). */
  placing: Promise<unknown>;
  /** Total payload bytes received since start, for the speed display. */
  bytesIn: number;
}

const STALE_UPLOAD_MS = 7 * 24 * 60 * 60 * 1000;
/** A chunk that receives no bytes for this long is abandoned so the upload can be resumed. */
export const timeouts = { chunkIdleMs: 60_000 };
/** Test seam: lets a test fail the final move once, to prove the upload goes back to resumable (SRV-05). */
export const seams: { beforeMove?: () => void } = {};

function errorCode(err: unknown): string {
  return typeof err === 'object' && err !== null && 'code' in err ? String((err as { code: unknown }).code) : '';
}

async function statOrNull(file: string) {
  try {
    return await stat(file);
  } catch (err) {
    if (errorCode(err) === 'ENOENT') return null;
    throw err;
  }
}

export async function hashFile(file: string): Promise<string> {
  const hash = createHash('sha256');
  await pipeline(createReadStream(file), hash);
  return hash.digest('hex');
}

/** The stored copy exists and still has the recorded content (full re-read, not just a stat). */
async function fileIntact(file: FileRow): Promise<boolean> {
  const st = await statOrNull(file.path);
  return !!st && st.isFile() && st.size === file.size && (await hashFile(file.path)) === file.sha256;
}

function incomingDir(settings: Settings): string {
  return path.join(settings.destination, '.incoming');
}

function plausibleTime(ms: number | null): ms is number {
  return ms !== null && ms > Date.UTC(1990, 0, 1) && ms < Date.now() + 86_400_000;
}

/** Turns filesystem/stream errors into user-facing errors and logs the diagnosis once. */
function classify(ctx: Ctx, filename: string, err: unknown): HttpError {
  if (err instanceof HttpError) return err;
  const code = errorCode(err);
  if (code === 'ENOSPC') {
    ctx.log('error', 'insufficient_space', `The backup drive ran out of space while saving "${filename}". Free up space or choose another backup folder.`);
    return new HttpError(507, 'insufficient_space', 'The backup drive is full.');
  }
  if (code === 'EACCES' || code === 'EPERM') {
    ctx.log('error', 'permission_denied', `Windows denied access while saving "${filename}". Check that the backup folder is writable and not blocked by antivirus or Controlled Folder Access.`);
    return new HttpError(500, 'permission_denied', 'Windows denied access to the backup folder.');
  }
  if (code === 'UPLOAD_TIMEOUT') {
    ctx.log('warn', 'upload_timeout', `Upload timed out: no data arrived for ${timeouts.chunkIdleMs / 1000}s while receiving "${filename}". Check the Wi-Fi signal; the upload can resume.`);
    return new HttpError(408, 'upload_timeout', 'Upload timed out.');
  }
  if (code === 'ERR_STREAM_PREMATURE_CLOSE' || code === 'ECONNRESET' || code === 'ECONNABORTED') {
    ctx.log('warn', 'client_disconnected', `Connection lost while receiving "${filename}". If the iPhone screen locked or Safari went to the background, iOS suspended the upload; it resumes from where it stopped.`);
    return new HttpError(400, 'client_disconnected', 'Connection lost during upload.');
  }
  ctx.log('error', 'write_failed', `Unexpected error while saving "${filename}": ${err instanceof Error ? err.message : String(err)}`);
  return new HttpError(500, 'write_failed', 'The server could not save the file.');
}

/** Bytes safely on disk for this upload. Always measured from the file, never trusted from the DB. */
export async function currentOffset(upload: UploadRow): Promise<number> {
  return (await statOrNull(upload.temp_path))?.size ?? 0;
}

export function getUpload(ctx: Ctx, id: string, deviceId: string): UploadRow {
  const upload = get<UploadRow>(ctx.db, 'SELECT * FROM uploads WHERE id = ? AND device_id = ?', id, deviceId);
  if (!upload) throw new HttpError(404, 'unknown_upload', 'Unknown upload.');
  return upload;
}

function resultOf(ctx: Ctx, uploadId: string): UploadResult {
  const row = get<{ status: 'verified' | 'duplicate'; sha256: string; e2e_verified: number; path: string }>(
    ctx.db,
    'SELECT u.status, u.sha256, u.e2e_verified, f.path FROM uploads u JOIN files f ON f.id = u.file_id WHERE u.id = ?',
    uploadId,
  );
  if (!row) throw new HttpError(500, 'inconsistent_record', 'Upload record has no stored file.');
  return { uploadId, status: row.status, sha256: row.sha256, endToEndVerified: row.e2e_verified === 1, path: row.path };
}

export async function createUpload(ctx: Ctx, device: DeviceRow, body: z.infer<typeof UploadCreate>): Promise<UploadState | UploadResult> {
  const settings = ctx.settings();
  const filename = safeMediaFilename(body.filename, body.mimeType);
  if (body.size > settings.maxFileBytes) {
    throw new HttpError(413, 'file_too_large', `"${filename}" is larger than the configured per-file limit.`);
  }
  if (!get(ctx.db, 'SELECT id FROM sessions WHERE id = ? AND device_id = ?', body.sessionId, device.id)) {
    throw new HttpError(404, 'unknown_session', 'Unknown backup session.');
  }
  // SRV-04: the same item sent again in one session gets the record it already has, not a second row that
  // would inflate the session's counts. Matched by hash, or by asset identifier and size; never by name alone.
  const same = body.sha256
    ? get<UploadRow>(ctx.db, `SELECT * FROM uploads WHERE session_id = ? AND sha256 = ? AND status IN ('verified', 'duplicate') LIMIT 1`, body.sessionId, body.sha256)
    : body.assetId
      ? get<UploadRow>(ctx.db, `SELECT * FROM uploads WHERE session_id = ? AND asset_id = ? AND size = ? AND status IN ('verified', 'duplicate') LIMIT 1`, body.sessionId, body.assetId, body.size)
      : undefined;
  // Reported as a duplicate, as a re-announced known hash always has been: nothing new was stored.
  if (same) return { ...resultOf(ctx, same.id), status: 'duplicate' };
  const now = Date.now();
  const id = randomUUID();
  const insert = (status: string, tempPath: string, extra: { sha256?: string; fileId?: number } = {}) =>
    run(
      ctx.db,
      `INSERT INTO uploads (id, session_id, device_id, filename, size, mime, last_modified, asset_id, temp_path, sha256, e2e_verified, status, file_id, created_at, updated_at, hidden, pair_id, pair_name)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id, body.sessionId, device.id, filename, body.size, body.mimeType || null, body.lastModified ?? null, body.assetId ?? null,
      tempPath, extra.sha256 ?? null, extra.sha256 ? 1 : 0, status, extra.fileId ?? null, now, now,
      body.hidden ? 1 : 0, body.pairId ?? null, body.pairName ?? null,
    );

  // A sender that already knows the hash (native app) can skip sending known content.
  if (body.sha256) {
    const existing = get<FileRow>(ctx.db, 'SELECT * FROM files WHERE sha256 = ?', body.sha256);
    if (existing && (await fileIntact(existing))) {
      insert('duplicate', '', { sha256: body.sha256, fileId: existing.id });
      ctx.log('info', 'duplicate', `"${filename}" is already backed up at ${existing.path}; nothing was transferred.`);
      ctx.emit('change');
      return resultOf(ctx, id);
    }
  }

  // Resume an interrupted transfer of what is, by name + size + modification time, the same file.
  if (body.lastModified !== undefined) {
    const prior = get<UploadRow>(
      ctx.db,
      `SELECT * FROM uploads WHERE device_id = ? AND filename = ? AND size = ? AND last_modified = ? AND status = 'receiving'
       ORDER BY created_at DESC LIMIT 1`,
      device.id, filename, body.size, body.lastModified,
    );
    // While the earlier attempt is still open (its stalled connection has not timed out yet), say so: a new
    // upload here would resend the whole file. The phone waits and asks again.
    if (prior && ctx.active.has(prior.id)) {
      throw new HttpError(409, 'upload_busy', 'The earlier attempt at this file is still open. Trying again shortly will resume it.');
    }
    if (prior) {
      run(ctx.db, 'UPDATE uploads SET session_id = ?, updated_at = ? WHERE id = ?', body.sessionId, now, prior.id);
      return { uploadId: prior.id, status: 'receiving', offset: await currentOffset(prior), size: prior.size };
    }
  }

  try {
    await mkdir(incomingDir(settings), { recursive: true });
    // ponytail: space and quota are checked per upload at start, not reserved, so parallel
    // large uploads can overshoot by up to (concurrency - 1) files. A real ENOSPC is still
    // caught and reported while writing. Reserve in-flight sizes here if that ever matters.
    const free = await ctx.freeBytes(settings.destination);
    if (free - body.size < settings.minFreeBytes) {
      ctx.log('error', 'insufficient_space', `Not enough free disk space for "${filename}". Free up space or choose another backup folder.`);
      throw new HttpError(507, 'insufficient_space', 'Not enough free space on the backup drive.');
    }
    if (settings.quotaBytes > 0) {
      const used = get<{ n: number }>(ctx.db, 'SELECT COALESCE(SUM(size), 0) AS n FROM files')!.n;
      if (used + body.size > settings.quotaBytes) {
        ctx.log('error', 'quota_exceeded', `Storing "${filename}" would exceed the configured backup storage quota.`);
        throw new HttpError(507, 'quota_exceeded', 'The backup storage quota is full.');
      }
    }
    const tempPath = path.join(incomingDir(settings), `${id}.part`);
    await writeFile(tempPath, '', { flag: 'wx' });
    // An earlier failed attempt at this file in this session is superseded by this one.
    run(ctx.db, `UPDATE uploads SET status = 'retried' WHERE session_id = ? AND filename = ? AND size = ? AND status IN ('failed', 'cancelled')`, body.sessionId, filename, body.size);
    insert('receiving', tempPath);
  } catch (err) {
    throw classify(ctx, filename, err);
  }
  ctx.emit('change');
  return { uploadId: id, status: 'receiving', offset: 0, size: body.size };
}

/** Appends request bytes at `offset`. Returns the new offset. Partial data stays for resume. */
export async function appendChunk(ctx: Ctx, upload: UploadRow, offset: number, body: Readable): Promise<number> {
  if (upload.status !== 'receiving') throw new HttpError(409, 'not_receiving', `This upload is already ${upload.status}.`);
  if (ctx.active.has(upload.id)) throw new HttpError(409, 'upload_busy', 'Another request is writing to this upload.');
  ctx.active.add(upload.id);
  let idle: NodeJS.Timeout | undefined;
  try {
    if (!(await statOrNull(upload.temp_path))) {
      await mkdir(path.dirname(upload.temp_path), { recursive: true });
      await writeFile(upload.temp_path, '', { flag: 'wx' });
    }
    const current = await currentOffset(upload);
    if (offset !== current) {
      throw new HttpError(409, 'offset_mismatch', 'Upload offset does not match the data on disk.', { offset: current });
    }
    let written = offset;
    const counter = new Transform({
      transform(chunk: Buffer, _enc, done) {
        armIdleTimer();
        written += chunk.length;
        ctx.bytesIn += chunk.length;
        if (written > upload.size) done(new HttpError(413, 'too_much_data', 'More data was sent than the declared file size.'));
        else done(null, chunk);
      },
    });
    const fail = (code: string) => counter.destroy(Object.assign(new Error(code), { code }));
    const armIdleTimer = () => {
      clearTimeout(idle);
      idle = setTimeout(() => fail('UPLOAD_TIMEOUT'), timeouts.chunkIdleMs);
    };
    // The request is piped by hand rather than through pipeline(): pipeline would destroy
    // the connection on a disk error, and the sender would never receive the reason.
    body.on('error', () => fail('ECONNRESET'));
    body.on('close', () => {
      if (!body.readableEnded) fail('ERR_STREAM_PREMATURE_CLOSE');
    });
    if (body.destroyed && !body.readableEnded) throw Object.assign(new Error('closed'), { code: 'ERR_STREAM_PREMATURE_CLOSE' });
    armIdleTimer();
    try {
      body.pipe(counter);
      await pipeline(counter, createWriteStream(upload.temp_path, { flags: 'r+', start: offset }));
    } catch (err) {
      body.unpipe(counter);
      if (errorCode(err) === 'UPLOAD_TIMEOUT') body.destroy();
      else body.resume(); // discard the rest of this request so the error response can be delivered
      throw err;
    }
    run(ctx.db, 'UPDATE uploads SET updated_at = ? WHERE id = ?', Date.now(), upload.id);
    return await currentOffset(upload);
  } catch (err) {
    throw classify(ctx, upload.filename, err);
  } finally {
    clearTimeout(idle);
    ctx.active.delete(upload.id);
  }
}

function markFailed(ctx: Ctx, uploadId: string, error: string): void {
  run(ctx.db, `UPDATE uploads SET status = 'failed', error = ?, updated_at = ? WHERE id = ?`, error, Date.now(), uploadId);
  ctx.emit('change');
}

/** Placement decisions (duplicate check, name choice, rename) run one at a time. */
function serialize<T>(ctx: Ctx, fn: () => Promise<T>): Promise<T> {
  const result = ctx.placing.then(fn);
  ctx.placing = result.catch(() => undefined);
  return result;
}

async function syncFile(file: string): Promise<void> {
  const fh = await open(file, 'r+');
  try {
    await fh.sync();
  } finally {
    await fh.close();
  }
}

function commitStored(ctx: Ctx, upload: UploadRow, sha256: string, finalPath: string, e2e: boolean, capturedAt: string | null, dateSource: string): void {
  const now = Date.now();
  tx(ctx.db, () => {
    run(
      ctx.db,
      `INSERT INTO files (sha256, path, original_name, size, mime, captured_at, date_source, created_at, verified_at, verify_status)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'ok')
       ON CONFLICT(sha256) DO UPDATE SET path = excluded.path, verified_at = excluded.verified_at, verify_status = 'ok'`,
      sha256, finalPath, upload.filename, upload.size, upload.mime, capturedAt, dateSource, now, now,
    );
    const file = get<{ id: number }>(ctx.db, 'SELECT id FROM files WHERE sha256 = ?', sha256)!;
    run(
      ctx.db,
      `UPDATE uploads SET status = 'verified', sha256 = ?, final_path = ?, e2e_verified = ?, file_id = ?, error = NULL, updated_at = ? WHERE id = ?`,
      sha256, finalPath, e2e ? 1 : 0, file.id, now, upload.id,
    );
  });
}

async function place(ctx: Ctx, upload: UploadRow, sha256: string, e2e: boolean, capture: CaptureDate | null): Promise<void> {
  const settings = ctx.settings();
  const existing = get<FileRow>(ctx.db, 'SELECT * FROM files WHERE sha256 = ?', sha256);
  if (existing) {
    if (await fileIntact(existing)) {
      run(
        ctx.db,
        `UPDATE uploads SET status = 'duplicate', sha256 = ?, e2e_verified = ?, file_id = ?, updated_at = ? WHERE id = ?`,
        sha256, e2e ? 1 : 0, existing.id, Date.now(), upload.id,
      );
      await rm(upload.temp_path, { force: true });
      ctx.log('info', 'duplicate', `"${upload.filename}" is already backed up at ${existing.path}; no second copy was created.`);
      return;
    }
    ctx.log('error', 'stored_file_damaged', `The earlier backup copy at ${existing.path} is missing or damaged. Storing the new upload and pointing the record at it.`);
  }

  // A Live Photo's other part may already be stored: this part then joins its folder and takes its name.
  const mate = upload.pair_id
    ? get<{ path: string }>(
        ctx.db,
        `SELECT f.path FROM uploads u JOIN files f ON f.id = u.file_id
         WHERE u.device_id = ? AND u.pair_id = ? AND u.id != ? AND u.status IN ('verified', 'duplicate') LIMIT 1`,
        upload.device_id, upload.pair_id, upload.id,
      )
    : undefined;

  // Folder: the other part's folder; otherwise the embedded capture date (or the documented fallback).
  let when: { year: string; month: string; capturedAt: string | null; source: string };
  let dir: string;
  if (mate) {
    dir = path.dirname(mate.path);
    when = capture ?? { year: '', month: '', capturedAt: null, source: 'paired' };
  } else {
    if (capture) {
      when = capture;
    } else {
      const trusted = plausibleTime(upload.last_modified);
      const d = new Date(trusted ? upload.last_modified! : Date.now());
      when = { year: String(d.getFullYear()), month: String(d.getMonth() + 1).padStart(2, '0'), capturedAt: null, source: trusted ? 'file-modified' : 'received' };
    }
    // Hidden items keep their own tree so they never mix with the ordinary library.
    const base = upload.hidden ? path.join(settings.destination, 'Hidden') : settings.destination;
    dir = settings.organizeByDate ? resolveInside(base, when.year, when.month) : path.resolve(base);
  }
  await mkdir(dir, { recursive: true });

  // Collision-safe name: never replace a different file; adopt an identical one.
  const { name: stem, ext } = path.parse(upload.filename);
  let target = '';
  let adopted = false;
  if (mate) {
    const candidate = resolveInside(dir, `${path.parse(mate.path).name}${ext}`);
    const st = await statOrNull(candidate);
    if (!st) target = candidate;
    else if (st.isFile() && st.size === upload.size && (await hashFile(candidate)) === sha256) {
      target = candidate;
      adopted = true;
    } else {
      throw new HttpError(409, 'pair_name_taken', `The other part of this Live Photo cannot take the matching name in its folder. Nothing was stored; send it again.`);
    }
  } else {
    const pairExt = upload.pair_name ? path.extname(upload.pair_name) : '';
    for (let n = 1; n <= 10_000 && !target; n++) {
      const stemN = n === 1 ? stem : `${stem} (${n})`;
      // A pair's first part also needs the other part's name free, so the two still match when stored.
      if (pairExt && (await statOrNull(resolveInside(dir, `${stemN}${pairExt}`)))) continue;
      const candidate = resolveInside(dir, `${stemN}${ext}`);
      const st = await statOrNull(candidate);
      if (!st) target = candidate;
      else if (st.isFile() && st.size === upload.size && (await hashFile(candidate)) === sha256) {
        target = candidate;
        adopted = true;
      }
    }
  }
  if (!target) throw new HttpError(500, 'no_free_name', `Could not find a free filename for "${upload.filename}".`);

  if (adopted) {
    await rm(upload.temp_path, { force: true });
  } else {
    // Record the intent first so a crash between rename and commit is recoverable (see recover()).
    run(ctx.db, `UPDATE uploads SET status = 'finalizing', final_path = ?, sha256 = ?, e2e_verified = ?, updated_at = ? WHERE id = ?`, target, sha256, e2e ? 1 : 0, Date.now(), upload.id);
    try {
      seams.beforeMove?.();
      await rename(upload.temp_path, target);
    } catch (err) {
      if (errorCode(err) !== 'EXDEV') throw err;
      // Backup folder was moved to another drive mid-upload: copy, verify the copy, then drop the temp.
      try {
        await copyFile(upload.temp_path, target, constants.COPYFILE_EXCL);
        await syncFile(target);
      } catch (copyErr) {
        // A half-copied target is ours to remove; EEXIST means someone else's file is there, so it stays.
        if (errorCode(copyErr) !== 'EEXIST') await rm(target, { force: true });
        throw copyErr;
      }
      if ((await hashFile(target)) !== sha256) {
        await rm(target, { force: true });
        throw new Error('copy to the backup folder did not verify');
      }
      await rm(upload.temp_path, { force: true });
    }
  }
  commitStored(ctx, upload, sha256, target, e2e, when.capturedAt, when.source);
  ctx.log('info', 'stored', `Stored and verified "${upload.filename}" at ${target}.`);
}

/**
 * Completes an upload. Resolves only once the file is in the backup folder, its bytes have
 * been re-read from disk and hashed, and the record is committed. Safe to call again.
 */
export async function finishUpload(ctx: Ctx, upload: UploadRow, clientSha256: string | undefined): Promise<UploadResult> {
  if (upload.status === 'verified' || upload.status === 'duplicate') return resultOf(ctx, upload.id);
  if (upload.status !== 'receiving') throw new HttpError(409, 'not_receiving', `This upload is ${upload.status}${upload.error ? `: ${upload.error}` : ''}.`);
  if (ctx.active.has(upload.id)) throw new HttpError(409, 'upload_busy', 'This upload is still being written.');
  ctx.active.add(upload.id);
  try {
    const offset = await currentOffset(upload);
    if (offset !== upload.size) {
      throw new HttpError(409, 'incomplete', `Only ${offset} of ${upload.size} bytes have been received.`, { offset });
    }
    await syncFile(upload.temp_path);
    const sha256 = await hashFile(upload.temp_path);
    if (clientSha256 && clientSha256 !== sha256) {
      await rm(upload.temp_path, { force: true });
      markFailed(ctx, upload.id, 'hash_mismatch');
      ctx.log('error', 'corrupt_upload', `"${upload.filename}" arrived corrupted (SHA-256 differs from the sender's). Nothing was stored; send it again.`);
      throw new HttpError(422, 'hash_mismatch', 'The received file does not match the hash computed on the sender. Nothing was stored.');
    }
    const capture = await readCaptureDate(upload.temp_path, path.extname(upload.filename).slice(1));
    if (plausibleTime(upload.last_modified)) {
      const t = new Date(upload.last_modified);
      await utimes(upload.temp_path, t, t).catch(() => undefined); // timestamp only; content untouched
    }
    await serialize(ctx, () => place(ctx, upload, sha256, !!clientSha256, capture));
    ctx.emit('change');
    return resultOf(ctx, upload.id);
  } catch (err) {
    // SRV-05: a failed final move goes back to a resumable upload. The temp file is still complete, so a
    // retry finishes it without restarting the PC app.
    const row = get<{ status: string }>(ctx.db, 'SELECT status FROM uploads WHERE id = ?', upload.id);
    if (row?.status === 'finalizing') {
      run(ctx.db, `UPDATE uploads SET status = 'receiving', final_path = NULL, sha256 = NULL, updated_at = ? WHERE id = ?`, Date.now(), upload.id);
      ctx.log('warn', 'move_retry', `Saving "${upload.filename}" failed at the final move; it is back in line to finish on retry.`);
    }
    throw classify(ctx, upload.filename, err);
  } finally {
    ctx.active.delete(upload.id);
  }
}

export async function cancelUpload(ctx: Ctx, upload: UploadRow): Promise<void> {
  if (upload.status !== 'receiving') return;
  if (ctx.active.has(upload.id)) throw new HttpError(409, 'upload_busy', 'This upload is being written; try again in a moment.');
  run(ctx.db, `UPDATE uploads SET status = 'cancelled', updated_at = ? WHERE id = ?`, Date.now(), upload.id);
  await rm(upload.temp_path, { force: true });
  ctx.emit('change');
}

/**
 * Run once at startup. Repairs anything a crash or power cut left half-done, so that every
 * record is either a resumable partial upload or a verified file - never something in between.
 */
export async function recover(ctx: Ctx): Promise<void> {
  for (const upload of all<UploadRow>(ctx.db, `SELECT * FROM uploads WHERE status = 'finalizing'`)) {
    const finalPath = upload.final_path ?? '';
    const [temp, final] = await Promise.all([statOrNull(upload.temp_path), finalPath ? statOrNull(finalPath) : null]);
    if (temp) {
      // Rename never happened (or a cross-drive copy was cut short): back to resumable.
      if (final) await rm(finalPath, { force: true });
      run(ctx.db, `UPDATE uploads SET status = 'receiving', final_path = NULL, sha256 = NULL, updated_at = ? WHERE id = ?`, Date.now(), upload.id);
      ctx.log('warn', 'recovered', `Finalizing "${upload.filename}" was interrupted; it can be completed by retrying.`);
    } else if (final && upload.sha256 && (await hashFile(finalPath)) === upload.sha256) {
      // File reached the backup folder but the record was not committed: finish the commit.
      commitStored(ctx, upload, upload.sha256, finalPath, upload.e2e_verified === 1, null, 'received');
      ctx.log('warn', 'recovered', `Completed the interrupted record for "${upload.filename}" after verifying the stored file.`);
    } else {
      markFailed(ctx, upload.id, 'lost_during_finalize');
      ctx.log('error', 'recovery_failed', `"${upload.filename}" was lost when the server stopped mid-save. Send it again.`);
    }
  }

  const cutoff = Date.now() - STALE_UPLOAD_MS;
  for (const upload of all<UploadRow>(ctx.db, `SELECT * FROM uploads WHERE status = 'receiving' AND updated_at < ?`, cutoff)) {
    await rm(upload.temp_path, { force: true });
    markFailed(ctx, upload.id, 'expired');
  }

  // Temp files no record points at (only ever our own *.part files in .incoming).
  const dir = incomingDir(ctx.settings());
  const known = new Set(all<{ temp_path: string }>(ctx.db, `SELECT temp_path FROM uploads WHERE status = 'receiving'`).map((r) => path.resolve(r.temp_path)));
  for (const name of await readdir(dir).catch(() => [] as string[])) {
    const full = path.resolve(dir, name);
    if (name.endsWith('.part') && !known.has(full)) await rm(full, { force: true });
  }
}

export function sessionSummary(db: Db, sessionId: string): SessionSummary | null {
  const s = get<{ id: string; method: SessionSummary['method']; selected_count: number; unavailable_count: number; library_count: number | null; started_at: number; completed_at: number | null; device: string }>(
    db,
    'SELECT s.*, d.name AS device FROM sessions s JOIN devices d ON d.id = s.device_id WHERE s.id = ?',
    sessionId,
  );
  if (!s) return null;
  const counts: Record<string, { n: number; bytes: number }> = {};
  for (const row of all<{ status: string; n: number; bytes: number }>(db, 'SELECT status, COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM uploads WHERE session_id = ? GROUP BY status', sessionId)) {
    counts[row.status] = row;
  }
  const n = (status: string) => counts[status]?.n ?? 0;
  const verified = n('verified');
  const duplicates = n('duplicate');
  const failed = n('failed');
  const inProgress = n('receiving') + n('finalizing');
  const submitted = verified + duplicates + failed + inProgress + n('cancelled');
  const safe = verified + duplicates;
  const selected = Math.max(s.selected_count, submitted);

  let message: string;
  if (inProgress > 0) message = `${safe} of ${selected} selected files are safely stored so far; ${inProgress} still transferring.`;
  else if (selected > 0 && safe === selected && failed === 0 && s.unavailable_count === 0) message = COVERAGE_NOTICE;
  else {
    const parts = [`${safe} of ${selected} selected files are safely stored`];
    if (failed > 0) parts.push(`${failed} failed`);
    if (s.unavailable_count > 0) parts.push(`${s.unavailable_count} could not be read on the iPhone`);
    const missing = selected - safe - failed - s.unavailable_count - n('cancelled');
    if (missing > 0) parts.push(`${missing} never reached this computer`);
    if (n('cancelled') > 0) parts.push(`${n('cancelled')} cancelled`);
    message = `${parts.join('; ')}. Complete iPhone photo library coverage has not been verified.`;
  }

  return {
    id: s.id,
    deviceName: s.device,
    method: s.method,
    startedAt: s.started_at,
    completedAt: s.completed_at,
    libraryCount: s.library_count,
    selected,
    submitted,
    received: safe + n('finalizing'),
    verified,
    duplicates,
    failed,
    unavailable: s.unavailable_count,
    inProgress,
    bytesStored: (counts.verified?.bytes ?? 0) + (counts.duplicate?.bytes ?? 0),
    libraryCoverageVerified: false,
    message,
  };
}
