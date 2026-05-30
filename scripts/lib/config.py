"""Parse and validate config/config.yaml for the KH-9 pipeline."""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


@dataclass
class ComputeCfg:
    match_jobs: int = 6
    threads_per_job: int = 4


@dataclass
class PathsCfg:
    metadata_parquet: Path
    dem_tiles_dir: Path
    planet_tiles_dir: Path
    # Per-run working tree (holds <working_dir>/inputs/ and <working_dir>/output/).
    working_dir: Path
    # Permanent multi-run archive (cameras/OBC, cameras/CSM, images/mapproject-{16m,1m}, DSM/DSM-{16m,1m}).
    archive_dir: Path
    # Legacy on-repo camera backup root, e.g. ./cameras/complete/ — OBC/ and CSM/ subdirs live underneath.
    cameras_repo_dir: Path


@dataclass
class ManifestCfg:
    subdir: str | None = None
    entity_ids: list[str] = field(default_factory=list)


@dataclass
class Config:
    raw_dir: Path
    manifest: ManifestCfg
    compute: ComputeCfg
    paths: PathsCfg
    bbox_pad_deg: float
    crop_reuse_parquet: bool
    stages: list[int]
    s1_phases: list[int]
    s2_phases: list[int]
    config_path: Path


def _resolve_path(value: str, base: Path) -> Path:
    p = Path(value)
    if not p.is_absolute():
        p = (base / p).resolve()
    return p


def load_config(path: str | Path | None = None) -> Config:
    """Load and validate a config.yaml. ``path`` falls back to $GKP_CONFIG or
    ``config/config.yaml`` relative to the repo root."""
    if path is None:
        path = os.environ.get("GKP_CONFIG")
    if path is None:
        # repo root is two dirs up from this file (scripts/lib/config.py)
        path = Path(__file__).resolve().parents[2] / "config" / "config.yaml"
    path = Path(path).resolve()
    if not path.exists():
        raise FileNotFoundError(f"config file not found: {path}")

    with open(path) as f:
        data: dict[str, Any] = yaml.safe_load(f)

    repo_root = Path(__file__).resolve().parents[2]
    base = path.parent  # relative paths in config are resolved against the config's dir

    raw_dir = _resolve_path(data["raw_dir"], base)

    manifest_raw = data.get("manifest") or {}
    manifest = ManifestCfg(
        subdir=manifest_raw.get("subdir"),
        entity_ids=list(manifest_raw.get("entity_ids") or []),
    )
    if (manifest.subdir is None) == (not manifest.entity_ids):
        raise ValueError(
            "config.manifest must specify exactly one of `subdir` or `entity_ids`"
        )

    compute_raw = data.get("compute") or {}
    compute = ComputeCfg(
        match_jobs=int(compute_raw.get("match_jobs", 6)),
        threads_per_job=int(compute_raw.get("threads_per_job", 4)),
    )

    paths_raw = data.get("paths") or {}
    # metadata_parquet and cameras_repo_dir are most often given relative to the repo root.
    parquet_value = paths_raw.get("metadata_parquet", "./assets/declass3_metadata.parquet")
    cameras_repo_value = paths_raw.get("cameras_repo_dir", "./cameras/complete/")
    paths = PathsCfg(
        metadata_parquet=_resolve_path(parquet_value, repo_root if parquet_value.startswith("./") else base),
        dem_tiles_dir=_resolve_path(paths_raw["dem_tiles_dir"], base),
        planet_tiles_dir=_resolve_path(paths_raw["planet_tiles_dir"], base),
        working_dir=_resolve_path(paths_raw["working_dir"], base),
        archive_dir=_resolve_path(paths_raw["archive_dir"], base),
        cameras_repo_dir=_resolve_path(cameras_repo_value, repo_root if cameras_repo_value.startswith("./") else base),
    )

    bbox_pad_deg = float((data.get("bbox") or {}).get("pad_deg", 0.01))
    crop_reuse_parquet = bool((data.get("crop") or {}).get("reuse_parquet", True))
    stages = [int(s) for s in data.get("stages", [0, 1, 2])]
    s1_phases = [int(s) for s in data.get("s1_phases", list(range(1, 16)))]
    s2_phases = [int(s) for s in data.get("s2_phases", list(range(1, 18)))]

    return Config(
        raw_dir=raw_dir,
        manifest=manifest,
        compute=compute,
        paths=paths,
        bbox_pad_deg=bbox_pad_deg,
        crop_reuse_parquet=crop_reuse_parquet,
        stages=stages,
        s1_phases=s1_phases,
        s2_phases=s2_phases,
        config_path=path,
    )


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    import argparse

    p = argparse.ArgumentParser(description="Validate a config.yaml and print resolved values.")
    p.add_argument("config", nargs="?", default=None, help="path to config.yaml")
    args = p.parse_args(argv)

    cfg = load_config(args.config)
    log(f"[config] loaded {cfg.config_path}")
    log(f"[config] raw_dir            = {cfg.raw_dir}")
    if cfg.manifest.subdir:
        log(f"[config] manifest.subdir    = {cfg.manifest.subdir}")
    else:
        log(f"[config] manifest.entity_ids = {len(cfg.manifest.entity_ids)} ids")
    log(f"[config] metadata_parquet   = {cfg.paths.metadata_parquet}")
    log(f"[config] dem_tiles_dir      = {cfg.paths.dem_tiles_dir}")
    log(f"[config] planet_tiles_dir   = {cfg.paths.planet_tiles_dir}")
    log(f"[config] working_dir        = {cfg.paths.working_dir}")
    log(f"[config] archive_dir        = {cfg.paths.archive_dir}")
    log(f"[config] cameras_repo_dir   = {cfg.paths.cameras_repo_dir}")
    log(f"[config] stages             = {cfg.stages}")
    log(f"[config] s1_phases          = {cfg.s1_phases}")
    log(f"[config] s2_phases          = {cfg.s2_phases}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
