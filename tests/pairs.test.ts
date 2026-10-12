// Phase 3 server changes: Live Photo parts stored together (SRV-01) and hidden items under Hidden\ (SRV-02).
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { API, UPLOAD_CONTENT_TYPE } from '../shared/schemas.ts';
import { sha256, startServer, type TestServer } from './helpers.ts';

const open: TestServer[] = [];
afterEach(async () => {
  for (const s of open.splice(0)) await s.app.close();
});

async function server(...args: Parameters<typeof startServer>): Promise<TestServer> {
  const s = await startServer(...args);
  open.push(s);
  return s;
}

/** One complete upload with optional pair and hidden fields. */
async function send(s: TestServer, sessionId: string, filename: string, data: Buffer, extra: Record<string, unknown> = {}) {
  const created = await s.phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId, filename, size: data.length, mimeType: '', ...extra } });
  const { uploadId } = created.json() as { uploadId: string };
  await s.phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data, headers: { 'content-type': UPLOAD_CONTENT_TYPE, 'upload-offset': '0' } });
  const done = await s.phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: { sha256: sha256(data) } });
  return { status: done.statusCode, body: done.json() as { status: string; path: string } };
}

describe('Live Photo pairs', () => {
  it('both parts land in one folder with the same stem, even across a month boundary', async () => {
    const s = await server({ organizeByDate: true });
    const session = await s.newSession(2);
    const photo = await send(s, session, 'IMG_1.HEIC', Buffer.from('photo'), {
      lastModified: new Date(2026, 0, 31, 23).getTime(), pairId: 'p1', pairName: 'IMG_1.MOV',
    });
    const video = await send(s, session, 'IMG_1.MOV', Buffer.from('video'), {
      lastModified: new Date(2026, 1, 1, 1).getTime(), pairId: 'p1', pairName: 'IMG_1.HEIC',
    });
    expect(photo.body.status).toBe('verified');
    expect(video.body.status).toBe('verified');
    expect(path.dirname(video.body.path)).toBe(path.dirname(photo.body.path));
    expect(path.basename(photo.body.path)).toBe('IMG_1.HEIC');
    expect(path.basename(video.body.path)).toBe('IMG_1.MOV');
  });

  it('a name clash moves both parts to the same new stem', async () => {
    const s = await server({ organizeByDate: true });
    const session = await s.newSession(3);
    const when = new Date(2026, 4, 5).getTime();
    await send(s, session, 'IMG_2.HEIC', Buffer.from('an unrelated photo'), { lastModified: when });
    const photo = await send(s, session, 'IMG_2.HEIC', Buffer.from('photo'), { lastModified: when, pairId: 'p2', pairName: 'IMG_2.MOV' });
    const video = await send(s, session, 'IMG_2.MOV', Buffer.from('video'), { lastModified: when, pairId: 'p2', pairName: 'IMG_2.HEIC' });
    expect(path.basename(photo.body.path)).toBe('IMG_2 (2).HEIC');
    expect(path.basename(video.body.path)).toBe('IMG_2 (2).MOV');
  });
});

describe('hidden items', () => {
  it('a hidden item is stored under Hidden, and an ordinary item is not', async () => {
    const s = await server({ organizeByDate: true });
    const session = await s.newSession(2);
    const when = new Date(2026, 6, 10).getTime();
    const hidden = await send(s, session, 'IMG_3.JPG', Buffer.from('private'), { lastModified: when, hidden: true });
    const ordinary = await send(s, session, 'IMG_4.JPG', Buffer.from('plain'), { lastModified: when });
    expect(path.dirname(hidden.body.path)).toBe(path.join(s.dest, 'Hidden', '2026', '07'));
    expect(path.dirname(ordinary.body.path)).toBe(path.join(s.dest, '2026', '07'));
  });
});
