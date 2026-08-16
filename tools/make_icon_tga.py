#!/usr/bin/env python3
"""Convert mm-worldTourIcon.png into Media/icon.tga (and a 64px minimap copy).

WoW loads TGA and BLP, never PNG, so the source art has to be converted before
it can be used at all.

Two sizes on purpose. The minimap button draws at ~20px and the main window at
~32-64px; handing a 1024x1024 texture to either wastes several megabytes of
video memory to draw a thumbnail, and WoW does not mipmap addon textures for
you. Downscaling in Pillow (LANCZOS) also produces a far cleaner small icon than
the client's own point sampling would.

Matches the container the other Media/*.tga files already use: uncompressed
32-bit BGRA, bottom-left origin (descriptor 0x08), power-of-two dimensions.
"""
import struct, pathlib
from PIL import Image

SRC = pathlib.Path(__file__).resolve().parent.parent / "mm-worldTourIcon.png"
MEDIA = SRC.parent / "Media"

def write_tga(img, path):
    img = img.convert("RGBA")
    w, h = img.size
    # TGA rows run bottom-up for descriptor 0x08
    px = img.transpose(Image.FLIP_TOP_BOTTOM).tobytes()
    # RGBA -> BGRA
    out = bytearray(len(px))
    out[0::4], out[1::4], out[2::4], out[3::4] = px[2::4], px[1::4], px[0::4], px[3::4]
    header = struct.pack("<3B2HB4H2B", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    path.write_bytes(header + bytes(out))
    return w, h, len(header) + len(out)

src = Image.open(SRC)
print(f"source: {src.size[0]}x{src.size[1]} {src.mode}")
for size, name in ((128, "icon.tga"), (64, "icon-minimap.tga")):
    img = src.resize((size, size), Image.LANCZOS)
    w, h, n = write_tga(img, MEDIA / name)
    print(f"  {name:<18} {w}x{h}  {n//1024} KB")
