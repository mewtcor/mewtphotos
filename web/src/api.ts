import { API } from '../../shared/schemas.ts';

export class ApiError extends Error {
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

/** The request never got an HTTP answer (Wi-Fi drop, server stopped, iOS suspended the page). */
export class NetworkError extends Error {}

const TOKEN_KEY = 'photosync.deviceToken';
export const deviceToken = {
  get: (): string | null => localStorage.getItem(TOKEN_KEY),
  set: (value: string) => localStorage.setItem(TOKEN_KEY, value),
  clear: () => localStorage.removeItem(TOKEN_KEY),
};

export function authHeader(): Record<string, string> {
  const token = deviceToken.get();
  return token ? { authorization: `Bearer ${token}` } : {};
}

export function toApiError(status: number, text: string): ApiError {
  let data: { error?: string; message?: string } = {};
  try {
    data = JSON.parse(text) as typeof data;
  } catch {
    // non-JSON error body
  }
  return new ApiError(status, data.error ?? 'error', data.message ?? `Request failed (${status}).`, data);
}

export async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(API + path, {
      method,
      headers: { ...authHeader(), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new NetworkError('Cannot reach the backup computer.');
  }
  const text = await res.text();
  if (!res.ok) throw toApiError(res.status, text);
  return JSON.parse(text) as T;
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = n / 1024;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[i]}`;
}

export const formatTime = (ms: number): string => new Date(ms).toLocaleString();
