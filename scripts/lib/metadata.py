"""Lookup KH-9 image corner coordinates from the declass metadata parquet."""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from . import config as cfg_mod

ENTITY_ID_COL = "Entity ID"

# Decimal-degree corner columns in the parquet (Phase 1 finding).
CORNER_COLS = {
    "nw": ("NW Corne_2", "NW Corne_3"),  # (lat, lon) — verified below
    "ne": ("NE Corne_2", "NE Corne_3"),
    "se": ("SE Corne_2", "SE Corne_3"),
    "sw": ("SW Corne_2", "SW Corne_3"),
}
CROP_COLS = ("crop_xoff", "crop_yoff", "crop_xsize", "crop_ysize")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


@dataclass
class Corners:
    """Image corner coordinates in decimal degrees (lon, lat)."""
    nw: tuple[float, float]
    ne: tuple[float, float]
    se: tuple[float, float]
    sw: tuple[float, float]

    def to_lon_lat_values(self) -> str:
        """Format as cam_gen --lon-lat-values expects: 'lon lat lon lat lon lat lon lat'
        in NW, NE, SE, SW order (top-left, top-right, bottom-right, bottom-left).
        Use for the forward camera (not rotated)."""
        return " ".join(f"{v:.6f}" for c in (self.nw, self.ne, self.se, self.sw) for v in c)

    def to_lon_lat_values_aft(self) -> str:
        """Corner order for a 180°-rotated aft image: SE, SW, NW, NE.
        After 180° rotation the original SE corner is at the image top-left,
        so the traversal (TL→TR→BR→BL) maps to SE→SW→NW→NE."""
        return " ".join(f"{v:.6f}" for c in (self.se, self.sw, self.nw, self.ne) for v in c)


@dataclass
class ImageMeta:
    entity_id: str
    corners: Corners
    crop_xoff: int | None
    crop_yoff: int | None
    crop_xsize: int | None
    crop_ysize: int | None

    @property
    def has_crop(self) -> bool:
        return all(v is not None for v in (self.crop_xoff, self.crop_yoff, self.crop_xsize, self.crop_ysize))


@lru_cache(maxsize=4)
def _load_parquet(path_str: str):
    import pandas as pd
    log(f"[metadata] loading {path_str}")
    df = pd.read_parquet(path_str)
    if ENTITY_ID_COL not in df.columns:
        raise ValueError(f"parquet missing {ENTITY_ID_COL!r}: cols={list(df.columns)[:8]}...")
    return df.set_index(ENTITY_ID_COL, drop=False)


def _corner_from_row(row, key: str) -> tuple[float, float]:
    """Return (lon, lat) for one corner. The parquet stores them as
    `<X> Corne_2` (latitude) and `<X> Corne_3` (longitude)."""
    lat_col, lon_col = CORNER_COLS[key]
    lat = float(row[lat_col])
    lon = float(row[lon_col])
    return (lon, lat)


def _get_int_or_none(row, col: str) -> int | None:
    if col not in row.index:
        return None
    v = row[col]
    try:
        import pandas as pd
        if pd.isna(v):
            return None
    except Exception:
        if v is None:
            return None
    return int(v)


def lookup(parquet_path: Path, entity_id: str) -> ImageMeta:
    df = _load_parquet(str(parquet_path))
    if entity_id not in df.index:
        raise KeyError(f"entity id {entity_id!r} not found in {parquet_path.name}")
    matches = df.loc[[entity_id]]
    if len(matches) > 1:
        log(f"[metadata] WARNING: {len(matches)} rows for {entity_id}; using first")
    row = matches.iloc[0]

    corners = Corners(
        nw=_corner_from_row(row, "nw"),
        ne=_corner_from_row(row, "ne"),
        se=_corner_from_row(row, "se"),
        sw=_corner_from_row(row, "sw"),
    )
    return ImageMeta(
        entity_id=entity_id,
        corners=corners,
        crop_xoff=_get_int_or_none(row, "crop_xoff"),
        crop_yoff=_get_int_or_none(row, "crop_yoff"),
        crop_xsize=_get_int_or_none(row, "crop_xsize"),
        crop_ysize=_get_int_or_none(row, "crop_ysize"),
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Print corner+crop metadata for one entity.")
    p.add_argument("entity_id")
    p.add_argument("--config", default=None)
    args = p.parse_args(argv)

    cfg = cfg_mod.load_config(args.config)
    meta = lookup(cfg.paths.metadata_parquet, args.entity_id)
    print(json.dumps({
        "entity_id": meta.entity_id,
        "corners": {
            "nw": meta.corners.nw,
            "ne": meta.corners.ne,
            "se": meta.corners.se,
            "sw": meta.corners.sw,
        },
        "lon_lat_values": meta.corners.to_lon_lat_values(),
        "crop_xoff": meta.crop_xoff,
        "crop_yoff": meta.crop_yoff,
        "crop_xsize": meta.crop_xsize,
        "crop_ysize": meta.crop_ysize,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
