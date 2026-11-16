#!/usr/bin/env python3
"""Render a bright Lorenz-butterfly app icon (PNG + ICNS)."""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
PNG_PATH = ROOT / "Oscope/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
ICNS_PATH = ROOT / "Resources/Oscope.icns"

SIZE = 1024
# Classic Lorenz parameters; front view is x vs z.
SIGMA = 10.0
RHO = 28.0
BETA = 8.0 / 3.0
DT = 0.004
STEPS = 45_000
TRANSIENT = 2_000


def integrate_lorenz() -> np.ndarray:
    x, y, z = 1.0, 1.0, 1.0
    pts = np.empty((STEPS - TRANSIENT, 2), dtype=np.float64)
    out = 0
    for step in range(STEPS):
        dx = SIGMA * (y - x)
        dy = x * (RHO - z) - y
        dz = x * y - BETA * z
        x += dx * DT
        y += dy * DT
        z += dz * DT
        if step >= TRANSIENT:
            pts[out] = (x, z)
            out += 1
    return pts


def render_icon(size: int = SIZE) -> Image.Image:
    pts = integrate_lorenz()
    # THAT front view: wings left/right around a central crossing.
    xs = pts[:, 0]
    zs = pts[:, 1]
    # Center on mean, scale to sit inside the ring with a little margin.
    cx, cz = float(xs.mean()), float(zs.mean())
    xs = xs - cx
    zs = zs - cz
    span = max(float(np.percentile(np.abs(xs), 99.5)), float(np.percentile(np.abs(zs), 99.5)))
    scale = 0.34 * size / span

    # Dark CRT face.
    base = Image.new("RGB", (size, size), (4, 6, 4))
    draw = ImageDraw.Draw(base)

    margin = int(size * 0.08)
    ring_bbox = [margin, margin, size - margin, size - margin]
    # Dim outer halo, then bright ring.
    for radius_pad, color, width in (
        (18, (18, 55, 16), 28),
        (8, (55, 170, 45), 14),
        (0, (140, 255, 120), 7),
    ):
        bbox = [ring_bbox[0] - radius_pad, ring_bbox[1] - radius_pad,
                ring_bbox[2] + radius_pad, ring_bbox[3] + radius_pad]
        draw.ellipse(bbox, outline=color, width=width)

    # Soft crosshair inside the ring.
    mid = size // 2
    inset = margin + 36
    draw.line([(inset, mid), (size - inset, mid)], fill=(28, 70, 24), width=3)
    draw.line([(mid, inset), (mid, size - inset)], fill=(28, 70, 24), width=3)

    # Accumulate the attractor into a float buffer for glow.
    accum = np.zeros((size, size), dtype=np.float32)
    px = (mid + xs * scale).astype(np.int32)
    py = (mid - zs * scale).astype(np.int32)  # z up on screen
    valid = (px >= 2) & (px < size - 2) & (py >= 2) & (py < size - 2)
    px = px[valid]
    py = py[valid]
    # Newer samples slightly brighter so the tip reads as a hot beam.
    weights = np.linspace(0.55, 1.0, num=len(px), dtype=np.float32)
    for x, y, w in zip(px, py, weights):
        accum[y - 1 : y + 2, x - 1 : x + 2] += w
        accum[y, x] += w * 1.6

    # Soft bloom + sharper core — keep the butterfly hot and readable at small sizes.
    glow = Image.fromarray(np.clip(accum * 22.0, 0, 255).astype(np.uint8), mode="L")
    glow = glow.filter(ImageFilter.GaussianBlur(radius=3.6))
    core = Image.fromarray(np.clip(accum * 52.0, 0, 255).astype(np.uint8), mode="L")
    core = core.filter(ImageFilter.GaussianBlur(radius=0.9))

    glow_a = np.asarray(glow, dtype=np.float32) / 255.0
    core_a = np.asarray(core, dtype=np.float32) / 255.0
    mix = np.clip(glow_a * 0.65 + core_a * 1.25, 0.0, 1.0)

    rgb = np.asarray(base, dtype=np.float32)
    # Hot phosphor: green-forward with a bright core so the icon reads from afar.
    add = np.stack(
        [
            mix * 110.0 + core_a * 95.0,
            mix * 235.0 + core_a * 20.0,
            mix * 80.0 + core_a * 55.0,
        ],
        axis=-1,
    )
    out = np.clip(rgb + add, 0, 255).astype(np.uint8)
    image = Image.fromarray(out, mode="RGB")

    # Keep the ring edges crisp after bloom by redrawing a thin bright stroke.
    ring = ImageDraw.Draw(image)
    ring.ellipse(ring_bbox, outline=(175, 255, 155), width=5)
    return image


def image_to_png_bytes(image: Image.Image) -> bytes:
    # Apple ICNS expects raw PNG payloads; Pillow's encoder is fine.
    from io import BytesIO

    buf = BytesIO()
    image.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(path: Path, master: Image.Image) -> None:
    """Pack a minimal modern ICNS with the usual PNG icon slots."""
    # type -> pixel size (1x). Retina slots use 2x.
    slots = [
        (b"ic07", 128),   # 128x128
        (b"ic08", 256),   # 256x256
        (b"ic09", 512),   # 512x512
        (b"ic10", 1024),  # 1024x1024 (10.8+)
        (b"ic11", 32),    # 16x16@2x
        (b"ic12", 64),    # 32x32@2x
        (b"ic13", 256),   # 128x128@2x
        (b"ic14", 512),   # 256x256@2x
    ]
    entries = []
    for tag, px in slots:
        scaled = master.resize((px, px), Image.Resampling.LANCZOS)
        payload = image_to_png_bytes(scaled)
        entries.append(tag + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(entries)
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main() -> None:
    icon = render_icon()
    PNG_PATH.parent.mkdir(parents=True, exist_ok=True)
    icon.save(PNG_PATH, format="PNG", optimize=True)
    ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)
    write_icns(ICNS_PATH, icon)
    print(f"wrote {PNG_PATH.relative_to(ROOT)}")
    print(f"wrote {ICNS_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
