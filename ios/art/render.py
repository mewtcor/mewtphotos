"""Renders art/icon.svg to the 1024px app icon with headless Chrome, then drops the alpha channel
(App Store icons must be opaque). Usage: python art/render.py  (needs Chrome or Edge on Windows)."""
import struct, subprocess, sys, tempfile, zlib
from pathlib import Path

here = Path(__file__).resolve().parent
out = here.parent / "MewtPhotos" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
browsers = [r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"]
exe = next(b for b in browsers if Path(b).exists())
shot = Path(tempfile.mkdtemp()) / "shot.png"
subprocess.run([exe, "--headless", "--disable-gpu", "--hide-scrollbars", "--default-background-color=FF000000",
                "--window-size=1024,1024", f"--screenshot={shot}", (here / "icon.svg").as_uri()], check=True)

data = shot.read_bytes()
pos, idat, ihdr = 8, b"", None
while pos < len(data):
    n, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    if kind == b"IHDR": ihdr = struct.unpack(">IIBBBBB", body)
    if kind == b"IDAT": idat += body
    pos += 12 + n
w, h, depth, ctype, _, _, interlace = ihdr
assert depth == 8 and ctype in (2, 6) and interlace == 0, ihdr
bpp = 4 if ctype == 6 else 3
raw, stride = zlib.decompress(idat), w * bpp
rows, prev = [], bytearray(stride)
for y in range(h):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - bpp] if i >= bpp else 0
        b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(bytes(line)); prev = line
rgb = b"".join(b"\x00" + b"".join(r[i:i + 3] for i in range(0, stride, bpp)) for r in rows)
def chunk(k, d): return struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d))
out.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rgb, 9)) + chunk(b"IEND", b""))
print("wrote", out, w, "x", h, "RGB")
