#!/bin/bash
# S2.sh — Multi-strip KH-9 jitter_solve pipeline (raw-space cascade).
# Adapted from ASP/stereo/jitter_pipeline.sh, parameterized by the resolved
# manifest produced by S0.sh.
#
# Usage:
#   bash scripts/S2.sh [config/config.yaml]
#
# Phase selection (default: from config.s2_phases):
#   PHASES="7 8" bash scripts/S2.sh
#
# Per-image parallelism (overrides config.compute.match_jobs):
#   MATCH_JOBS=6 bash scripts/S2.sh
#
# Exclude broken cameras from the GCP constraint:
#   SKIP_GCP_STRIPS="D3C1216-300814-014_fwd" bash scripts/S2.sh
#
# Phases (linear cascade — raw-space tile matching against Planet):
#    1. cam_gen          : optical bar .tsai → CSM linescan .json (sub16)
#    2. scale            : scale_linescan.py sub16 → sub8 → sub4
#    3. rig_setup        : rotate sub4 raw + symlink raw + symlink synth cameras
#    4. mapproject_synth : sub4 mapproject @ 4 m/px with synth cams (for stereo + Phase 6)
#    5. intra_strip_synth: parallel_stereo fwd↔aft per strip → 11 intra-strip match files
#    6. inter_strip_synth: bundle_adjust on adjacent fwd↔fwd (synth maps + cams) → 10 inter-strip matches
#    7. stage1_match     : raw_tile_match.py SIFT @ 10 m/px per image (parallel) → 22 GCP files
#    8. stage1_solve     : global jitter_solve with synth cams + stage1 GCPs + 21 matches → cameras_stage1
#    9. mapproject_stage1: sub4 mapproject @ 4 m/px with stage1 cams (basis for regen + stage2)
#   10. intra_strip_regen: re-run parallel_stereo on stage1 mapped → overwrite 11 intra match files
#   11. inter_strip_regen: re-run bundle_adjust on stage1 mapped → overwrite 10 inter match files
#   12. stage2_match     : raw_tile_match.py SIFT @ 10 m/px AND 4 m/px per image → concat 22 GCP files
#   13. stage2_solve     : global jitter_solve with stage1 cams + stage2 GCPs + fresh matches → cameras_stage2
#   14. stage2b_solve    : warm-start re-solve with same inputs → cameras_final (PRODUCTION)
#   15. qc_final         : qc_csm_cameras.py + orbit_plot + cam_test on cameras_final
#   16. mapproject_final : sub4 mapproject @ 4 m/px with cameras_final (bbox-gate skips 014_fwd)
#   17. mapproject_full  : scale sub4 → sub2 → full + mapproject @ 1 m/px → final/

set -euo pipefail

# ─── Python interpreter ────────────────────────────────────────────────────────
# Custom scripts (raw_tile_match.py, raw_npz_to_gcp.py, concat_gcps.py,
# scale_linescan.py, qc_csm_cameras.py) require packages from the ASP conda env:
#   rasterio, pyproj, numpy, cv2 (opencv), scipy, csmapi, usgscsm
#
# Override via: PYTHON=/path/to/conda/envs/asp/bin/python3 bash scripts/S2.sh
# Or activate the conda env before running: conda activate asp_py && bash scripts/S2.sh
PYTHON="${PYTHON:-python3}"

# Resolve which Python to use, in priority order:
#  1. PYTHON explicitly set by the caller (highest priority)
#  2. Active conda environment (conda activate asp_py sets $CONDA_PREFIX)
#  3. Python sibling of cam_gen in the ASP binary bundle (fallback — may lack csmapi)
if [ "${PYTHON}" = "python3" ]; then
  if [ -n "${CONDA_PREFIX:-}" ] && [ -x "$CONDA_PREFIX/bin/python3" ]; then
    PYTHON="$CONDA_PREFIX/bin/python3"
    echo "Using conda env Python: $PYTHON"
  elif command -v cam_gen &>/dev/null; then
    _asp_bin="$(dirname "$(command -v cam_gen)")"
    if [ -x "$_asp_bin/python3" ]; then
      PYTHON="$_asp_bin/python3"
      echo "Auto-detected ASP Python: $PYTHON (activate asp_py conda env for csmapi)"
    fi
  fi
fi

# Verify required packages are importable before any phase runs.
_check_python_env() {
  local missing="" pkg
  for pkg in numpy rasterio pyproj cv2; do
    "$PYTHON" -c "import $pkg" 2>/dev/null || missing="$missing $pkg"
  done
  if [ -n "$missing" ]; then
    echo "ERROR: Python packages missing from '$PYTHON':$missing"
    echo "  Activate the ASP conda environment, then re-run:"
    echo "    conda activate <asp-env> && bash scripts/S2.sh"
    echo "  Or set PYTHON explicitly:"
    echo "    PYTHON=/path/to/conda/envs/asp/bin/python3 bash scripts/S2.sh"
    exit 1
  fi
  "$PYTHON" -c "import scipy" 2>/dev/null \
    || echo "  WARNING: scipy not found — some helpers may be unavailable (install: conda install scipy)"
  "$PYTHON" -c "import csmapi" 2>/dev/null \
    || echo "  WARNING: csmapi not found — Phases 7 and 12 will fail (install: conda install -c conda-forge usgscsm)"
}
_check_python_env

# ─── Configuration (loaded from <working_dir>/inputs/manifest.resolved.json) ─
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${1:-${GKP_CONFIG:-$REPO_ROOT/config/config.yaml}}"
export GKP_CONFIG="$CFG"

# Per-run working tree (config.paths.working_dir).  Holds <working_dir>/inputs/
# (manifest, DEM, mosaics) and <working_dir>/output/<strip_id>/ (per-strip work).
WORK_DIR="$("$PYTHON" -c "from scripts.lib.config import load_config; print(load_config('$CFG').paths.working_dir)")"
INPUTS="$WORK_DIR/inputs"
RESOLVED="$INPUTS/manifest.resolved.json"
[[ -f "$RESOLVED" ]] || { echo "[S2] missing $RESOLVED — run S0.sh first" >&2; exit 1; }

# STEREO is the root holding per-strip working trees (forward_sub16.tif,
# aft_sub16.tif, ba_rpc_gcp_ht/, jitter_solve/, ...). S1 writes those under
# <working_dir>/output/<strip_id>/ — that's our $STEREO here.
STEREO="$WORK_DIR/output"
DEM="$INPUTS/dem.tif"
PLANET="$INPUTS/planet.tif"
RIG="$STEREO/multi-track-rig"

UTM_EPSG="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["utm_epsg"])' "$RESOLVED")"
UTM_T_SRS="EPSG:${UTM_EPSG}"

[[ -f "$DEM"    ]] || { echo "[S2] missing $DEM — run S0.sh"     >&2; exit 1; }
[[ -f "$PLANET" ]] || { echo "[S2] missing $PLANET (S0 phase 4 must populate Planet)" >&2; exit 1; }

# Per-strip artifact roots
CAM_DIR="$RIG/cameras"                  # synthetic cam symlinks (Phase 3)
RAW_DIR="$RIG/raw"                      # rotated sub4 raw symlinks (Phase 3)
MATCH_DIR="$RIG/ba_match"               # intra + inter strip .match files

# Raw-space matching artifacts (Phases 7, 12)
RAW_MATCH_DIR="$RIG/raw_match"
STAGE1_NPZ_DIR="$RAW_MATCH_DIR/stage1/npz"
STAGE1_GCP_DIR="$RAW_MATCH_DIR/stage1/gcps"
STAGE2_NPZ_DIR="$RAW_MATCH_DIR/stage2/npz"
STAGE2_GCP_DIR="$RAW_MATCH_DIR/stage2/gcps"

# Solve outputs (Phases 8, 13, 14)
CAM_STAGE1_DIR="$RIG/cameras_stage1"
CAM_STAGE2_DIR="$RIG/cameras_stage2"
CAM_FINAL_DIR="$RIG/cameras_final"

# Mapproject outputs
SYNTH_MAP_DIR="$RIG"                              # Phase 4
STAGE1_MAP_DIR="$RIG/jitter_mapped_stage1"        # Phase 9
FINAL_MAP_DIR="$RIG/jitter_mapped"                # Phase 16
CAM_FULL_DIR="$RIG/cameras_full"                  # Phase 17

# Phase 17 produces ~270 GB. Allow redirection via env vars:
#   FINAL_DIR=/mnt/f/.../final FULL_RES_WORK=/mnt/f/.../work bash scripts/S2.sh
FINAL_DIR="${FINAL_DIR:-$RIG/final}"
FULL_RES_WORK="${FULL_RES_WORK:-$STEREO}"

# Inter-strip BA work dirs
INTERSTRIP_SYNTH_DIR="$RIG/interstrip_ip"
INTERSTRIP_STAGE1_DIR="$RIG/interstrip_ip_stage1"

# Helper scripts (ported into scripts/lib/)
LIB="$REPO_ROOT/scripts/lib"
SCALE_LS="$LIB/scale_linescan.py"
QC_SCRIPT="$LIB/qc_csm_cameras.py"
RAW_TILE_MATCH="$LIB/raw_tile_match.py"
RAW_NPZ_TO_GCP="$LIB/raw_npz_to_gcp.py"
CONCAT_GCPS="$LIB/concat_gcps.py"

# Default phase list from config.s2_phases (env PHASES overrides).
DEFAULT_PHASES="$("$PYTHON" -c 'import json,sys; print(" ".join(str(p) for p in json.load(open(sys.argv[1]))["s2_phases"]))' "$RESOLVED")"
PHASES="${PHASES:-$DEFAULT_PHASES}"

# Default match parallelism from config.compute.match_jobs (env MATCH_JOBS overrides).
DEFAULT_MATCH_JOBS="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["compute"]["match_jobs"])' "$RESOLVED")"
MATCH_JOBS="${MATCH_JOBS:-$DEFAULT_MATCH_JOBS}"

# ─── Strip inventory (from resolved manifest) ─────────────────────────────────
# All strips produced by S1 use the same ba subdir + cam prefix (two BA rounds).
# This is simpler than the legacy ASP/stereo tree where strip 002 had a third BA pass.
mapfile -t STRIPS < <("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for s in data["strips"]:
    print(s["strip_id"])
' "$RESOLVED")
[[ ${#STRIPS[@]} -ge 1 ]] || { echo "[S2] resolved manifest has 0 strips" >&2; exit 1; }

declare -A BA_DIR=()
declare -A CAM_PFX=()
for S in "${STRIPS[@]}"; do
  BA_DIR[$S]="ba_rpc_gcp_ht"
  CAM_PFX[$S]="run-run-"
done

# INTER_PAIRS: latitudinal adjacency from median centroid lat (south → north).
# This requires looking up each strip's footprint, which we do via the lib.
mapfile -t INTER_PAIRS < <("$PYTHON" - "$RESOLVED" <<'PYEOF'
import json, sys
from scripts.lib import metadata as md, config as c
cfg = c.load_config()
data = json.load(open(sys.argv[1]))
items = []
for s in data["strips"]:
    eid = s["fwd"]["entity_id"]
    meta = md.lookup(cfg.paths.metadata_parquet, eid)
    cy = (meta.corners.nw[1] + meta.corners.ne[1] + meta.corners.se[1] + meta.corners.sw[1]) / 4.0
    items.append((cy, s["strip_id"]))
items.sort()
for (_, a), (_, b) in zip(items, items[1:]):
    print(f"{a} {b}")
PYEOF
)

# ─── Helpers ──────────────────────────────────────────────────────────────────
run_phase() { [[ " $PHASES " == *" $1 "* ]]; }

get_dim() {
  # Usage: get_dim <tif> <0=width|1=height>
  gdalinfo -json "$1" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['size'][$2])"
}

skip_if_exists() {
  # Returns 0 (true in bash) if file exists → caller should skip
  if [ -f "$1" ]; then
    echo "  [skip] $(basename "$1")"
    return 0
  fi
  return 1
}

# Symlink run-${STRIP}_${TAG}_sub4.adjusted_state.json (from SRC) under a clean
# stem ${STRIP}_${TAG}_sub4.json (in DST). jitter_solve names outputs by input
# basename, so clean stems → clean output names (avoids run-run-...adjusted_state.adjusted_state.json).
make_clean_symlinks() {
  local SRC="$1" DST="$2"
  mkdir -p "$DST"
  for STRIP in "${STRIPS[@]}"; do
    for TAG in fwd aft; do
      local SRC_F="$SRC/run-${STRIP}_${TAG}_sub4.adjusted_state.json"
      local DST_F="$DST/${STRIP}_${TAG}_sub4.json"
      if [ -f "$SRC_F" ] && [ ! -e "$DST_F" ]; then
        ln -sf "$(realpath "$SRC_F")" "$DST_F"
      fi
    done
  done
}

# Build the full list of 22 sub4 raw image paths
all_raw_images() {
  for STRIP in "${STRIPS[@]}"; do
    for TAG in fwd aft; do
      printf '%s\n' "$RAW_DIR/${STRIP}_${TAG}_sub4.tif"
    done
  done
}

echo "======================================================================"
echo "  KH-9 Multi-Strip Jitter Solve Pipeline (raw-space cascade)"
echo "  Phases:          $PHASES"
echo "  MATCH_JOBS:      $MATCH_JOBS"
echo "  FINAL_DIR:       $FINAL_DIR"
echo "  FULL_RES_WORK:   $FULL_RES_WORK"
echo "======================================================================"

# ─── Phase 1: cam_gen — optical bar tsai → CSM linescan .json (sub16) ────────
if run_phase 1; then
  echo ""
  echo "=== Phase 1: cam_gen (optical bar → CSM linescan, sub16 resolution) ==="
  for STRIP in "${STRIPS[@]}"; do
    SD="$STEREO/$STRIP"
    JS="$SD/jitter_solve"
    mkdir -p "$JS"
    BA="${BA_DIR[$STRIP]}"
    PFX="${CAM_PFX[$STRIP]}"

    for CAM in forward aft; do
      OUT="$JS/${CAM}_sub16.json"
      skip_if_exists "$OUT" && continue

      ORIG_TSAI="$SD/$BA/${PFX}${CAM}_sub16.tsai"
      PATCHED_TSAI="$JS/${CAM}_sub16.tsai"

      # cam_gen errors if the .tsai image_size doesn't exactly match the image.
      # Bundle_adjust can leave a few-pixel mismatch, so always patch image_size
      # from gdalinfo of the actual sub16 image.  The patched copy lives in
      # jitter_solve/; the original .tsai is never modified.
      ACT_W=$(get_dim "$SD/${CAM}_sub16.tif" 0)
      ACT_H=$(get_dim "$SD/${CAM}_sub16.tif" 1)
      TSAI_SZ=$(grep "^image_size" "$ORIG_TSAI" | awk '{print $3" "$4}')
      if [ "$TSAI_SZ" != "$ACT_W $ACT_H" ]; then
        echo "  NOTE: $STRIP/$CAM image_size mismatch: tsai=${TSAI_SZ}  actual=${ACT_W} ${ACT_H} — patching"
      fi
      sed "s/^image_size = .*/image_size = ${ACT_W} ${ACT_H}/" "$ORIG_TSAI" > "$PATCHED_TSAI"

      echo "  cam_gen: $STRIP / $CAM"
      cam_gen --camera-type linescan \
        "$SD/${CAM}_sub16.tif" \
        --input-camera "$PATCHED_TSAI" \
        -o "$OUT"
    done
  done
fi

# ─── Phase 2: scale cameras — sub16 → sub8 → sub4 ────────────────────────────
if run_phase 2; then
  echo ""
  echo "=== Phase 2: scale_linescan.py (sub16 → sub8 → sub4) ==="
  for STRIP in "${STRIPS[@]}"; do
    SD="$STEREO/$STRIP"
    JS="$SD/jitter_solve"

    for CAM in forward aft; do
      # sub16 → sub8
      # cam_gen rotates the camera in-sensor: m_nSamples = cross-scan (image height),
      # m_nLines = along-scan (image width).  scale_linescan.py args are out_samples
      # out_lines, so pass H (height = cross-scan) first, W (width = along-scan) second.
      OUT8="$JS/${CAM}_sub8.json"
      if ! skip_if_exists "$OUT8"; then
        W8=$(get_dim "$SD/${CAM}_sub8.tif" 0)
        H8=$(get_dim "$SD/${CAM}_sub8.tif" 1)
        echo "  scale sub16→sub8: $STRIP / $CAM  (samples=${H8}, lines=${W8})"
        "$PYTHON" "$SCALE_LS" "$JS/${CAM}_sub16.json" "$OUT8" "$H8" "$W8"
      fi

      # sub8 → sub4
      OUT4="$JS/${CAM}_sub4.json"
      if ! skip_if_exists "$OUT4"; then
        W4=$(get_dim "$SD/${CAM}_sub4.tif" 0)
        H4=$(get_dim "$SD/${CAM}_sub4.tif" 1)
        echo "  scale sub8→sub4:  $STRIP / $CAM  (samples=${H4}, lines=${W4})"
        "$PYTHON" "$SCALE_LS" "$OUT8" "$OUT4" "$H4" "$W4"
      fi
    done
  done
fi

# ─── Phase 3: rig setup — rotate sub4 raw + symlink raw + symlink synth cams ─
# Three steps that all establish the multi-track-rig/ working tree:
#   3a: image_mosaic --rotate-90 on sub4 raw images (in-place at $SD/jitter_solve/)
#   3b: symlink rotated sub4 raw images → $RAW_DIR with strip-prefixed names
#   3c: symlink sub4 synthetic cameras → $CAM_DIR with strip-prefixed names
# jitter_solve and bundle_adjust both require unique image and camera basenames
# so match-file naming is unambiguous across the 22-image multi-strip bundle.
if run_phase 3; then
  echo ""
  echo "=== Phase 3: rig setup (rotate raw + symlink raw + symlink synth cameras) ==="
  mkdir -p "$RAW_DIR" "$CAM_DIR"

  for STRIP in "${STRIPS[@]}"; do
    SD="$STEREO/$STRIP"
    JS="$SD/jitter_solve"
    mkdir -p "$JS"

    for CAM in forward aft; do
      TAG="${CAM/forward/fwd}"

      # 3a — rotate sub4 raw image in place (image_mosaic writes to JS)
      ROT="$JS/${CAM}_sub4.tif"
      if ! skip_if_exists "$ROT"; then
        echo "  3a rotate: $STRIP / $CAM"
        image_mosaic "$SD/${CAM}_sub4.tif" \
          --ot Byte \
          --rotate-90 \
          -o "$ROT"
      fi

      # 3b — symlink rotated raw to $RAW_DIR with strip-prefixed name.
      # Use a RELATIVE target so the symlinks survive being copied to another
      # machine where the absolute path would differ. From multi-track-rig/raw/
      # back to stereo/ is two levels up.
      RAW_DST="$RAW_DIR/${STRIP}_${TAG}_sub4.tif"
      if [ ! -L "$RAW_DST" ] && [ ! -f "$RAW_DST" ]; then
        ln -sf "../../${STRIP}/jitter_solve/${CAM}_sub4.tif" "$RAW_DST"
        echo "  3b linked raw:  $(basename "$RAW_DST")"
      fi

      # 3c — symlink synthetic sub4 camera to $CAM_DIR with strip-prefixed name
      CAM_DST="$CAM_DIR/${STRIP}_${TAG}_sub4.json"
      if [ ! -L "$CAM_DST" ] && [ ! -f "$CAM_DST" ]; then
        ln -sf "../../${STRIP}/jitter_solve/${CAM}_sub4.json" "$CAM_DST"
        echo "  3c linked cam:  $(basename "$CAM_DST")"
      fi
    done
  done
fi

# ─── Phase 4: mapproject sub4 with synthetic cameras @ 4 m/px ────────────────
# Outputs feed Phase 5 (intra-strip stereo) and Phase 6 (inter-strip BA).
# --threads 1 --jobs 1 because some synthetic-cam strips have large nominal
# envelopes; serializing keeps per-strip memory low. Phase 9 (mapproject with
# stage1 cams) and Phase 16 (final cams) use higher concurrency.
if run_phase 4; then
  echo ""
  echo "=== Phase 4: mapproject_synth (sub4, 4 m/px, synthetic cameras → multi-track-rig/) ==="
  mkdir -p "$RIG"

  for STRIP in "${STRIPS[@]}"; do
    JS="$STEREO/$STRIP/jitter_solve"

    for CAM in forward aft; do
      TAG="${CAM/forward/fwd}"
      OUT="$SYNTH_MAP_DIR/${STRIP}_${TAG}_sub4.map.tif"
      skip_if_exists "$OUT" && continue
      echo "  mapproject: $STRIP / $CAM"
      mapproject \
        --tr 4 \
        --t_srs "$UTM_T_SRS" \
        --ot Byte \
        --tif-compress LZW \
        --threads 1 \
        --parallel-options '--jobs 1' \
        "$DEM" \
        "$JS/${CAM}_sub4.tif" \
        "$JS/${CAM}_sub4.json" \
        "$OUT"
    done
  done
fi

# ─── Phase 5: intra-strip tie-points (parallel_stereo fwd↔aft) ───────────────
# Dense intra-strip matches via parallel_stereo. asp_bm + subpixel-mode 1 is
# used instead of asp_mgm + mode 9 to keep memory within bounds on this machine.
# Match quality is sufficient for jitter_solve — we need coverage, not sub-pixel
# disparity accuracy. Phase 10 regenerates these from stage1-mapped images.
if run_phase 5; then
  echo ""
  echo "=== Phase 5: intra_strip_synth (parallel_stereo fwd↔aft, synth cams + maps) ==="
  mkdir -p "$MATCH_DIR"

  for STRIP in "${STRIPS[@]}"; do
    STEREO_OUT="$STEREO/$STRIP/stereo_csm_sub4"
    CAM_FWD="$CAM_DIR/${STRIP}_fwd_sub4.json"
    CAM_AFT="$CAM_DIR/${STRIP}_aft_sub4.json"
    FWD_MAP="$SYNTH_MAP_DIR/${STRIP}_fwd_sub4.map.tif"
    AFT_MAP="$SYNTH_MAP_DIR/${STRIP}_aft_sub4.map.tif"
    STEREO_SENTINEL="$STEREO_OUT/.stereo_done"

    if [ ! -f "$STEREO_SENTINEL" ]; then
      echo "  stereo: $STRIP (fwd ↔ aft)"
      mkdir -p "$STEREO_OUT"
      parallel_stereo \
        --stereo-algorithm asp_bm \
        --subpixel-mode 1 \
        --alignment-method affineepipolar \
        -t csmmapcsm \
        --skip-rough-homography \
        --num-matches-from-disparity 100000 \
        --disable-tri-ip-filter \
        --ip-detect-method 1 \
        "$FWD_MAP" "$AFT_MAP" \
        "$CAM_FWD" "$CAM_AFT" \
        "$STEREO_OUT/run" \
        "$DEM"
      touch "$STEREO_SENTINEL"
    else
      echo "  [skip] dense stereo already done for $STRIP"
    fi

    # Sync the intra-strip disparity match file to $MATCH_DIR with a unique
    # strip-prefixed name so jitter_solve can locate it via RAW_DIR image stems.
    MATCH_SRC="$STEREO_OUT/run-disp-forward_sub4__aft_sub4.match"
    MATCH_DST="$MATCH_DIR/run-${STRIP}_fwd_sub4__${STRIP}_aft_sub4.match"
    if [ -f "$MATCH_SRC" ] && [ ! -f "$MATCH_DST" ]; then
      cp -f "$MATCH_SRC" "$MATCH_DST"
      echo "  synced: $(basename "$MATCH_DST")"
    elif [ -f "$MATCH_DST" ]; then
      echo "  [skip] $(basename "$MATCH_DST") already in $MATCH_DIR"
    else
      echo "  WARNING: $MATCH_SRC not found for $STRIP"
    fi
  done
fi

# ─── Phase 6: inter-strip tie-points from synthetic mapped + cams ────────────
# bundle_adjust on adjacent fwd↔fwd pairs to chain strips latitudinally before
# the stage 1 solve. Without this, stage1 would have each strip floating
# absolutely, with northern strips drifting north relative to Planet-anchored
# southern strips. Synthetic-mapped matches are sparser (~50K vs ~500K with
# corrected cams) — Phase 11 regenerates with stage1 cams for full match counts.
# Bumped --ip-per-tile 2000 → 4000 to compensate for the higher distortion in
# synthetic-mapped imagery (more RANSAC candidates needed to find enough inliers).
if run_phase 6; then
  echo ""
  echo "=== Phase 6: inter_strip_synth (bundle_adjust fwd↔fwd, synthetic maps + cams) ==="
  mkdir -p "$INTERSTRIP_SYNTH_DIR" "$MATCH_DIR"

  TAG=fwd
  for PAIR in "${INTER_PAIRS[@]}"; do
    read -r A B <<< "$PAIR"
    IMG_A="$SYNTH_MAP_DIR/${A}_${TAG}_sub4.map.tif"
    IMG_B="$SYNTH_MAP_DIR/${B}_${TAG}_sub4.map.tif"
    CAM_A="$CAM_DIR/${A}_${TAG}_sub4.json"
    CAM_B="$CAM_DIR/${B}_${TAG}_sub4.json"

    if [ ! -f "$IMG_A" ] || [ ! -f "$IMG_B" ] || [ ! -f "$CAM_A" ] || [ ! -f "$CAM_B" ]; then
      echo "  WARNING: missing input for $A↔$B — skipping"
      continue
    fi

    STEM_A="${A}_${TAG}_sub4"
    STEM_B="${B}_${TAG}_sub4"
    IMG_A_RAW="$RAW_DIR/${STEM_A}.tif"
    IMG_B_RAW="$RAW_DIR/${STEM_B}.tif"
    PAIR_OUT="$INTERSTRIP_SYNTH_DIR/${STEM_A}__${STEM_B}"
    MATCH_SRC="$PAIR_OUT/run-${STEM_A}__${STEM_B}.match"
    MATCH_DST="$MATCH_DIR/run-${STEM_A}__${STEM_B}.match"

    # Idempotency gate: if the match file already exists in MATCH_DIR, skip.
    # Re-runs only retry failed pairs.
    if [ -f "$MATCH_DST" ]; then
      echo "  [skip] $(basename "$MATCH_DST") already in $MATCH_DIR"
      continue
    fi

    echo "  bundle_adjust IP: $A ↔ $B ($TAG)"
    mkdir -p "$PAIR_OUT"
    rm -f "$MATCH_SRC"

    # See Phase 11 below for flag rationale (parallel-look pairs need:
    # --disable-tri-ip-filter, --ip-inlier-factor 5.0, --ip-uniqueness 0.95,
    # higher --ip-per-tile). Phase 6 doubles --ip-per-tile to 4000 because
    # synthetic-mapped imagery is more distorted than stage1-mapped.
    bundle_adjust \
      -t csm \
      "$IMG_A_RAW" "$IMG_B_RAW" \
      "$CAM_A" "$CAM_B" \
      --mapprojected-data "$IMG_A $IMG_B $DEM" \
      --datum WGS_1984 \
      --ip-detect-method 1 \
      --ip-per-tile 4000 \
      --ip-num-ransac-iterations 5000 \
      --ip-inlier-factor 5.0 \
      --ip-uniqueness-threshold 0.95 \
      --disable-tri-ip-filter \
      --max-pairwise-matches 10000 \
      --num-iterations 1 \
      --num-passes 1 \
      -o "$PAIR_OUT/run"

    if [ -f "$MATCH_SRC" ]; then
      cp -f "$MATCH_SRC" "$MATCH_DST"
      echo "  synced: $(basename "$MATCH_DST")"
    else
      echo "  WARNING: $MATCH_SRC not produced — see $PAIR_OUT for diagnostics"
    fi
  done
fi

# ─── Phase 7: stage1 raw-space matching against Planet @ 10 m/px ─────────────
# Per-image raw_tile_match.py SIFT @ 10 m/px with synthetic cameras as warp basis.
# Output: one NPZ + one GCP per image (22 total). Parallelized across images via
# xargs -P "${MATCH_JOBS:-6}". Each worker peaks ~2 GB RAM on 4 m/px tiles
# (stage1 is 10 m/px so closer to 1 GB; safer parallelism).
#
# Raw-space matching avoids the synthetic-cam distortion baked into globally
# mapprojected imagery (the Phase 4 maps that Phase 6 SIFT-against-Planet
# would have used in the old pipeline). Within each ~12 km × 12 km UTM tile,
# the synthetic-vs-true camera offset is approximately constant → matcher sees
# two near-aligned images differing by a single per-tile translation, which
# is exactly the regime SIFT is designed for.
stage1_match_one() {
  set -eu
  local RAW="$1"
  local STEM
  STEM="$(basename "$RAW" _sub4.tif)"   # e.g. D3C1216-300814-011_fwd
  local CAM="$CAM_DIR/${STEM}_sub4.json"
  local NPZ="$STAGE1_NPZ_DIR/${STEM}.10m.npz"
  local GCP="$STAGE1_GCP_DIR/${STEM}.gcp"

  if [ -f "$GCP" ]; then
    echo "  [skip] $(basename "$GCP")"
    return 0
  fi
  if [ ! -f "$CAM" ]; then
    echo "  ERROR: missing synth cam: $(basename "$CAM") — run Phase 3 first" >&2
    return 1
  fi

  if [ ! -f "$NPZ" ]; then
    echo "  stage1 match: $STEM"
    "$PYTHON" "$RAW_TILE_MATCH" \
      --raw "$RAW" \
      --planet "$PLANET" \
      --camera "$CAM" \
      --dem "$DEM" \
      --matcher sift \
      --match-res 10.0 \
      --tile-utm-km 12.0 \
      --tile-step-frac 0.5 \
      --sparse-step 64 \
      --utm-zone-epsg "$UTM_EPSG" \
      --max-keypoints 8000 \
      --min-confidence 0.0 \
      --device cpu \
      --output "$NPZ"
  fi

  echo "  stage1 gcp:   $STEM"
  "$PYTHON" "$RAW_NPZ_TO_GCP" \
    --npz "$NPZ" \
    --raw-image "$RAW" \
    --dem "$DEM" \
    --utm-zone-epsg "$UTM_EPSG" \
    --output "$GCP"
}
export -f stage1_match_one
export PYTHON RAW_TILE_MATCH RAW_NPZ_TO_GCP CAM_DIR STAGE1_NPZ_DIR STAGE1_GCP_DIR PLANET DEM

if run_phase 7; then
  echo ""
  echo "=== Phase 7: stage1_match (raw_tile_match SIFT @ 10 m/px, ${MATCH_JOBS} workers) ==="
  mkdir -p "$STAGE1_NPZ_DIR" "$STAGE1_GCP_DIR"

  if [ ! -f "$RAW_TILE_MATCH" ]; then
    echo "  ERROR: $RAW_TILE_MATCH not found" >&2
    exit 1
  fi

  # Allow individual worker failures (e.g. 014_fwd corrupt-camera crash) without
  # halting the whole pipeline. xargs returns 123 if any child fails; the GCP-count
  # summary below makes which images are missing explicit.
  set +e
  all_raw_images | \
    xargs -P "$MATCH_JOBS" -I{} bash -c 'stage1_match_one "$@"' _ {}
  XARGS_RC=$?
  set -e
  if [ "$XARGS_RC" -ne 0 ]; then
    echo "  WARNING: at least one stage1 worker exited non-zero (xargs rc=${XARGS_RC});"
    echo "           see counts below for which images are missing GCPs."
  fi

  echo ""
  echo "  Stage1 GCP counts:"
  for STRIP in "${STRIPS[@]}"; do
    for TAG in fwd aft; do
      G="$STAGE1_GCP_DIR/${STRIP}_${TAG}.gcp"
      if [ -f "$G" ]; then
        N=$(awk '!/^#/ && NF>10' "$G" | wc -l)
        printf "    %-30s : %6d GCPs\n" "${STRIP}_${TAG}" "$N"
      else
        printf "    %-30s : [missing]\n" "${STRIP}_${TAG}"
      fi
    done
  done
fi

# ─── Phase 8: stage1 global jitter_solve ─────────────────────────────────────
# Global solve over all 22 images: synth cams + stage1 GCPs + intra-strip ties
# (Phase 5) + inter-strip ties (Phase 6) + DEM anchors. Uses loose Phase-7-style
# uncertainty bounds (250 m DEM, 100 m position, 1000-line per-position/orientation)
# because the synthetic cameras have ~100 m position error that the solver needs
# room to absorb. --max-pairwise-matches 200000 from the start so all Phase 5 ties
# enter the solve, not just the default 10K cap.
if run_phase 8; then
  echo ""
  echo "=== Phase 8: stage1_solve (global jitter_solve from synth cams + stage1 GCPs) ==="
  mkdir -p "$CAM_STAGE1_DIR"

  FWD_IMGS=(); AFT_IMGS=()
  FWD_CAMS=(); AFT_CAMS=()
  ALL_GCPS=()

  for STRIP in "${STRIPS[@]}"; do
    FWD_IMGS+=("$RAW_DIR/${STRIP}_fwd_sub4.tif")
    AFT_IMGS+=("$RAW_DIR/${STRIP}_aft_sub4.tif")
    FWD_CAMS+=("$CAM_DIR/${STRIP}_fwd_sub4.json")
    AFT_CAMS+=("$CAM_DIR/${STRIP}_aft_sub4.json")

    for TAG in fwd aft; do
      # SKIP_GCP_STRIPS excludes specific images from the GCP constraint set.
      # Use for cameras with internal-contradiction GCPs (e.g. 014_fwd clouds).
      if [[ " ${SKIP_GCP_STRIPS:-} " == *" ${STRIP}_${TAG} "* ]]; then
        echo "  GCP excluded (SKIP_GCP_STRIPS): ${STRIP}_${TAG}"
        continue
      fi
      GCP="$STAGE1_GCP_DIR/${STRIP}_${TAG}.gcp"
      if [ -f "$GCP" ]; then
        ALL_GCPS+=("$GCP")
      else
        echo "  WARNING: stage1 GCP missing for ${STRIP}_${TAG} — run Phase 7 first"
      fi
    done
  done

  echo "  Images:       ${#FWD_IMGS[@]} forward + ${#AFT_IMGS[@]} aft"
  echo "  Cameras:      ${#FWD_CAMS[@]} + ${#AFT_CAMS[@]}  (synthetic CSM)"
  echo "  GCP files:    ${#ALL_GCPS[@]} (raw-space stage1 against Planet)"
  echo "  Match prefix: $MATCH_DIR/run"

  if [ ${#ALL_GCPS[@]} -eq 0 ]; then
    echo "  ERROR: No stage1 GCPs found — run Phase 7 first."
    exit 1
  fi

  # Camera position uncertainty: 100 m horizontal/vertical 1σ for stage 1.
  # Synthetic cam offset is ~100 m, so this gives the solver headroom but caps
  # runaway drift. Tightened to 50 m in stages 2/2b once cameras are corrected.
  UNCERT="$CAM_STAGE1_DIR/camera_position_uncertainty.txt"
  > "$UNCERT"
  for img in "${FWD_IMGS[@]}" "${AFT_IMGS[@]}"; do
    echo "$img 100 100" >> "$UNCERT"
  done

  jitter_solve \
    "${FWD_IMGS[@]}" "${AFT_IMGS[@]}" \
    "${FWD_CAMS[@]}" "${AFT_CAMS[@]}" \
    "${ALL_GCPS[@]}" \
    --match-files-prefix "$MATCH_DIR/run" \
    --max-pairwise-matches 200000 \
    --heights-from-dem "$DEM" \
    --heights-from-dem-uncertainty 250 \
    --num-lines-per-position 1000 \
    --num-lines-per-orientation 1000 \
    --num-anchor-points 100 \
    --num-anchor-points-extra-lines 500 \
    --anchor-weight 1.0 \
    --anchor-dem "$DEM" \
    --camera-position-uncertainty "$UNCERT" \
    --max-initial-reprojection-error 20 \
    --num-iterations 100 \
    -o "$CAM_STAGE1_DIR/run"

  echo ""
  echo "  Stage1 jitter_solve done. Residuals:"
  echo "    $CAM_STAGE1_DIR/run-final_residuals_stats.txt"
fi

# ─── Phase 9: mapproject sub4 with stage1 cameras @ 4 m/px ───────────────────
# Feeds Phase 10 (intra-strip regen), Phase 11 (inter-strip regen), and Phase 12
# (stage2 raw-matching — though stage2 only needs the stage1 cameras directly).
# Bbox-gate skips cameras with grossly inflated envelopes (corrupt cams).
if run_phase 9; then
  echo ""
  echo "=== Phase 9: mapproject_stage1 (sub4, 4 m/px, stage1 cameras) ==="
  mkdir -p "$STAGE1_MAP_DIR"

  for STRIP in "${STRIPS[@]}"; do
    for CAM in forward aft; do
      TAG="${CAM/forward/fwd}"
      RAW="$RAW_DIR/${STRIP}_${TAG}_sub4.tif"
      S1_CAM="$CAM_STAGE1_DIR/run-${STRIP}_${TAG}_sub4.adjusted_state.json"
      OUT="$STAGE1_MAP_DIR/${STRIP}_${TAG}_sub4.map.tif"

      if [ ! -f "$S1_CAM" ]; then
        echo "  WARNING: stage1 camera not found: $(basename "$S1_CAM") — run Phase 8 first"
        continue
      fi

      skip_if_exists "$OUT" && continue

      # Envelope gate — same thresholds as Phase 16 (sub4 maps with final cams).
      QUERY="$STAGE1_MAP_DIR/${STRIP}_${TAG}.query.txt"
      mapproject \
        --tr 4 \
        --t_srs "$UTM_T_SRS" \
        --query-projection \
        "$DEM" \
        "$RAW" \
        "$S1_CAM" \
        "$OUT" > "$QUERY" 2>&1 || true

      SIZE_LINE=$(grep -oE '\(width: [0-9]+ height: [0-9]+\)' "$QUERY" | head -1)
      W=$(echo "$SIZE_LINE" | sed -E 's/.*width: ([0-9]+).*/\1/')
      H=$(echo "$SIZE_LINE" | sed -E 's/.*height: ([0-9]+).*/\1/')
      if [ -z "$W" ] || [ -z "$H" ]; then
        echo "  WARNING: $STRIP/$CAM --query-projection produced no envelope — skipping"
        continue
      fi
      if [ "$W" -gt 95000 ] || [ "$H" -gt 30000 ]; then
        echo "  WARNING: $STRIP/$CAM envelope ${W}x${H} grossly inflated (cam likely corrupt) — skipping"
        continue
      fi

      echo "  mapproject: $STRIP / $CAM  (env ${W}x${H})"
      mapproject \
        --tr 4 \
        --t_srs "$UTM_T_SRS" \
        --ot Byte \
        --tif-compress LZW \
        --processes 4 \
        --threads 2 \
        --tile-size 5120 \
        --nodata-value 0 \
        "$DEM" \
        "$RAW" \
        "$S1_CAM" \
        "$OUT"
    done
  done
fi

# ─── Phase 10: regenerate intra-strip tie-points from stage1 mapped ──────────
# Old Phase 5 ties were generated from synthetic-mapped imagery; they encode
# small geometric distortion at scan-start. Fresh ties from stage1-mapped
# images encode stage1 camera geometry, which is ~50% closer to truth.
# Overwrites Phase 5 outputs in MATCH_DIR. Stereo work dir is separate
# (stereo_csm_sub4_stage1) so Phase 5 outputs remain inspectable.
if run_phase 10; then
  echo ""
  echo "=== Phase 10: intra_strip_regen (parallel_stereo fwd↔aft, stage1 maps + cams) ==="

  for STRIP in "${STRIPS[@]}"; do
    STEREO_OUT="$STEREO/$STRIP/stereo_csm_sub4_stage1"
    S1_RAW_FWD="$CAM_STAGE1_DIR/run-${STRIP}_fwd_sub4.adjusted_state.json"
    S1_RAW_AFT="$CAM_STAGE1_DIR/run-${STRIP}_aft_sub4.adjusted_state.json"
    FWD_MAP="$STAGE1_MAP_DIR/${STRIP}_fwd_sub4.map.tif"
    AFT_MAP="$STAGE1_MAP_DIR/${STRIP}_aft_sub4.map.tif"
    STEREO_SENTINEL="$STEREO_OUT/.stereo_done"

    if [ ! -f "$S1_RAW_FWD" ] || [ ! -f "$S1_RAW_AFT" ] || [ ! -f "$FWD_MAP" ] || [ ! -f "$AFT_MAP" ]; then
      echo "  WARNING: missing stage1 input for $STRIP — skipping"
      continue
    fi

    # Use clean-stem camera symlinks so the parallel_stereo disparity match
    # has a predictable basename (parallel_stereo embeds the camera-target
    # basename in run-disp-*.match naming when cameras are symlinked).
    mkdir -p "$STEREO_OUT/cameras_in"
    CAM_FWD="$STEREO_OUT/cameras_in/${STRIP}_fwd_sub4.json"
    CAM_AFT="$STEREO_OUT/cameras_in/${STRIP}_aft_sub4.json"
    ln -sf "$(realpath "$S1_RAW_FWD")" "$CAM_FWD"
    ln -sf "$(realpath "$S1_RAW_AFT")" "$CAM_AFT"

    if [ ! -f "$STEREO_SENTINEL" ]; then
      echo "  stereo: $STRIP (fwd ↔ aft, stage1 geometry)"
      mkdir -p "$STEREO_OUT"
      parallel_stereo \
        --stereo-algorithm asp_bm \
        --subpixel-mode 1 \
        --alignment-method affineepipolar \
        -t csmmapcsm \
        --skip-rough-homography \
        --num-matches-from-disparity 100000 \
        --disable-tri-ip-filter \
        --ip-detect-method 1 \
        "$FWD_MAP" "$AFT_MAP" \
        "$CAM_FWD" "$CAM_AFT" \
        "$STEREO_OUT/run" \
        "$DEM"
      touch "$STEREO_SENTINEL"
    else
      echo "  [skip] stage1 dense stereo already done for $STRIP"
    fi

    # Glob for whatever run-disp-*.match parallel_stereo produced (the exact
    # name depends on how ASP resolves camera symlinks). Overwrite the Phase 5
    # match file in MATCH_DIR with this stage1 version.
    MATCH_SRC=$(ls "$STEREO_OUT"/run-disp-*.match 2>/dev/null | head -1)
    MATCH_DST="$MATCH_DIR/run-${STRIP}_fwd_sub4__${STRIP}_aft_sub4.match"
    if [ -n "$MATCH_SRC" ] && [ -f "$MATCH_SRC" ]; then
      cp -f "$MATCH_SRC" "$MATCH_DST"
      echo "  overwrote: $(basename "$MATCH_DST")  <-- $(basename "$MATCH_SRC")"
    else
      echo "  WARNING: no run-disp-*.match in $STEREO_OUT — Phase 5 file kept"
    fi
  done
fi

# ─── Phase 11: regenerate inter-strip tie-points from stage1 mapped ──────────
# Re-run Phase 6 bundle_adjust on stage1-mapped images using stage1 cameras.
# Stage1 cameras are ~50% closer to truth than synthetic, so the mapped images
# overlap more cleanly — expect ~10× more inliers (~500K vs ~50K) per pair.
# Overwrites Phase 6 outputs in MATCH_DIR. Uses default --ip-per-tile 2000
# (stage1 maps are clean enough that doubling isn't needed).
if run_phase 11; then
  echo ""
  echo "=== Phase 11: inter_strip_regen (bundle_adjust fwd↔fwd, stage1 maps + cams) ==="
  mkdir -p "$INTERSTRIP_STAGE1_DIR"

  TAG=fwd
  for PAIR in "${INTER_PAIRS[@]}"; do
    read -r A B <<< "$PAIR"
    IMG_A="$STAGE1_MAP_DIR/${A}_${TAG}_sub4.map.tif"
    IMG_B="$STAGE1_MAP_DIR/${B}_${TAG}_sub4.map.tif"
    CAM_A="$CAM_STAGE1_DIR/run-${A}_${TAG}_sub4.adjusted_state.json"
    CAM_B="$CAM_STAGE1_DIR/run-${B}_${TAG}_sub4.adjusted_state.json"

    if [ ! -f "$IMG_A" ] || [ ! -f "$IMG_B" ] || [ ! -f "$CAM_A" ] || [ ! -f "$CAM_B" ]; then
      echo "  WARNING: missing stage1 input for $A↔$B — skipping"
      continue
    fi

    STEM_A="${A}_${TAG}_sub4"
    STEM_B="${B}_${TAG}_sub4"
    IMG_A_RAW="$RAW_DIR/${STEM_A}.tif"
    IMG_B_RAW="$RAW_DIR/${STEM_B}.tif"
    PAIR_OUT="$INTERSTRIP_STAGE1_DIR/${STEM_A}__${STEM_B}"
    MATCH_SRC="$PAIR_OUT/run-${STEM_A}__${STEM_B}.match"
    MATCH_DST="$MATCH_DIR/run-${STEM_A}__${STEM_B}.match"

    echo "  bundle_adjust IP: $A ↔ $B ($TAG, stage1 geometry)"
    mkdir -p "$PAIR_OUT"
    rm -f "$MATCH_SRC"

    # Why bundle_adjust + --mapprojected-data instead of parallel_stereo:
    #   parallel_stereo's preprocessor culls every IP within 4 px of nodata.
    #   Stage1 mapped images are still only ~23% non-nodata (KH-9 strip is a
    #   parallelogram inside a much larger UTM bbox), and SIFT keypoints
    #   concentrate at the high-contrast parallelogram boundary — so radius-4
    #   nodata cull wipes them all out. bundle_adjust does not apply that cull.
    #
    # Why these specific flags for low-baseline inter-strip pairs:
    #   --disable-tri-ip-filter: triangulation between near-parallel rays is
    #     numerically unstable; the post-IP triangulation filter rejects valid
    #     matches for low-baseline pairs (this killed 004↔016 and 010↔009 in
    #     the prior attempt without this flag).
    #   --ip-inlier-factor 5.0: loosens RANSAC inlier threshold ~25× from
    #     default. Small baselines produce poorly-conditioned epipolar models;
    #     tight inlier thresholds reject everything.
    #   --ip-uniqueness-threshold 0.95: accept more ambiguous matches.
    #     Same-sensor inter-strip features are visually similar, so ambiguity
    #     is higher than default 0.8 tolerates.
    #   --ip-per-tile 2000: 4× more candidates per tile than default; gives
    #     RANSAC more inliers to work with after the looser filters.
    #   --num-iterations 1: we want the match file, not adjusted cameras.
    bundle_adjust \
      -t csm \
      "$IMG_A_RAW" "$IMG_B_RAW" \
      "$CAM_A" "$CAM_B" \
      --mapprojected-data "$IMG_A $IMG_B $DEM" \
      --datum WGS_1984 \
      --ip-detect-method 1 \
      --ip-per-tile 2000 \
      --ip-num-ransac-iterations 5000 \
      --ip-inlier-factor 5.0 \
      --ip-uniqueness-threshold 0.95 \
      --disable-tri-ip-filter \
      --max-pairwise-matches 10000 \
      --num-iterations 1 \
      --num-passes 1 \
      -o "$PAIR_OUT/run"

    if [ -f "$MATCH_SRC" ]; then
      cp -f "$MATCH_SRC" "$MATCH_DST"
      echo "  overwrote: $(basename "$MATCH_DST")"
    else
      echo "  WARNING: $MATCH_SRC not produced — Phase 6 file kept; see $PAIR_OUT"
    fi
  done
fi

# ─── Phase 12: stage2 raw-space matching @ 10 m/px AND 4 m/px ────────────────
# Cascade refinement: re-match RAW vs Planet using stage1 cameras as the
# per-tile warp basis. Stage1 cameras are ~50% better than synthetic →
# per-tile warps now align Planet to almost-correct raw pixels → many more
# matches survive RANSAC, and they localize more precisely. Multi-resolution
# (10 m coarse + 4 m fine) is concat'd per image. --cam-filter-thresh 3 drops
# matches with raw-pixel disagreement > 3 px against the stage1 camera before
# they reach the solver (cheap pre-filter for noisy cross-sensor matches).
stage2_match_one() {
  set -eu
  local RAW="$1"
  local STEM
  STEM="$(basename "$RAW" _sub4.tif)"
  local FULL_STEM="${STEM}_sub4"
  local S1_CAM="$CAM_STAGE1_DIR/run-${FULL_STEM}.adjusted_state.json"
  local NPZ10="$STAGE2_NPZ_DIR/${STEM}.10m.npz"
  local NPZ4="$STAGE2_NPZ_DIR/${STEM}.4m.npz"
  local GCP="$STAGE2_GCP_DIR/${STEM}.gcp"
  local TMP10="${NPZ10%.npz}.gcp.tmp"
  local TMP4="${NPZ4%.npz}.gcp.tmp"

  if [ -f "$GCP" ]; then
    echo "  [skip] $(basename "$GCP")"
    return 0
  fi
  if [ ! -f "$S1_CAM" ]; then
    echo "  ERROR: missing stage1 cam: $(basename "$S1_CAM") — run Phase 8 first" >&2
    return 1
  fi

  if [ ! -f "$NPZ10" ]; then
    echo "  stage2 match 10m: $STEM"
    "$PYTHON" "$RAW_TILE_MATCH" \
      --raw "$RAW" \
      --planet "$PLANET" \
      --camera "$S1_CAM" \
      --dem "$DEM" \
      --matcher sift \
      --match-res 10.0 \
      --tile-utm-km 12.0 \
      --tile-step-frac 0.5 \
      --sparse-step 64 \
      --utm-zone-epsg "$UTM_EPSG" \
      --max-keypoints 8000 \
      --min-confidence 0.0 \
      --device cpu \
      --cam-filter-thresh 3 \
      --output "$NPZ10"
  fi

  if [ ! -f "$NPZ4" ]; then
    echo "  stage2 match 4m:  $STEM"
    "$PYTHON" "$RAW_TILE_MATCH" \
      --raw "$RAW" \
      --planet "$PLANET" \
      --camera "$S1_CAM" \
      --dem "$DEM" \
      --matcher sift \
      --match-res 4.0 \
      --tile-utm-km 6.0 \
      --tile-step-frac 0.5 \
      --sparse-step 64 \
      --utm-zone-epsg "$UTM_EPSG" \
      --max-keypoints 8000 \
      --min-confidence 0.0 \
      --device cpu \
      --cam-filter-thresh 3 \
      --output "$NPZ4"
  fi

  echo "  stage2 concat:    $STEM"
  "$PYTHON" "$RAW_NPZ_TO_GCP" --npz "$NPZ10" --raw-image "$RAW" --dem "$DEM" \
    --utm-zone-epsg "$UTM_EPSG" --output "$TMP10"
  "$PYTHON" "$RAW_NPZ_TO_GCP" --npz "$NPZ4"  --raw-image "$RAW" --dem "$DEM" \
    --utm-zone-epsg "$UTM_EPSG" --output "$TMP4"
  "$PYTHON" "$CONCAT_GCPS" "$GCP" "$TMP10" "$TMP4"
  rm -f "$TMP10" "$TMP4"
}
export -f stage2_match_one
export CONCAT_GCPS CAM_STAGE1_DIR STAGE2_NPZ_DIR STAGE2_GCP_DIR

if run_phase 12; then
  echo ""
  echo "=== Phase 12: stage2_match (raw_tile_match SIFT @ 10m + 4m, ${MATCH_JOBS} workers) ==="
  mkdir -p "$STAGE2_NPZ_DIR" "$STAGE2_GCP_DIR"

  set +e
  all_raw_images | \
    xargs -P "$MATCH_JOBS" -I{} bash -c 'stage2_match_one "$@"' _ {}
  XARGS_RC=$?
  set -e
  if [ "$XARGS_RC" -ne 0 ]; then
    echo "  WARNING: at least one stage2 worker exited non-zero (xargs rc=${XARGS_RC});"
    echo "           see counts below for which images are missing GCPs."
  fi

  echo ""
  echo "  Stage2 GCP counts:"
  for STRIP in "${STRIPS[@]}"; do
    for TAG in fwd aft; do
      G="$STAGE2_GCP_DIR/${STRIP}_${TAG}.gcp"
      if [ -f "$G" ]; then
        N=$(awk '!/^#/ && NF>10' "$G" | wc -l)
        printf "    %-30s : %6d GCPs\n" "${STRIP}_${TAG}" "$N"
      else
        printf "    %-30s : [missing]\n" "${STRIP}_${TAG}"
      fi
    done
  done
fi

# ─── Phase 13: stage2 global jitter_solve ────────────────────────────────────
# Re-solve starting from stage1 cameras + stage2 GCPs + fresh Phase 10/11 match
# files. Tighter uncertainty bounds vs stage1 (40 m DEM, 50 m position, 500-line
# per-position/orientation) because the starting point is already much closer
# to truth. --max-pairwise-matches 200000.
if run_phase 13; then
  echo ""
  echo "=== Phase 13: stage2_solve (global jitter_solve from stage1 cams + stage2 GCPs) ==="
  mkdir -p "$CAM_STAGE2_DIR"

  # Create clean-stem symlinks to stage1 outputs so jitter_solve writes outputs
  # with the same naming as stage1 (avoids run-run-...adjusted_state.adjusted_state.json).
  CAM_STAGE1_IN="$CAM_STAGE2_DIR/cameras_in"
  make_clean_symlinks "$CAM_STAGE1_DIR" "$CAM_STAGE1_IN"

  FWD_IMGS=(); AFT_IMGS=()
  FWD_CAMS=(); AFT_CAMS=()
  ALL_GCPS=()

  for STRIP in "${STRIPS[@]}"; do
    FWD_IMGS+=("$RAW_DIR/${STRIP}_fwd_sub4.tif")
    AFT_IMGS+=("$RAW_DIR/${STRIP}_aft_sub4.tif")
    FWD_CAMS+=("$CAM_STAGE1_IN/${STRIP}_fwd_sub4.json")
    AFT_CAMS+=("$CAM_STAGE1_IN/${STRIP}_aft_sub4.json")

    for TAG in fwd aft; do
      if [[ " ${SKIP_GCP_STRIPS:-} " == *" ${STRIP}_${TAG} "* ]]; then
        echo "  GCP excluded (SKIP_GCP_STRIPS): ${STRIP}_${TAG}"
        continue
      fi
      GCP="$STAGE2_GCP_DIR/${STRIP}_${TAG}.gcp"
      if [ -f "$GCP" ]; then
        ALL_GCPS+=("$GCP")
      else
        echo "  WARNING: stage2 GCP missing for ${STRIP}_${TAG} — run Phase 12 first"
      fi
    done
  done

  echo "  Images:       ${#FWD_IMGS[@]} forward + ${#AFT_IMGS[@]} aft"
  echo "  Cameras:      ${#FWD_CAMS[@]} + ${#AFT_CAMS[@]}  (stage1 via clean symlinks)"
  echo "  GCP files:    ${#ALL_GCPS[@]} (raw-space stage2 against Planet, 10m+4m concat)"
  echo "  Match prefix: $MATCH_DIR/run"

  if [ ${#ALL_GCPS[@]} -eq 0 ]; then
    echo "  ERROR: No stage2 GCPs found — run Phase 12 first."
    exit 1
  fi

  UNCERT="$CAM_STAGE2_DIR/camera_position_uncertainty.txt"
  > "$UNCERT"
  for img in "${FWD_IMGS[@]}" "${AFT_IMGS[@]}"; do
    echo "$img 50 50" >> "$UNCERT"
  done

  jitter_solve \
    "${FWD_IMGS[@]}" "${AFT_IMGS[@]}" \
    "${FWD_CAMS[@]}" "${AFT_CAMS[@]}" \
    "${ALL_GCPS[@]}" \
    --match-files-prefix "$MATCH_DIR/run" \
    --max-pairwise-matches 200000 \
    --heights-from-dem "$DEM" \
    --heights-from-dem-uncertainty 40 \
    --num-lines-per-position 500 \
    --num-lines-per-orientation 500 \
    --num-anchor-points 100 \
    --num-anchor-points-extra-lines 500 \
    --anchor-weight 1.0 \
    --anchor-dem "$DEM" \
    --camera-position-uncertainty "$UNCERT" \
    --max-initial-reprojection-error 20 \
    --num-iterations 100 \
    -o "$CAM_STAGE2_DIR/run"

  echo ""
  echo "  Stage2 jitter_solve done. Residuals:"
  echo "    $CAM_STAGE2_DIR/run-final_residuals_stats.txt"
fi

# ─── Phase 14: stage2b cap-lifted re-solve → PRODUCTION cameras ──────────────
# Warm-start from stage2 cameras with identical flags + GCPs + matches.
# Ceres restarts from a much better basin, so the cost-function evolves
# differently in the final passes — measurable additional refinement.
# 011 single-strip experiment: fwd global median 5.74 → 4.00 px (−30%);
# fwd own-residual median 6.65 → 0.30 px (essentially perfect self-consistency).
if run_phase 14; then
  echo ""
  echo "=== Phase 14: stage2b_solve (cap-lifted warm-start from stage2 → PRODUCTION) ==="
  mkdir -p "$CAM_FINAL_DIR"

  CAM_STAGE2_IN="$CAM_FINAL_DIR/cameras_in"
  make_clean_symlinks "$CAM_STAGE2_DIR" "$CAM_STAGE2_IN"

  FWD_IMGS=(); AFT_IMGS=()
  FWD_CAMS=(); AFT_CAMS=()
  ALL_GCPS=()

  for STRIP in "${STRIPS[@]}"; do
    FWD_IMGS+=("$RAW_DIR/${STRIP}_fwd_sub4.tif")
    AFT_IMGS+=("$RAW_DIR/${STRIP}_aft_sub4.tif")
    FWD_CAMS+=("$CAM_STAGE2_IN/${STRIP}_fwd_sub4.json")
    AFT_CAMS+=("$CAM_STAGE2_IN/${STRIP}_aft_sub4.json")

    for TAG in fwd aft; do
      if [[ " ${SKIP_GCP_STRIPS:-} " == *" ${STRIP}_${TAG} "* ]]; then
        echo "  GCP excluded (SKIP_GCP_STRIPS): ${STRIP}_${TAG}"
        continue
      fi
      GCP="$STAGE2_GCP_DIR/${STRIP}_${TAG}.gcp"
      if [ -f "$GCP" ]; then
        ALL_GCPS+=("$GCP")
      else
        echo "  WARNING: stage2 GCP missing for ${STRIP}_${TAG}"
      fi
    done
  done

  echo "  Images:       ${#FWD_IMGS[@]} forward + ${#AFT_IMGS[@]} aft"
  echo "  Cameras:      ${#FWD_CAMS[@]} + ${#AFT_CAMS[@]}  (stage2 via clean symlinks)"
  echo "  GCP files:    ${#ALL_GCPS[@]} (same stage2 GCPs as Phase 13)"
  echo "  Match prefix: $MATCH_DIR/run"

  UNCERT="$CAM_FINAL_DIR/camera_position_uncertainty.txt"
  > "$UNCERT"
  for img in "${FWD_IMGS[@]}" "${AFT_IMGS[@]}"; do
    echo "$img 50 50" >> "$UNCERT"
  done

  jitter_solve \
    "${FWD_IMGS[@]}" "${AFT_IMGS[@]}" \
    "${FWD_CAMS[@]}" "${AFT_CAMS[@]}" \
    "${ALL_GCPS[@]}" \
    --match-files-prefix "$MATCH_DIR/run" \
    --max-pairwise-matches 200000 \
    --heights-from-dem "$DEM" \
    --heights-from-dem-uncertainty 40 \
    --num-lines-per-position 500 \
    --num-lines-per-orientation 500 \
    --num-anchor-points 100 \
    --num-anchor-points-extra-lines 500 \
    --anchor-weight 1.0 \
    --anchor-dem "$DEM" \
    --camera-position-uncertainty "$UNCERT" \
    --max-initial-reprojection-error 20 \
    --num-iterations 100 \
    -o "$CAM_FINAL_DIR/run"

  echo ""
  echo "  Stage2b done — PRODUCTION cameras at:"
  echo "    $CAM_FINAL_DIR/run-*.adjusted_state.json"
  echo "  Residuals:"
  echo "    $CAM_FINAL_DIR/run-final_residuals_stats.txt"
fi

# ─── Phase 15: CSM camera QC on cameras_final ────────────────────────────────
# Three checks: orbit_plot.py (visual roll/pitch/yaw), cam_test (image→ground→
# image identity), qc_csm_cameras.py (structural hard gate). Thresholds are
# loose — 014_fwd cloud-contamination is expected to leave one camera in a
# stuck state, which Phase 16's bbox-gate auto-skips at render time.
if run_phase 15; then
  echo ""
  echo "=== Phase 15: qc_final (orbit_plot + cam_test + qc_csm_cameras) ==="
  mkdir -p "$RIG/qc/orbit_plots"

  # 15a — orbit_plot.py (visual; non-fatal if absent or fails).
  CAM_LIST="$RIG/qc/cam_list.txt"
  ls "$CAM_FINAL_DIR"/run-*.adjusted_state.json > "$CAM_LIST"
  if command -v orbit_plot.py >/dev/null 2>&1; then
    orbit_plot.py \
      --list "$CAM_LIST" \
      --orbit-id fwd,aft \
      --subtract-line-fit \
      --output-file "$RIG/qc/orbit_plots/cameras_final.png" \
      || echo "  WARNING: orbit_plot.py failed (non-fatal)"
  else
    echo "  [skip] orbit_plot.py not on PATH"
  fi

  # 15b — cam_test on every fwd+aft pair (non-fatal; results go to text files)
  if command -v cam_test >/dev/null 2>&1; then
    for STRIP in "${STRIPS[@]}"; do
      for TAG in fwd aft; do
        IMG="$RAW_DIR/${STRIP}_${TAG}_sub4.tif"
        CAM="$CAM_FINAL_DIR/run-${STRIP}_${TAG}_sub4.adjusted_state.json"
        if [ -f "$CAM" ] && [ -f "$IMG" ]; then
          cam_test --image "$IMG" --cam1 "$CAM" --cam2 "$CAM" \
            --session1 csm --session2 csm --sample-rate 100 \
            > "$RIG/qc/camtest_${STRIP}_${TAG}.txt" 2>&1 \
            || echo "  cam_test failed: $STRIP/$TAG"
        fi
      done
    done
  else
    echo "  [skip] cam_test not on PATH"
  fi

  # 15c — structural hard gate (set -e at top of file halts pipeline on failure).
  # Loose thresholds let any stuck-state camera (e.g. 014_fwd cloud-contamination)
  # pass QC so Phase 16 can proceed — bbox-gate skips it at render time.
  "$PYTHON" "$QC_SCRIPT" \
    --jitter-dir "$CAM_FINAL_DIR" \
    --stats-file "$CAM_FINAL_DIR/run-final_residuals_stats.txt" \
    --max-pos-spread-km 25 \
    --max-pos-delta-km 30 \
    --max-mean-residual 1e10 \
    --max-median-residual 5
fi

# ─── Phase 16: mapproject sub4 raw with cameras_final @ 4 m/px ───────────────
# Final sub4 ortho preview at 4 m/px. Bbox-gate auto-skips cameras whose
# envelope inflates past 95k×30k px (e.g. 014_fwd). Output feeds Phase 17.
if run_phase 16; then
  echo ""
  echo "=== Phase 16: mapproject_final (sub4, 4 m/px, cameras_final → jitter_mapped/) ==="
  mkdir -p "$FINAL_MAP_DIR"

  for STRIP in "${STRIPS[@]}"; do
    for CAM in forward aft; do
      TAG="${CAM/forward/fwd}"
      RAW="$RAW_DIR/${STRIP}_${TAG}_sub4.tif"
      FIN_CAM="$CAM_FINAL_DIR/run-${STRIP}_${TAG}_sub4.adjusted_state.json"
      OUT="$FINAL_MAP_DIR/${STRIP}_${TAG}_sub4.map.tif"

      if [ ! -f "$FIN_CAM" ]; then
        echo "  WARNING: final camera not found: $(basename "$FIN_CAM") — run Phase 14 first"
        continue
      fi

      skip_if_exists "$OUT" && continue

      # Envelope gate — same calibration as Phase 9.
      QUERY="$FINAL_MAP_DIR/${STRIP}_${TAG}.query.txt"
      mapproject \
        --tr 4 \
        --t_srs "$UTM_T_SRS" \
        --query-projection \
        "$DEM" \
        "$RAW" \
        "$FIN_CAM" \
        "$OUT" > "$QUERY" 2>&1 || true

      SIZE_LINE=$(grep -oE '\(width: [0-9]+ height: [0-9]+\)' "$QUERY" | head -1)
      W=$(echo "$SIZE_LINE" | sed -E 's/.*width: ([0-9]+).*/\1/')
      H=$(echo "$SIZE_LINE" | sed -E 's/.*height: ([0-9]+).*/\1/')
      if [ -z "$W" ] || [ -z "$H" ]; then
        echo "  WARNING: $STRIP/$CAM --query-projection produced no envelope — skipping"
        continue
      fi
      if [ "$W" -gt 95000 ] || [ "$H" -gt 30000 ]; then
        echo "  WARNING: $STRIP/$CAM envelope ${W}x${H} grossly inflated (cam likely corrupt) — skipping"
        continue
      fi

      echo "  mapproject: $STRIP / $CAM  (env ${W}x${H})"
      mapproject \
        --tr 4 \
        --t_srs "$UTM_T_SRS" \
        --ot Byte \
        --tif-compress LZW \
        --processes 4 \
        --threads 2 \
        --tile-size 5120 \
        --nodata-value 0 \
        "$DEM" \
        "$RAW" \
        "$FIN_CAM" \
        "$OUT"
    done
  done
fi

# ─── Phase 17: scale cameras_final sub4 → sub2 → full + full-res mapproject ──
# Two passes of scale_linescan.py (sub4→sub2, sub2→full). HEIGHT first (samples),
# WIDTH second (lines) — cam_gen rotates the sensor so samples=cross-scan=image-
# height. Full-res rotation uses image_mosaic --rotate-90, same as Phase 3.
# Mapproject at 1 m/px (~28 billion pixels per long strip). Bbox-gate skips
# inflated envelopes; --cache-size-mb 8192 --processes 1 --threads 4 avoids
# WSL OOM-kill on large mosaics.
if run_phase 17; then
  echo ""
  echo "=== Phase 17: mapproject_full (scale sub4→sub2→full + mapproject @ 1 m/px) ==="
  mkdir -p "$CAM_FULL_DIR" "$FINAL_DIR"

  for STRIP in "${STRIPS[@]}"; do
    SD="$STEREO/$STRIP"
    JS="$SD/jitter_solve"

    for CAM in forward aft; do
      TAG="${CAM/forward/fwd}"

      SOLVED="$CAM_FINAL_DIR/run-${STRIP}_${TAG}_sub4.adjusted_state.json"
      if [ ! -f "$SOLVED" ]; then
        echo "  WARNING: $(basename "$SOLVED") not found — skipping $STRIP/$CAM"
        continue
      fi

      # sub4 → sub2  (samples=H, lines=W)
      OUT2="$CAM_FULL_DIR/${STRIP}_${TAG}_sub2.json"
      if ! skip_if_exists "$OUT2"; then
        W2=$(get_dim "$SD/${CAM}_sub2.tif" 0)
        H2=$(get_dim "$SD/${CAM}_sub2.tif" 1)
        echo "  scale sub4→sub2: $STRIP / $CAM  (samples=${H2}, lines=${W2})"
        "$PYTHON" "$SCALE_LS" "$SOLVED" "$OUT2" "$H2" "$W2"
      fi

      # sub2 → full
      OUTF="$CAM_FULL_DIR/${STRIP}_${TAG}_full.json"
      if ! skip_if_exists "$OUTF"; then
        WF=$(get_dim "$SD/${CAM}.tif" 0)
        HF=$(get_dim "$SD/${CAM}.tif" 1)
        echo "  scale sub2→full: $STRIP / $CAM  (samples=${HF}, lines=${WF})"
        "$PYTHON" "$SCALE_LS" "$OUT2" "$OUTF" "$HF" "$WF"
      fi

      # Rotate full-resolution raw image (same as Phase 3, but for full res).
      # FULL_RES_WORK redirects these ~6.5 GB intermediates off the C: drive
      # when set; default is alongside the per-strip dirs.
      FULL_ROT_DIR="$FULL_RES_WORK/$STRIP/jitter_solve"
      FULL_ROT="$FULL_ROT_DIR/${CAM}_full_rot.tif"
      mkdir -p "$FULL_ROT_DIR"
      if ! skip_if_exists "$FULL_ROT"; then
        echo "  rotate full-res: $STRIP / $CAM  ($FULL_ROT)"
        image_mosaic "$SD/${CAM}.tif" \
          --ot Byte \
          --rotate-90 \
          -o "$FULL_ROT"
      fi

      # Mapproject at full resolution. 4× of sub4 thresholds for envelope gate.
      MAP_OUT="$FINAL_DIR/${STRIP}_${TAG}.map.tif"
      if ! skip_if_exists "$MAP_OUT"; then
        QUERY_FULL="$FINAL_DIR/${STRIP}_${TAG}.query.txt"
        mapproject \
          --tr 1 \
          --t_srs "$UTM_T_SRS" \
          --query-projection \
          "$DEM" \
          "$FULL_ROT" \
          "$OUTF" \
          "$MAP_OUT" > "$QUERY_FULL" 2>&1 || true
        SIZE_LINE=$(grep -oE '\(width: [0-9]+ height: [0-9]+\)' "$QUERY_FULL" | head -1)
        WF=$(echo "$SIZE_LINE" | sed -E 's/.*width: ([0-9]+).*/\1/')
        HF=$(echo "$SIZE_LINE" | sed -E 's/.*height: ([0-9]+).*/\1/')
        if [ -z "$WF" ] || [ -z "$HF" ]; then
          echo "  WARNING: $STRIP/$CAM full-res --query-projection no envelope — skipping"
          continue
        fi
        if [ "$WF" -gt 380000 ] || [ "$HF" -gt 120000 ]; then
          echo "  WARNING: $STRIP/$CAM full-res envelope ${WF}x${HF} grossly inflated — skipping"
          continue
        fi
        echo "  mapproject full-res: $STRIP / $CAM  (env ${WF}x${HF})"
        # Full-res KH-9 strips are ~28 billion pixels each. The default ASP
        # cache of 1024 MB triggers WSL OOM. --cache-size-mb 8192 + --processes 1
        # (single cache, not 4) + --threads 4 keeps CPU high without multiplying
        # memory.
        mapproject \
          --tr 1 \
          --t_srs "$UTM_T_SRS" \
          --ot Byte \
          --tif-compress LZW \
          --processes 1 \
          --threads 4 \
          --cache-size-mb 8192 \
          --tile-size 5120 \
          "$DEM" \
          "$FULL_ROT" \
          "$OUTF" \
          "$MAP_OUT"
      fi
    done
  done

  echo ""
  echo "  Full-resolution mapped images: $FINAL_DIR/"
fi

echo ""
echo "======================================================================"
echo "  Pipeline complete — phases run: $PHASES"
echo "======================================================================"
