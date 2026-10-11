import { createHash } from 'node:crypto';
import { mkdtemp } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { API, UPLOAD_CONTENT_TYPE, type Settings, type UploadResult } from '../shared/schemas.ts';
import type { InjectOptions, LightMyRequestResponse } from 'fastify';
import { buildApp, type AppOptions, type BuiltApp } from '../server/app.ts';
import { saveSettings } from '../server/config.ts';
import { openDb, type Db } from '../server/db.ts';

export const PHONE_IP = '192.168.1.50';
export const sha256 = (data: Buffer) => createHash('sha256').update(data).digest('hex');

export interface TestServer extends BuiltApp {
  root: string;
  dest: string;
  db: Db;
  token: string;
  /** Request as the paired phone on the LAN. */
  phone(opts: { method: string; url: string; payload?: unknown; headers?: Record<string, string> }): Promise<LightMyRequestResponse>;
  newSession(selectedCount?: number): Promise<string>;
  /** Full chunked flow: create -> PATCH -> finish (with sender hash unless told otherwise). */
  upload(sessionId: string, filename: string, data: Buffer, opts?: { claimSha?: string | null; lastModified?: number }): Promise<{ status: number; body: UploadResult & { error?: string } }>;
}

export async function startServer(settings: Partial<Settings> = {}, options: Partial<AppOptions> = {}, reuse?: { root: string; db: Db; token: string }): Promise<TestServer> {
  const root = reuse?.root ?? (await mkdtemp(path.join(os.tmpdir(), 'photosync-test-')));
  const dest = path.join(root, 'backup');
  const db = reuse?.db ?? openDb(path.join(root, 'test.db'));
  if (!reuse) {
    saveSettings(db, { destination: dest, organizeByDate: false, maxFileBytes: 2 ** 30, quotaBytes: 0, minFreeBytes: 0, concurrency: 2, stopWithDashboard: true, ...settings });
  }
  const built = await buildApp({ db, port: 0, lanIp: null, webDir: path.join(root, 'no-web'), ...options });
  const { app, pairing } = built;

  let token = reuse?.token ?? '';
  if (!token) {
    const res = await app.inject({ method: 'POST', url: `${API}/pair`, remoteAddress: PHONE_IP, payload: { code: pairing.current().code, deviceName: 'Test iPhone' } });
    token = (res.json() as { token: string }).token;
  }

  const phone: TestServer['phone'] = (opts) =>
    app.inject({ remoteAddress: PHONE_IP, ...opts, headers: { authorization: `Bearer ${token}`, ...opts.headers } } as InjectOptions);

  const newSession: TestServer['newSession'] = async (selectedCount = 1) =>
    ((await phone({ method: 'POST', url: `${API}/sessions`, payload: { method: 'safari', selectedCount } })).json() as { id: string }).id;

  const upload: TestServer['upload'] = async (sessionId, filename, data, opts = {}) => {
    const created = await phone({ method: 'POST', url: `${API}/uploads`, payload: { sessionId, filename, size: data.length, mimeType: '', lastModified: opts.lastModified } });
    if (created.statusCode !== 200) return { status: created.statusCode, body: created.json() };
    const { uploadId } = created.json() as { uploadId: string };
    await phone({ method: 'PATCH', url: `${API}/uploads/${uploadId}`, payload: data, headers: { 'content-type': UPLOAD_CONTENT_TYPE, 'upload-offset': '0' } });
    const claim = opts.claimSha === undefined ? sha256(data) : opts.claimSha;
    const done = await phone({ method: 'POST', url: `${API}/uploads/${uploadId}/finish`, payload: claim ? { sha256: claim } : {} });
    return { status: done.statusCode, body: done.json() };
  };

  return { ...built, root, dest, db, token, phone, newSession, upload };
}

/** Real socket request, for tests that need streaming or a connection cut mid-body. */
export function rawRequest(
  port: number,
  opts: { method: string; path: string; headers: Record<string, string | number> },
  send: (req: http.ClientRequest) => void | Promise<void>,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method: opts.method, path: opts.path, headers: opts.headers }, (res) => {
      let body = '';
      res.on('data', (c: Buffer) => (body += c.toString()));
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on('error', reject);
    void send(req);
  });
}
