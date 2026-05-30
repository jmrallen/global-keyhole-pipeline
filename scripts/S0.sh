#!/usr/bin/env bash
# Stage 0 — pre-processing for the KH-9 pipeline.
# Resolves the manifest, builds DEM/Planet bbox mosaics, image_mosaics every
# entity, runs crop detection (persisting back to the parquet), and writes a
# resolved manifest JSON for S1/S2 to consume.
#
# Usage:
#   bash scripts/S0.sh [config/config.yaml]

set -euo pipefail

# --- Locate repo root and config -------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${1:-${GKP_CONFIG:-$REPO_ROOT/config/config.yaml}}"
if [[ ! -f "$CFG" ]]; then
  echo "[S0] config not found: $CFG" >&2
  exit 1
fi
export GKP_CONFIG="$CFG"

PY="${PYTHON:-python3}"
cd "$REPO_ROOT"

# Working directory (per-run tree on F: by default; see config.yaml).  All
# pipeline-generated state lives under here as $WORK_DIR/inputs/ and
# $WORK_DIR/output/.  The C: repo only holds code + cameras/sample/ templates +
# cameras/complete/ legacy backup.
WORK_DIR="$($PY -c "from scripts.lib.config import load_config; print(load_config('$CFG').paths.working_dir)")"
INPUTS="$WORK_DIR/inputs"
mkdir -p "$INPUTS"

echo "[S0] config       : $CFG"
echo "[S0] repo root    : $REPO_ROOT"
echo "[S0] working dir  : $WORK_DIR"
echo "[S0] python       : $($PY -c 'import sys; print(sys.executable)')"

# --- Phase 1: validate config + resolve manifest ---------------------------
echo "[S0] === phase 1: validate config + resolve manifest ==="
$PY -m scripts.lib.config "$CFG"
$PY -m scripts.lib.manifest "$CFG" > /dev/null   # surface any resolution errors early

# --- Phase 2: footprint + contiguity gate ----------------------------------
echo "[S0] === phase 2: footprint + UTM zone + contiguity gate ==="
$PY -m scripts.lib.footprint "$CFG"

# --- Phase 3: DEM bbox mosaic ----------------------------------------------
echo "[S0] === phase 3: DEM bbox mosaic ==="
$PY -m scripts.lib.dem_tiles "$CFG" --out "$INPUTS/dem.tif"

# --- Phase 3b: blurred DEM for mapprojection (ASP docs §6.1.7.3, §8.30.6) ---
# S1 mapprojects against this blurred copy; the sharp dem.tif stays the height
# reference for cam_gen, bundle_adjust --heights-from-dem, dem2gcp, point2dem.
if [[ ! -f "$INPUTS/dem_blur.tif" ]]; then
  echo "[S0] === phase 3b: blurred DEM (dem_mosaic --dem-blur-sigma 5) ==="
  dem_mosaic --dem-blur-sigma 5 "$INPUTS/dem.tif" -o "$INPUTS/dem_blur.tif"
else
  echo "[S0] === phase 3b: dem_blur.tif exists — skipping ==="
fi

# --- Phase 4: Planet bbox mosaic (always soft — S2.sh enforces hard gate) ---
echo "[S0] === phase 4: Planet bbox mosaic ==="
$PY -m scripts.lib.planet_tiles "$CFG" --out "$INPUTS/planet.tif" || {
  echo "[S0] Planet step exited $? — no tiles found; continuing (S2 will fail until populated)"
}

# --- Phase 5: cam_gen corner files -----------------------------------------
echo "[S0] === phase 5: cam_gen corner files ==="
$PY -m scripts.lib.cam_gen_corners "$CFG" --out-dir "$INPUTS/cam_gen"

# --- Phase 6: image_mosaic + crop detect (per entity) ----------------------
echo "[S0] === phase 6: image_mosaic + crop detect ==="
mkdir -p "$INPUTS/mosaics"

# Pull the per-entity work list (entity_id + camera + piece paths) from the
# resolver as a TSV so the shell loop stays simple.
$PY - "$CFG" <<'PYEOF' > "$INPUTS/_entities.tsv"
import sys
from scripts.lib import config as c, manifest as m
cfg = c.load_config(sys.argv[1])
for s in m.resolve(cfg):
    for ent in (s.fwd, s.aft):
        if ent is None:
            continue
        print("\t".join([ent.entity_id, ent.camera, *(str(p) for p in ent.pieces)]))
PYEOF

PARQUET="$($PY -c "from scripts.lib.config import load_config; print(load_config('$CFG').paths.metadata_parquet)")"
REUSE="$($PY -c "from scripts.lib.config import load_config; print('1' if load_config('$CFG').crop_reuse_parquet else '0')")"

while IFS=$'\t' read -r EID CAM REST; do
  IFS=$'\t' read -r -a PIECES <<< "$REST"
  MOSAIC="$INPUTS/mosaics/${EID}.tif"

  if [[ ! -f "$MOSAIC" ]]; then
    echo "[S0]   image_mosaic $EID ($CAM, ${#PIECES[@]} pieces)"
    ROTATE_FLAG=()
    [[ "$CAM" == "aft" ]] && ROTATE_FLAG=(--rotate)
    image_mosaic --ot byte --overlap-width 3000 "${ROTATE_FLAG[@]}" \
      -o "$MOSAIC" "${PIECES[@]}"
  else
    echo "[S0]   image_mosaic $EID — cached ($MOSAIC)"
  fi

  HAS_CROP="$($PY -c "
from scripts.lib.metadata import lookup
m = lookup('$PARQUET', '$EID')
print('1' if m.has_crop else '0')
")"
  if [[ "$REUSE" == "1" && "$HAS_CROP" == "1" ]]; then
    echo "[S0]   crop $EID — cached in parquet"
  else
    echo "[S0]   crop_detect $EID"
    $PY -m scripts.lib.crop_detect "$MOSAIC" \
      --metadata-parquet "$PARQUET" \
      --entity-id "$EID"
  fi
done < "$INPUTS/_entities.tsv"

rm -f "$INPUTS/_entities.tsv"

# --- Phase 7: emit resolved manifest ---------------------------------------
echo "[S0] === phase 7: write resolved manifest ==="
$PY -m scripts.lib.resolved "$CFG" --out "$INPUTS/manifest.resolved.json"

# --- Phase 7a: per-run camera templates with dynamic mean_surface_elevation ---
# cam_gen --sample-file reads the .tsai literally; the template's
# mean_surface_elevation field becomes the initial ground assumption for cam
# refinement and BA1.  A static value (800 m in the Pamir-derived template)
# is wrong for AOIs at different mean elevations.  Compute the actual mean
# from inputs/dem.tif and emit per-run copies under inputs/cameras/.
echo "[S0] === phase 7a: per-run camera templates (dynamic mean elevation) ==="
mkdir -p "$INPUTS/cameras"
# gdalinfo -stats writes a .aux.xml sidecar and prints STATISTICS_MEAN=<float>.
MEAN_ELEV=$(gdalinfo -stats "$INPUTS/dem.tif" \
  | awk -F= '/STATISTICS_MEAN/{printf "%.0f", $2; exit}')
if [[ -z "$MEAN_ELEV" ]]; then
  echo "[S0]   WARNING: could not extract STATISTICS_MEAN from dem.tif — leaving template default"
else
  echo "[S0]   mean DEM elevation: ${MEAN_ELEV} m (was 800 in sample template)"
fi
for CAM in forward aft; do
  SRC="$REPO_ROOT/cameras/sample/${CAM}_sub16.tsai"
  DST="$INPUTS/cameras/${CAM}_sub16.tsai"
  if [[ ! -f "$SRC" ]]; then
    echo "[S0]   WARNING: $SRC missing — skipping $CAM template"
    continue
  fi
  if [[ -n "$MEAN_ELEV" ]]; then
    sed "s/^mean_surface_elevation = .*/mean_surface_elevation = ${MEAN_ELEV}/" "$SRC" > "$DST"
  else
    cp "$SRC" "$DST"
  fi
  echo "[S0]   wrote $DST"
done

# --- Phase 7b: DEM reprojected to local UTM (hillshade + diagnostics) ------
# inputs/dem.tif is WGS84 geographic (degrees) — gdaldem hillshade's default
# -s 1 misinterprets that as 1 m horizontal per 1 m vertical, producing a
# washed-out hillshade.  inputs/dem_utm.tif is the same DEM reprojected to
# the strip-set's local UTM zone at 30 m/px, so default hillshade settings
# (s=1, z=1) are correct and the relief renders with full contrast.
# Used by S1 Phase 8 for the reference hillshade; also handy for diagnostics.
if [[ ! -f "$INPUTS/dem_utm.tif" ]]; then
  echo "[S0] === phase 7b: reproject DEM to local UTM (dem_utm.tif) ==="
  UTM_EPSG=$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["utm_epsg"])' \
    "$INPUTS/manifest.resolved.json")
  gdalwarp -t_srs "EPSG:$UTM_EPSG" -tr 30 30 -r bilinear -of GTiff \
    -co COMPRESS=LZW -co TILED=YES \
    "$INPUTS/dem.tif" "$INPUTS/dem_utm.tif"
else
  echo "[S0] === phase 7b: dem_utm.tif exists — skipping ==="
fi

echo "[S0] done."
