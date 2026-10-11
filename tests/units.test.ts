import { randomBytes } from 'node:crypto';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { HttpError, isLocalNetworkAddress, Pairing, resolveInside, safeMediaFilename, sanitizeFilename } from '../server/security.ts';
import { Sha256 } from '../shared/sha256.ts';
import { sha256 } from './helpers.ts';

describe('browser-side SHA-256', () => {
  it('matches node:crypto for many sizes and chunkings', () => {
    for (const size of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 65_537, 300_001]) {
      const data = randomBytes(size);
      for (const step of [1, 7, 64, 1000, size + 1]) {
        if (size > 5000 && step < 64) continue;
        const h = new Sha256();
        for (let i = 0; i < size; i += step) h.update(data.subarray(i, i + step));
        expect(h.digestHex(), `size ${size} step ${step}`).toBe(sha256(data));
      }
    }
  });

  it('matches the published test vector', () => {
    expect(new Sha256().update(Buffer.from('abc')).digestHex()).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});

describe('filenames and paths', () => {
  it('strips directories and traversal', () => {
    expect(sanitizeFilename('../../Windows/System32/evil.jpg')).toBe('evil.jpg');
    expect(sanitizeFilename('..\\..\\evil.jpg')).toBe('evil.jpg');
    expect(sanitizeFilename('C:\\Users\\x\\IMG_0001.HEIC')).toBe('IMG_0001.HEIC');
    expect(sanitizeFilename('...')).toBe('unnamed');
  });

  it('neutralises reserved characters and device names', () => {
    expect(sanitizeFilename('a<b>c:d|e?.jpg')).toBe('a_b_c_d_e_.jpg');
    expect(sanitizeFilename('CON.jpg')).toBe('_CON.jpg');
    expect(sanitizeFilename('photo.jpg. . ')).toBe('photo.jpg');
    expect(sanitizeFilename(`${'x'.repeat(400)}.heic`).length).toBeLessThanOrEqual(150);
  });

  it('accepts media, rejects other types, and derives a missing extension from the MIME type', () => {
    expect(safeMediaFilename('IMG_1.HEIC', '')).toBe('IMG_1.HEIC');
    expect(safeMediaFilename('clip', 'video/quicktime')).toBe('clip.mov');
    expect(() => safeMediaFilename('setup.exe', '')).toThrow(HttpError);
    expect(() => safeMediaFilename('photo.jpg.exe', 'image/jpeg')).toThrow(HttpError);
    expect(() => safeMediaFilename('noext', 'application/zip')).toThrow(HttpError);
  });

  it('refuses to resolve outside the backup folder', () => {
    const root = path.resolve('some', 'backup');
    expect(resolveInside(root, '2024', '05', 'a.jpg')).toBe(path.join(root, '2024', '05', 'a.jpg'));
    expect(() => resolveInside(root, '..', 'a.jpg')).toThrow(HttpError);
    expect(() => resolveInside(root, '..', 'backup-other', 'a.jpg')).toThrow(HttpError);
  });
});

describe('network and pairing', () => {
  it('recognises only local-network addresses', () => {
    for (const ip of ['127.0.0.1', '192.168.4.20', '10.1.2.3', '172.16.5.5', '::ffff:192.168.1.9', '::1', 'fe80::1']) {
      expect(isLocalNetworkAddress(ip), ip).toBe(true);
    }
    for (const ip of ['8.8.8.8', '172.32.0.1', '192.169.0.1', '2001:4860:4860::8888', '::ffff:1.2.3.4']) {
      expect(isLocalNetworkAddress(ip), ip).toBe(false);
    }
  });

  it('accepts the code once, then rotates it', () => {
    const pairing = new Pairing();
    const { code } = pairing.current();
    expect(() => pairing.consume('WRONGCOD', '10.0.0.2')).toThrow(/wrong or has expired/);
    pairing.consume(code.toLowerCase(), '10.0.0.2'); // case-insensitive
    expect(pairing.current().code).not.toBe(code);
    expect(() => pairing.consume(code, '10.0.0.2')).toThrow(HttpError);
  });

  it('throttles repeated wrong codes per address', () => {
    const pairing = new Pairing();
    let last: unknown;
    for (let i = 0; i < 9; i++) {
      try {
        pairing.consume('AAAAAAAA', '10.0.0.3');
      } catch (err) {
        last = err;
      }
    }
    expect((last as HttpError).status).toBe(429);
    // even the right code is refused while throttled; another address is unaffected
    expect(() => pairing.consume(pairing.current().code, '10.0.0.3')).toThrow(/Too many/);
    pairing.consume(pairing.current().code, '10.0.0.4');
  });
});
