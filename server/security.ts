import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { BlockList, isIPv4 } from 'node:net';
import os from 'node:os';
import path from 'node:path';

export class HttpError extends Error {
  status: number;
  code: string;
  extra: Record<string, unknown>;
  constructor(status: number, code: string, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

// ---- network -------------------------------------------------------------

const localNetworks = new BlockList();
localNetworks.addSubnet('10.0.0.0', 8);
localNetworks.addSubnet('172.16.0.0', 12);
localNetworks.addSubnet('192.168.0.0', 16);
localNetworks.addSubnet('169.254.0.0', 16);
localNetworks.addSubnet('127.0.0.0', 8);
localNetworks.addSubnet('fc00::', 7, 'ipv6');
localNetworks.addSubnet('fe80::', 10, 'ipv6');
localNetworks.addAddress('::1', 'ipv6');

function plainAddress(ip: string): string {
  return ip.startsWith('::ffff:') ? ip.slice(7) : ip;
}

/** True for loopback, RFC 1918, link-local and IPv6 unique-local addresses only. */
export function isLocalNetworkAddress(ip: string): boolean {
  const addr = plainAddress(ip);
  return localNetworks.check(addr, isIPv4(addr) ? 'ipv4' : 'ipv6');
}

export function isLoopback(ip: string): boolean {
  const addr = plainAddress(ip);
  return addr === '::1' || addr.startsWith('127.');
}

/** Picks the Wi-Fi/Ethernet address the iPhone should connect to, ignoring virtual adapters. */
export function pickLanAddress(): string | null {
  const candidates: { name: string; address: string }[] = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family === 'IPv4' && !a.internal && isLocalNetworkAddress(a.address) && !a.address.startsWith('169.254.')) {
        candidates.push({ name, address: a.address });
      }
    }
  }
  const virtual = /vethernet|wsl|virtualbox|vmware|hyper-v|docker|br-|virbr|veth|bluetooth|tailscale|zerotier|vpn/i;
  const real = candidates.filter((c) => !virtual.test(c.name));
  const pool = real.length > 0 ? real : candidates;
  const preferred = process.platform === 'linux'
    ? pool.find((c) => /^(en|eth)/i.test(c.name)) ?? pool.find((c) => /wi-?fi|wlan|wireless|^wl/i.test(c.name))
    : pool.find((c) => /wi-?fi|wlan|wireless/i.test(c.name));
  return (preferred ?? pool[0])?.address ?? null;
}

// ---- credentials ---------------------------------------------------------

export function newToken(): string {
  return randomBytes(32).toString('base64url');
}

/** Only this hash is stored; the token itself exists on the phone alone. */
export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no look-alikes (0/O, 1/I/L)
const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_FAILURES = 8;
const FAILURE_WINDOW_MS = 5 * 60 * 1000;

/** One-time pairing code shown on the dashboard, plus per-address brute-force throttling. */
export class Pairing {
  private code = '';
  private expiresAt = 0;
  private failures = new Map<string, { count: number; resetAt: number }>();

  current(): { code: string; expiresAt: number } {
    if (Date.now() >= this.expiresAt) this.rotate();
    return { code: this.code, expiresAt: this.expiresAt };
  }

  /** Throws 429 when throttled, 403 on a wrong code; rotates the code on success. */
  consume(input: string, ip: string): void {
    const now = Date.now();
    const entry = this.failures.get(ip);
    if (entry && now < entry.resetAt && entry.count >= MAX_FAILURES) {
      throw new HttpError(429, 'too_many_attempts', 'Too many wrong pairing codes. Wait a few minutes and try again.');
    }
    const expected = Buffer.from(this.current().code);
    const given = Buffer.from(input.toUpperCase().replace(/[^A-Z0-9]/g, ''));
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
      if (!entry || now >= entry.resetAt) this.failures.set(ip, { count: 1, resetAt: now + FAILURE_WINDOW_MS });
      else entry.count++;
      throw new HttpError(403, 'bad_pairing_code', 'That pairing code is wrong or has expired. Check the dashboard for the current code.');
    }
    this.failures.delete(ip);
    this.rotate();
  }

  private rotate(): void {
    this.code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
    this.expiresAt = Date.now() + CODE_TTL_MS;
  }
}

// ---- filenames -----------------------------------------------------------

const ALLOWED_EXTENSIONS = new Set([
  // images
  'jpg', 'jpeg', 'jpe', 'heic', 'heif', 'hif', 'avif', 'png', 'gif', 'webp', 'bmp', 'tif', 'tiff',
  // raw
  'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2',
  // video
  'mov', 'mp4', 'm4v', '3gp', '3g2', 'avi', 'mkv', 'webm', 'mts', 'm2ts',
]);

const MIME_EXTENSIONS: Record<string, string> = {
  'image/jpeg': 'jpg', 'image/heic': 'heic', 'image/heif': 'heif', 'image/png': 'png', 'image/gif': 'gif',
  'image/webp': 'webp', 'image/tiff': 'tif', 'image/avif': 'avif', 'image/x-adobe-dng': 'dng',
  'video/quicktime': 'mov', 'video/mp4': 'mp4', 'video/x-m4v': 'm4v',
};

/**
 * Reduces a client-supplied name to a single safe Windows filename: no directories, no
 * reserved characters or device names. The original bytes are never touched, only the name.
 */
export function sanitizeFilename(raw: string): string {
  let name = raw.replace(/\\/g, '/').split('/').pop() ?? '';
  name = name.normalize('NFC').replace(/[\x00-\x1f\x7f<>:"|?*]/g, '_').replace(/^[. ]+|[. ]+$/g, '');
  if (/^(con|prn|aux|nul|com\d|lpt\d)(\.|$)/i.test(name)) name = `_${name}`;
  if (name.length > 150) {
    const ext = path.extname(name).slice(0, 12);
    name = name.slice(0, 150 - ext.length) + ext;
  }
  return name || 'unnamed';
}

/** Returns a safe filename with an allowed photo/video extension, or throws 415. */
export function safeMediaFilename(raw: string, mimeType: string): string {
  let name = sanitizeFilename(raw);
  let ext = path.extname(name).slice(1).toLowerCase();
  if (!ext) {
    const fromMime = MIME_EXTENSIONS[mimeType.split(';')[0]!.trim().toLowerCase()];
    if (fromMime) {
      name = `${name}.${fromMime}`;
      ext = fromMime;
    }
  }
  if (!ALLOWED_EXTENSIONS.has(ext)) {
    throw new HttpError(415, 'unsupported_type', `"${name}" is not a supported photo or video type.`);
  }
  return name;
}

/** Joins and then proves the result is still inside `root`. */
export function resolveInside(root: string, ...parts: string[]): string {
  const base = path.resolve(root);
  const full = path.resolve(base, ...parts);
  if (full !== base && !full.startsWith(base + path.sep)) {
    throw new HttpError(400, 'bad_path', 'Refusing to write outside the backup folder.');
  }
  return full;
}
