#!/usr/bin/env python3
"""Rebuild a Tauri AppImage payload with executable AppRun permissions intact."""

from __future__ import annotations

import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


SQUASHFS_COMPRESSORS = {
    1: "gzip",
    2: "lzma",
    3: "lzo",
    4: "xz",
    5: "lz4",
    6: "zstd",
}


def image_layout(image: Path) -> tuple[int, str, int]:
    with image.open("rb") as handle:
        header = handle.read(64)
        if len(header) != 64 or header[:4] != b"\x7fELF":
            raise ValueError("AppImage does not begin with an ELF runtime")
        if header[4] != 2 or header[5] != 1:
            raise ValueError("Expected a little-endian 64-bit AppImage runtime")

        section_offset = struct.unpack_from("<Q", header, 40)[0]
        section_size = struct.unpack_from("<H", header, 58)[0]
        section_count = struct.unpack_from("<H", header, 60)[0]
        if not section_offset or not section_size or not section_count:
            raise ValueError("AppImage runtime has an unsupported ELF section table")

        squashfs_offset = section_offset + section_size * section_count
        handle.seek(squashfs_offset)
        superblock = handle.read(48)

    if superblock[:4] != b"hsqs":
        raise ValueError("SquashFS does not start at the expected AppImage offset")

    block_size = struct.unpack_from("<I", superblock, 12)[0]
    compression_id = struct.unpack_from("<H", superblock, 20)[0]
    try:
        compressor = SQUASHFS_COMPRESSORS[compression_id]
    except KeyError as error:
        raise ValueError(f"Unsupported SquashFS compression id: {compression_id}") from error
    if block_size <= 0:
        raise ValueError("AppImage has an invalid SquashFS block size")

    return squashfs_offset, compressor, block_size


def copy_prefix(source: Path, destination: Path, length: int) -> None:
    remaining = length
    with source.open("rb") as source_handle, destination.open("wb") as destination_handle:
        while remaining:
            chunk = source_handle.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("AppImage ended before the SquashFS payload")
            destination_handle.write(chunk)
            remaining -= len(chunk)


def repair(image: Path) -> None:
    image = image.resolve(strict=True)
    offset, compressor, block_size = image_layout(image)

    with tempfile.TemporaryDirectory(prefix="octoshrink-appimage-") as temporary:
        temporary_path = Path(temporary)
        app_dir = temporary_path / "squashfs-root"
        squashfs = temporary_path / "payload.squashfs"
        repaired_image = temporary_path / image.name

        subprocess.run(
            ["unsquashfs", "-no-progress", "-o", str(offset), "-d", str(app_dir), str(image)],
            check=True,
        )

        for launcher_name in ("AppRun", "AppRun.wrapped"):
            launcher = app_dir / launcher_name
            if launcher_name == "AppRun" and not launcher.is_file():
                raise FileNotFoundError(f"AppImage payload is missing {launcher_name}")
            if launcher.is_file():
                launcher.chmod(stat.S_IMODE(launcher.stat().st_mode) | 0o111)

        for executable in (app_dir / "usr" / "bin").glob("*"):
            if executable.is_file():
                executable.chmod(stat.S_IMODE(executable.stat().st_mode) | 0o111)

        subprocess.run(
            [
                "mksquashfs",
                str(app_dir),
                str(squashfs),
                "-noappend",
                "-comp",
                compressor,
                "-b",
                str(block_size),
                "-all-root",
                "-no-progress",
            ],
            check=True,
        )

        copy_prefix(image, repaired_image, offset)
        with repaired_image.open("ab") as output, squashfs.open("rb") as payload:
            shutil.copyfileobj(payload, output)

        repaired_image.chmod(stat.S_IMODE(image.stat().st_mode) | 0o111)
        os.replace(repaired_image, image)

    print(
        f"Repacked {image.name}: AppRun launchers are executable; "
        f"SquashFS uses {compressor} with {block_size}-byte blocks."
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {Path(sys.argv[0]).name} PATH_TO_APPIMAGE")
    repair(Path(sys.argv[1]))
