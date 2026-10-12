// Phase 3 server changes: "already backed up?" only counts a file still on disk (SRV-03), and a resend in one
// session creates no second record (SRV-04).
import { rm, writeFile } from 'node:fs/promises';
import { afterEach, describe, expect, it } from 'vitest';
import { API } from '../shared/schemas.ts';
import { all } from '../server/db.ts';
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

async function knownBySha(s: TestServer, hash: string): Promise<boolean> {
  const res = await s.phone({ method: 'POST', url: `${API}/assets/check`, payload: { items: [{ sha256: hash }] } });
  return (res.json() as { known: boolean[] }).known[0];
}

describe('already backed up', () => {
  it('answers not backed up once the stored file is deleted or shortened', async () => {
    const s = await server();
    const data = Buffer.from('a photo that will be backed up');
    const hash = sha256(data);
    const done = await s.upload(await s.newSession(1), 'IMG_9.JPG', data);
    expect(done.body.status).toBe('verified');
    expect(await knownBySha(s, hash)).toBe(true);
    expect((await s.phone({ method: 'GET', url: `${API}/files/${hash}` })).json()).toMatchObject({ known: true });

    await writeFile(done.body.path, 'short');
    expect(await knownBySha(s, hash)).toBe(false);
    expect((await s.phone({ method: 'GET', url: `${API}/files/${hash}` })).json()).toMatchObject({ known: false });

    await rm(done.body.path);
    expect(await knownBySha(s, hash)).toBe(false);
  });
});

describe('resend in one session', () => {
  it('returns the existing record and creates no second upload row', async () => {
    const s = await server();
    const session = await s.newSession(2);
    const data = Buffer.from('the same photo sent twice');
    const first = await s.upload(session, 'IMG_10.JPG', data);
    expect(first.body.status).toBe('verified');

    const again = await s.phone({
      method: 'POST',
      url: `${API}/uploads`,
      payload: { sessionId: session, filename: 'IMG_10.JPG', size: data.length, mimeType: '', sha256: sha256(data) },
    });
    expect(again.json()).toMatchObject({ status: 'duplicate' });
    expect(all(s.db, 'SELECT id FROM uploads WHERE session_id = ?', session)).toHaveLength(1);
  });
});

describe('PC count for this iPhone', () => {
  it('counts assets only while their stored copy is on disk, once per asset', async () => {
    const s = await server();
    const session = await s.newSession(3);
    const a = Buffer.from('first photo for the count');
    const b = Buffer.from('second photo for the count');
    const doneA = await s.upload(session, 'IMG_20.JPG', a);
    const doneB = await s.upload(session, 'IMG_21.JPG', b);
    // The upload helper sends no asset identifier, so the test records one on each row directly.
    s.db.exec(`UPDATE uploads SET asset_id = 'asset-a' WHERE id = '${doneA.body.uploadId}'`);
    s.db.exec(`UPDATE uploads SET asset_id = 'asset-a' WHERE id = '${doneB.body.uploadId}'`);
    const count = async () => (await s.phone({ method: 'GET', url: `${API}/assets/count` })).json();

    expect(await count()).toEqual({ stored: 1 });
    await rm(doneA.body.path);
    expect(await count()).toEqual({ stored: 1 });
    await rm(doneB.body.path);
    expect(await count()).toEqual({ stored: 0 });
  });
});
