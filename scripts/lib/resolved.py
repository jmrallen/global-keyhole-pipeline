"""Write/read the resolved manifest JSON that downstream stages consume."""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from . import config as cfg_mod
from . import footprint as fp_mod
from . import manifest as manifest_mod
from . import metadata as md_mod


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def build_resolved(cfg: cfg_mod.Config) -> dict:
    """Produce the resolved-manifest dict (does NOT include crop windows — those
    are filled in after image_mosaic + crop_detect runs in S0)."""
    strips = manifest_mod.resolve(cfg)
    fp = fp_mod.compute_footprint(cfg, strips)

    inputs_root = cfg.paths.working_dir / "inputs"
    mosaic_dir = inputs_root / "mosaics"
    cam_gen_dir = inputs_root / "cam_gen"

    def entity_record(ent: manifest_mod.Entity | None) -> dict | None:
        if ent is None:
            return None
        meta = md_mod.lookup(cfg.paths.metadata_parquet, ent.entity_id)
        return {
            "entity_id": ent.entity_id,
            "camera": ent.camera,
            "raw_dir": str(ent.raw_dir),
            "pieces": [str(p) for p in ent.pieces],
            "mosaic": str(mosaic_dir / f"{ent.entity_id}.tif"),
            "cam_gen_corners_file": str(cam_gen_dir / f"{ent.entity_id}.txt"),
            "lon_lat_values": meta.corners.to_lon_lat_values(),
            "crop": {
                "xoff": meta.crop_xoff,
                "yoff": meta.crop_yoff,
                "xsize": meta.crop_xsize,
                "ysize": meta.crop_ysize,
            },
        }

    return {
        "config_path": str(cfg.config_path),
        "raw_dir": str(cfg.raw_dir),
        "working_dir": str(cfg.paths.working_dir),
        "archive_dir": str(cfg.paths.archive_dir),
        "cameras_repo_dir": str(cfg.paths.cameras_repo_dir),
        "dem": str(inputs_root / "dem.tif"),
        "planet": str(inputs_root / "planet.tif"),
        "bbox": {
            "min_lon": fp["union_bbox"].min_lon,
            "min_lat": fp["union_bbox"].min_lat,
            "max_lon": fp["union_bbox"].max_lon,
            "max_lat": fp["union_bbox"].max_lat,
        },
        "utm_zone": fp["utm_zone"],
        "utm_hemisphere": fp["utm_hemisphere"],
        "utm_epsg": fp["utm_epsg"],
        "median_lon": fp["median_lon"],
        "median_lat": fp["median_lat"],
        "compute": {
            "match_jobs": cfg.compute.match_jobs,
            "threads_per_job": cfg.compute.threads_per_job,
        },
        "s1_phases": cfg.s1_phases,
        "s2_phases": cfg.s2_phases,
        "strips": [
            {
                "strip_id": s.strip_id,
                "fwd": entity_record(s.fwd),
                "aft": entity_record(s.aft),
                "extras": [entity_record(e) for e in s.extras],
            }
            for s in strips
        ],
    }


def write_resolved(cfg: cfg_mod.Config, out_path: Path | None = None) -> Path:
    out_path = out_path or (cfg.paths.working_dir / "inputs" / "manifest.resolved.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    data = build_resolved(cfg)
    out_path.write_text(json.dumps(data, indent=2) + "\n")
    log(f"[resolved] wrote {out_path}")
    return out_path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Write <working_dir>/inputs/manifest.resolved.json")
    p.add_argument("config", nargs="?", default=None)
    p.add_argument("--out", type=Path, default=None)
    args = p.parse_args(argv)

    cfg = cfg_mod.load_config(args.config)
    write_resolved(cfg, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
