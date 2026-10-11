// Reads the capture date embedded in a photo or video. Read-only: used solely to choose
// the YYYY\MM folder, never to change the file.
import { open } from 'node:fs/promises';
import ExifReader from 'exifreader';

export interface CaptureDate {
  /** Local wall-clock time, e.g. 2024-05-01T12:34:56 */
  capturedAt: string;
  year: string;
  month: string;
  source: 'exif' | 'quicktime';
}

const VIDEO = new Set(['mov', 'mp4', 'm4v', '3gp', '3g2']);
const HEADER_BYTES = 1024 * 1024; // EXIF sits near the start of JPEG/HEIC/TIFF/DNG files

function plausible(year: number): boolean {
  return year >= 1990 && year <= new Date().getFullYear() + 1;
}

async function exifDate(file: string): Promise<CaptureDate | null> {
  const fh = await open(file, 'r');
  try {
    const { size } = await fh.stat();
    const buf = Buffer.alloc(Math.min(size, HEADER_BYTES));
    await fh.read(buf, 0, buf.length, 0);
    const tags = ExifReader.load(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length), { expanded: true });
    const raw = tags.exif?.DateTimeOriginal?.description ?? tags.exif?.DateTimeDigitized?.description;
    const m = /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/.exec(raw ?? '');
    if (!m || !plausible(Number(m[1])) || Number(m[2]) < 1 || Number(m[2]) > 12) return null;
    return { capturedAt: `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}`, year: m[1]!, month: m[2]!, source: 'exif' };
  } finally {
    await fh.close();
  }
}

/** Finds moov/mvhd in an ISO-BMFF (MOV/MP4) file and returns its creation time. */
async function quicktimeDate(file: string): Promise<CaptureDate | null> {
  const fh = await open(file, 'r');
  try {
    const fileSize = (await fh.stat()).size;
    const head = Buffer.alloc(16);
    const findAtom = async (type: string, start: number, end: number): Promise<{ start: number; end: number } | null> => {
      let pos = start;
      while (pos + 8 <= end) {
        await fh.read(head, 0, 16, pos);
        let size = head.readUInt32BE(0);
        let headerLen = 8;
        if (size === 1) {
          size = Number(head.readBigUInt64BE(8));
          headerLen = 16;
        } else if (size === 0) {
          size = end - pos;
        }
        if (size < headerLen) return null;
        if (head.toString('latin1', 4, 8) === type) return { start: pos + headerLen, end: Math.min(pos + size, end) };
        pos += size;
      }
      return null;
    };
    const moov = await findAtom('moov', 0, fileSize);
    const mvhd = moov && (await findAtom('mvhd', moov.start, moov.end));
    if (!mvhd) return null;
    const body = Buffer.alloc(12);
    await fh.read(body, 0, 12, mvhd.start);
    const seconds = body[0] === 1 ? Number(body.readBigUInt64BE(4)) : body.readUInt32BE(4);
    if (seconds === 0) return null;
    const date = new Date((seconds - 2082844800) * 1000); // QuickTime epoch is 1904-01-01 UTC
    if (!plausible(date.getFullYear())) return null;
    const p = (n: number) => String(n).padStart(2, '0');
    const year = String(date.getFullYear());
    const month = p(date.getMonth() + 1);
    return {
      capturedAt: `${year}-${month}-${p(date.getDate())}T${p(date.getHours())}:${p(date.getMinutes())}:${p(date.getSeconds())}`,
      year,
      month,
      source: 'quicktime',
    };
  } finally {
    await fh.close();
  }
}

/** Returns null when the file carries no trustworthy capture date (callers fall back). */
export async function readCaptureDate(file: string, extension: string): Promise<CaptureDate | null> {
  try {
    return VIDEO.has(extension.toLowerCase()) ? await quicktimeDate(file) : await exifDate(file);
  } catch {
    return null; // unparseable metadata is not an upload failure
  }
}
