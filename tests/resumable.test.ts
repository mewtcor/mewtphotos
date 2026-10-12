// Phase 3 server change: a failed final move returns the upload to a resumable state (SRV-05).
import { afterEach, describe, expect, it } from 'vitest';
import { API, UPLOAD_CONTENT_TYPE } from '../shared/schemas.ts';
import { get } from '../server/db.ts';
import { seams } from '../server/engine.ts';
import { sha256, startServer, type TestServer } from './helpers.ts';

const open: TestServer[] = [];
afterEach(async () => {
  seams.beforeMove = undefined;
  for (const s of open.splice(0)) await s.app.close();
});

describe('failed final move', () => {
  it('returns the upload to receiving, and a retry completes it without a restart', async () => {
    const s = await startServer();
    open.push(s);
    const session = await s.newSession(1);
    const data = Buffer.from('bytes whose final move fails once');
    const created = await s.phone({
      method: 'POST', url: `${API}/uploads`, payload: { sessionId: session, filename: 'IMG_11.JPG', size: data.length, mimeType: '' },
    });
    const { uploadId } = created.json() as { uploadId: string };
    await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data, headers: { 'content-type': UPLOAD_CONTENT_TYPE, 'upload-offset': '0' } });

    // The move fails once, as a disk error would.
    seams.beforeMove = () => {
      seams.beforeMove = undefined;
      throw Object.assign(new Error('disk hiccup'), { code: 'EIO' });
    };
    const failed = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(failed.statusCode).toBe(500);
    expect(get<{ status: string }>(s.db, 'SELECT status FROM uploads WHERE id = ?', uploadId)?.status).toBe('receiving');

    const retried = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
    expect(retried.json()).toMatchObject({ status: 'verified', endToEndVerified: true });
  });
});
