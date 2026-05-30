"""Write per-entity cam_gen --lon-lat-values text files."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import config as cfg_mod
from . import manifest as manifest_mod
from . import metadata as md_mod


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def write_corner_file(parquet_path: Path, entity_id: str, camera: str, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    meta = md_mod.lookup(parquet_path, entity_id)
    # Both forward and aft use NW→NE→SE→SW (UL→UR→LR→LL) corner ordering.
    # The aft image is already rotated 180° by image_mosaic --rotate during
    # mosaicking, which restores the expected geographic orientation so the
    # corner traversal matches the forward camera.
    out_path = out_dir / f"{entity_id}.txt"
    out_path.write_text(meta.corners.to_lon_lat_values() + "\n")
    log(f"[cam_gen_corners] wrote {out_path} (camera={camera})")
    return out_path


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Write cam_gen corner files for the configured manifest.")
    p.add_argument("config", nargs="?", default=None)
    p.add_argument("--out-dir", type=Path, default=None)
    args = p.parse_args(argv)

    cfg = cfg_mod.load_config(args.config)
    strips = manifest_mod.resolve(cfg)
    out_dir = args.out_dir or (cfg.paths.working_dir / "inputs" / "cam_gen")

    for s in strips:
        for ent in (s.fwd, s.aft, *s.extras):
            if ent is None:
                continue
            write_corner_file(cfg.paths.metadata_parquet, ent.entity_id, ent.camera, out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
