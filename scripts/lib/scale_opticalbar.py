"""Scale an ASP OPTICAL_BAR .tsai camera to a different resolution.

Per ASP docs §8.26.2 / §8.29 (KH-9 workflow): the image_size and image_center
fields are in pixels and pitch is in metres-per-pixel.  Going to a resolution
whose pixels are N× SMALLER (i.e. sub16 → sub1, with N=16):

  image_size   *= N
  image_center *= N
  pitch        /= N

Going the opposite direction (sub1 → sub16, native to downsampled), pass a
fractional --scale (e.g. --scale 0.0625 for 1/16).

All other fields (focal length f, iC, iR, scan_dir, forward_tilt,
mean_surface_elevation, etc.) are copied through verbatim — they are physical
parameters independent of pixel sampling.

Usage:
    python -m scripts.lib.scale_opticalbar <in.tsai> <out.tsai> --scale N
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def scale_tsai(
    in_path: Path,
    out_path: Path,
    scale: float,
    override_size: tuple[int, int] | None = None,
) -> None:
    text = in_path.read_text()
    out_lines: list[str] = []
    saw_optical_bar = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "OPTICAL_BAR":
            saw_optical_bar = True

        if stripped.startswith("image_size") and "=" in line:
            key, _, rhs = line.partition("=")
            w, h = [float(tok) for tok in rhs.split()[:2]]
            # image_size is integer pixels. If --image-size was supplied, prefer
            # those exact dimensions over the scaled value — this absorbs the
            # off-by-a-few-pixels rounding between the sub16 mosaic crop and
            # the full-resolution tif.
            if override_size is not None:
                out_lines.append(f"{key.rstrip()} = {override_size[0]} {override_size[1]}")
            else:
                out_lines.append(f"{key.rstrip()} = {int(round(w * scale))} {int(round(h * scale))}")
        elif stripped.startswith("image_center") and "=" in line:
            key, _, rhs = line.partition("=")
            cx, cy = [float(tok) for tok in rhs.split()[:2]]
            out_lines.append(f"{key.rstrip()} = {cx * scale} {cy * scale}")
        elif stripped.startswith("pitch") and "=" in line and not stripped.startswith("pixel_pitch"):
            key, _, rhs = line.partition("=")
            p = float(rhs.split()[0])
            out_lines.append(f"{key.rstrip()} = {p / scale}")
        else:
            out_lines.append(line)

    if not saw_optical_bar:
        raise ValueError(
            f"{in_path} is not an OPTICAL_BAR camera (header line missing); refusing to scale"
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(out_lines) + "\n")
    log(f"[scale_opticalbar] {in_path} → {out_path} (scale={scale})")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("in_tsai", type=Path)
    p.add_argument("out_tsai", type=Path)
    p.add_argument(
        "--scale",
        type=float,
        required=True,
        help="output pixel count / input pixel count (e.g. 16 for sub16 → sub1)",
    )
    p.add_argument(
        "--image-size",
        type=int,
        nargs=2,
        metavar=("W", "H"),
        default=None,
        help="if given, override the scaled image_size with these exact pixel dimensions "
             "(use to absorb sub16↔full-res rounding from gdal_translate / pyramid creation)",
    )
    args = p.parse_args(argv)
    if args.scale <= 0:
        raise SystemExit("--scale must be > 0")
    size = tuple(args.image_size) if args.image_size else None
    scale_tsai(args.in_tsai, args.out_tsai, args.scale, size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
