#!/usr/bin/env python3
"""Render a bright Lorenz-butterfly app icon for iOS, macOS, and legacy ICNS."""

from __future__ import annotations

import json
import struct
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "Oscope/Assets.xcassets/AppIcon.appiconset"
MASTER_NAME = "AppIcon.png"
ICNS_PATH = ROOT / "Resources/Oscope.icns"

SIZE = 1024
# Classic Lorenz parameters; front view is x vs z.
SIGMA = 10.0
RHO = 28.0
BETA = 8.0 / 3.0
DT = 0.004
STEPS = 45_000
TRANSIENT = 2_000

# macOS asset-catalog slots: (filename, point size, scale)
MAC_SLOTS = [
    ("icon_16x16.png", 16, 1),
    ("diana.w@example.org", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("ivan.p@example.net", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("frank.g@example.org", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("wendy.h@example.net", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("walt.e@example.net", 512, 2),
]


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
    xs = pts[:, 0]
    zs = pts[:, 1]
    cx, cz = float(xs.mean()), float(zs.mean())
    xs = xs - cx
    zs = zs - cz
    span = max(float(np.percentile(np.abs(xs), 99.5)), float(np.percentile(np.abs(zs), 99.5)))
    scale = 0.36 * size / span

    base = Image.new("RGB", (size, size), (2, 4, 2))
    draw = ImageDraw.Draw(base)

    margin = int(size * 0.07)
    ring_bbox = [margin, margin, size - margin, size - margin]
    for radius_pad, color, width in (
        (20, (22, 70, 20), 30),
        (8, (70, 200, 55), 16),
        (0, (160, 255, 140), 8),
    ):
        bbox = [
            ring_bbox[0] - radius_pad,
            ring_bbox[1] - radius_pad,
            ring_bbox[2] + radius_pad,
            ring_bbox[3] + radius_pad,
        ]
        draw.ellipse(bbox, outline=color, width=width)

    mid = size // 2
    inset = margin + 40
    draw.line([(inset, mid), (size - inset, mid)], fill=(36, 90, 30), width=3)
    draw.line([(mid, inset), (mid, size - inset)], fill=(36, 90, 30), width=3)

    accum = np.zeros((size, size), dtype=np.float32)
    px = (mid + xs * scale).astype(np.int32)
    py = (mid - zs * scale).astype(np.int32)
    valid = (px >= 2) & (px < size - 2) & (py >= 2) & (py < size - 2)
    px = px[valid]
    py = py[valid]
    weights = np.linspace(0.6, 1.0, num=len(px), dtype=np.float32)
    for x, y, w in zip(px, py, weights):
        accum[y - 1 : y + 2, x - 1 : x + 2] += w
        accum[y, x] += w * 1.8

    glow = Image.fromarray(np.clip(accum * 26.0, 0, 255).astype(np.uint8), mode="L")
    glow = glow.filter(ImageFilter.GaussianBlur(radius=4.0))
    core = Image.fromarray(np.clip(accum * 60.0, 0, 255).astype(np.uint8), mode="L")
    core = core.filter(ImageFilter.GaussianBlur(radius=1.0))

    glow_a = np.asarray(glow, dtype=np.float32) / 255.0
    core_a = np.asarray(core, dtype=np.float32) / 255.0
    mix = np.clip(glow_a * 0.7 + core_a * 1.35, 0.0, 1.0)

    rgb = np.asarray(base, dtype=np.float32)
    add = np.stack(
        [
            mix * 125.0 + core_a * 110.0,
            mix * 245.0 + core_a * 10.0,
            mix * 90.0 + core_a * 60.0,
        ],
        axis=-1,
    )
    out = np.clip(rgb + add, 0, 255).astype(np.uint8)
    image = Image.fromarray(out, mode="RGB")

    ring = ImageDraw.Draw(image)
    ring.ellipse(ring_bbox, outline=(185, 255, 165), width=6)
    return image


def image_to_png_bytes(image: Image.Image) -> bytes:
    buf = BytesIO()
    image.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(path: Path, master: Image.Image) -> None:
    # Types match `iconutil -c icns` output, including 512 and 512@2x (ic09 / ic10).
    slots = [
        (b"icp4", 16),
        (b"icp5", 32),
        (b"icp6", 64),
        (b"ic07", 128),
        (b"ic08", 256),
        (b"ic09", 512),
        (b"ic10", 1024),
        (b"ic11", 32),
        (b"ic12", 64),
        (b"ic13", 256),
        (b"ic14", 512),
    ]
    entries = []
    for tag, px in slots:
        scaled = master.resize((px, px), Image.Resampling.LANCZOS)
        payload = image_to_png_bytes(scaled)
        entries.append(tag + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(entries)
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def write_contents_json() -> None:
    images = [
        {
            "filename": MASTER_NAME,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ]
    for filename, point, scale in MAC_SLOTS:
        images.append(
            {
                "filename": filename,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{point}x{point}",
            }
        )
    payload = {"images": images, "info": {"author": "xcode", "version": 1}}
    (ICONSET / "Contents.json").write_text(json.dumps(payload, indent=2) + "\n")


def main() -> None:
    icon = render_icon()
    ICONSET.mkdir(parents=True, exist_ok=True)
    master_path = ICONSET / MASTER_NAME
    icon.save(master_path, format="PNG", optimize=True)

    for filename, point, scale in MAC_SLOTS:
        px = point * scale
        icon.resize((px, px), Image.Resampling.LANCZOS).save(
            ICONSET / filename, format="PNG", optimize=True
        )

    write_contents_json()
    ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)
    write_icns(ICNS_PATH, icon)
    print(f"wrote {master_path.relative_to(ROOT)}")
    print(f"wrote {len(MAC_SLOTS)} macOS icon sizes in {ICONSET.relative_to(ROOT)}")
    print(f"wrote {ICNS_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
