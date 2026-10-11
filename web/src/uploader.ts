// Sends one file with the resumable chunk protocol:
//   POST /uploads -> PATCH /uploads/:id (repeated, Upload-Offset) -> POST /uploads/:id/finish
import { API, UPLOAD_CONTENT_TYPE, type UploadResult, type UploadState } from '../../shared/schemas.ts';
import { Sha256 } from '../../shared/sha256.ts';
import { api, ApiError, authHeader, NetworkError, toApiError } from './api.ts';

const MAX_ATTEMPTS = 6;
const CHUNK_TIMEOUT_MS = 120_000;

/** iOS could not hand the file's bytes to the browser (typically an iCloud-only original). */
export class UnavailableError extends Error {}

export interface UploadOptions {
  sessionId: string;
  chunkSize: number;
  /** Hash on the phone first: skips files the PC already has, and proves new ones arrived unchanged. */
  hash: boolean;
  signal: AbortSignal;
  /** In the 'checking' phase the byte count is bytes hashed locally, not bytes sent. */
  onProgress(bytes: number, phase: 'checking' | 'uploading' | 'verifying'): void;
  onUploadId(id: string): void;
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(new DOMException('Cancelled', 'AbortError'));
    }, { once: true });
  });
}

// XMLHttpRequest rather than fetch: it is the only way to get upload progress in Safari.
function sendChunk(uploadId: string, offset: number, blob: Blob, signal: AbortSignal, onProgress: (loaded: number) => void): Promise<number> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PATCH', `${API}/uploads/${uploadId}`);
    for (const [k, v] of Object.entries(authHeader())) xhr.setRequestHeader(k, v);
    xhr.setRequestHeader('content-type', UPLOAD_CONTENT_TYPE);
    xhr.setRequestHeader('upload-offset', String(offset));
    xhr.timeout = CHUNK_TIMEOUT_MS;
    xhr.upload.onprogress = (e) => onProgress(e.loaded);
    xhr.onload = () => {
      if (xhr.status === 200) resolve((JSON.parse(xhr.responseText) as { offset: number }).offset);
      else reject(toApiError(xhr.status, xhr.responseText));
    };
    xhr.onerror = () => reject(new NetworkError('Connection lost during upload.'));
    xhr.ontimeout = () => reject(new NetworkError('Upload timed out.'));
    xhr.onabort = () => reject(new DOMException('Cancelled', 'AbortError'));
    signal.addEventListener('abort', () => xhr.abort(), { once: true });
    xhr.send(blob);
  });
}

const retryable = (err: unknown) => err instanceof NetworkError || (err instanceof ApiError && (err.status >= 500 || err.status === 408 || err.code === 'upload_busy'));

/** Resolves only when the server reports the file stored and verified (or a duplicate). */
export async function uploadFile(file: File, opts: UploadOptions): Promise<UploadResult> {
  if (file.size === 0) throw new UnavailableError('iOS provided an empty file.');

  // Hash first, entirely on the phone. Knowing the hash up front lets the PC answer
  // "already backed up" before a single byte of the file is sent over Wi-Fi.
  let sha256: string | undefined;
  if (opts.hash) {
    const hasher = new Sha256();
    for (let pos = 0; pos < file.size; pos += opts.chunkSize) {
      if (opts.signal.aborted) throw new DOMException('Cancelled', 'AbortError');
      try {
        hasher.update(new Uint8Array(await file.slice(pos, pos + opts.chunkSize).arrayBuffer()));
      } catch {
        throw new UnavailableError('iOS could not read this item (it may exist only in iCloud). Open it in Photos to download it, then try again.');
      }
      opts.onProgress(Math.min(pos + opts.chunkSize, file.size), 'checking');
    }
    sha256 = hasher.digestHex();
  }

  const created = await api<UploadState | UploadResult>('POST', '/uploads', {
    sessionId: opts.sessionId,
    filename: file.name || 'unnamed',
    size: file.size,
    mimeType: file.type,
    lastModified: file.lastModified || undefined,
    sha256,
  });
  opts.onUploadId(created.uploadId);
  if (created.status !== 'receiving') return created as UploadResult; // already backed up: nothing sent

  const id = created.uploadId;
  let offset = (created as UploadState).offset; // > 0 when resuming an earlier interrupted transfer
  let attempts = 0;
  opts.onProgress(offset, 'uploading');

  for (let pos = 0; pos < file.size; ) {
    const end = Math.min(pos + opts.chunkSize, file.size);
    while (offset < end) {
      if (opts.signal.aborted) throw new DOMException('Cancelled', 'AbortError');
      try {
        const from = offset;
        offset = await sendChunk(id, from, file.slice(from, end), opts.signal, (loaded) => opts.onProgress(from + loaded, 'uploading'));
        attempts = 0;
      } catch (err) {
        if (err instanceof ApiError && err.code === 'offset_mismatch' && typeof err.extra.offset === 'number') {
          offset = err.extra.offset;
        } else if (retryable(err) && ++attempts < MAX_ATTEMPTS) {
          await sleep(Math.min(1000 * 2 ** (attempts - 1), 15_000), opts.signal);
          // Ask the server how much it really has before sending again.
          offset = await api<UploadState>('GET', `/uploads/${id}`).then((s) => s.offset, () => offset);
        } else {
          throw err;
        }
      }
      opts.onProgress(Math.min(offset, file.size), 'uploading');
    }
    pos = end;
  }

  opts.onProgress(file.size, 'verifying');
  const body = sha256 ? { sha256 } : {};
  for (let attempt = 1; ; attempt++) {
    try {
      return await api<UploadResult>('POST', `/uploads/${id}/finish`, body); // safe to repeat
    } catch (err) {
      // A very large video can take longer to re-read and hash than Safari waits for a reply.
      // The server keeps working; "busy" means exactly that, so keep asking without giving up.
      if (err instanceof ApiError && err.code === 'upload_busy') {
        attempt--;
        await sleep(3000, opts.signal);
        continue;
      }
      if (!retryable(err) || attempt >= MAX_ATTEMPTS) throw err;
      await sleep(Math.min(1000 * 2 ** (attempt - 1), 15_000), opts.signal);
    }
  }
}
