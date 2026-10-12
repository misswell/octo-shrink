#!/usr/bin/env python3
"""为 scripts/memory_stress.sh 生成多格式压测样本。

PNG 由本脚本直接写（噪声，确定性；zlib STORE 过滤），JPEG/GIF 走系统 sips，
WebP/AVIF 走 src-tauri/resources/bin 里的捆绑 CLI —— 与产物线实际使用的编码器一致。
噪声和照片一样是不可压缩内容，解码/编码的成本主要随像素数走，适合看内存曲线。
"""

from __future__ import annotations

import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "src-tauri" / "resources" / "bin"
LIBDIR = REPO / "src-tauri" / "resources" / "lib"

# (前缀, 张数, 宽, 高)
SIZES = [
    ("small", 8, 1200, 900),
    ("medium", 5, 2400, 1800),
    ("large", 2, 4000, 3000),
]


def tool_env() -> dict[str, str]:
    env = dict(os.environ)
    if LIBDIR.is_dir():
        existing = env.get("DYLD_FALLBACK_LIBRARY_PATH", "")
        env["DYLD_FALLBACK_LIBRARY_PATH"] = (
            f"{LIBDIR}:{existing}" if existing else str(LIBDIR)
        )
    return env


def run(cmd: list[str], **kwargs: object) -> None:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)  # type: ignore[arg-type]
    if result.returncode != 0:
        sys.stderr.write(f"命令失败: {' '.join(cmd)}\n{result.stderr}\n")
        raise SystemExit(1)


def write_png(path: Path, width: int, height: int, seed: int) -> None:
    import random

    rng = random.Random(seed)
    row_bytes = width * 3
    raw = b"".join(b"\x00" + rng.randbytes(row_bytes) for _ in range(height))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 1))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def write_ppm(path: Path, width: int, height: int, seed: int) -> None:
    import random

    rng = random.Random(seed)
    with open(path, "wb") as handle:
        handle.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        handle.write(rng.randbytes(width * height * 3))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gen_stress_samples.py <output-dir>", file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    env = tool_env()

    for tool in ("cwebp", "avifenc"):
        if not (TOOLS / tool).is_file():
            print(f"缺少捆绑工具 {TOOLS / tool}", file=sys.stderr)
            return 1

    written: list[Path] = []

    def note(path: Path) -> None:
        written.append(path)
        print(f"  {path.name:28s} {path.stat().st_size / 1_048_576:8.2f} MiB")

    seed = 20261012
    for prefix, count, width, height in SIZES:
        for index in range(1, count + 1):
            seed += 1
            png = out / f"{prefix}-png-{index:02d}.png"
            write_png(png, width, height, seed)
            note(png)

            jpg = out / f"{prefix}-jpg-{index:02d}.jpg"
            run(
                [
                    "sips", "-s", "format", "jpeg", "-s", "formatOptions", "90",
                    str(png), "--out", str(jpg),
                ]
            )
            note(jpg)

            webp = out / f"{prefix}-webp-{index:02d}.webp"
            run(
                [str(TOOLS / "cwebp"), "-q", "80", "-quiet", str(png), "-o", str(webp)],
                env=env,
            )
            note(webp)

    gif = out / "small-gif-01.gif"
    run(["sips", "-s", "format", "gif", str(out / "small-png-01.png"), "--out", str(gif)])
    note(gif)

    for source in ("small-png-01", "medium-png-01"):
        avif = out / f"{source.replace('-png', '-avif')}.avif"
        run(
            [
                str(TOOLS / "avifenc"), "-s", "8", "-q", "60",
                str(out / f"{source}.png"), str(avif),
            ],
            env=env,
        )
        note(avif)

    ppm = out / "large-cjpeg-input.ppm"
    write_ppm(ppm, 4000, 3000, seed + 1)
    note(ppm)

    total = sum(path.stat().st_size for path in written)
    print(f"合计 {len(written)} 个文件，{total / 1_048_576:.0f} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
