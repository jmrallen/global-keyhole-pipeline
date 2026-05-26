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

echo "[S0] config       : $CFG"
echo "[S0] repo root    : $REPO_ROOT"
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
mkdir -p "$REPO_ROOT/inputs"
$PY -m scripts.lib.dem_tiles "$CFG" --out "$REPO_ROOT/inputs/dem.tif"

# --- Phase 4: Planet bbox mosaic (soft if stage 2 not requested) -----------
echo "[S0] === phase 4: Planet bbox mosaic ==="
PLANET_REQUIRED=""
if $PY -c "
import sys, yaml
data = yaml.safe_load(open('$CFG'))
sys.exit(0 if 2 in (data.get('stages') or []) else 1)
"; then
  PLANET_REQUIRED="--required"
  echo "[S0] stage 2 requested; Planet mosaic is required"
fi
$PY -m scripts.lib.planet_tiles "$CFG" --out "$REPO_ROOT/inputs/planet.tif" $PLANET_REQUIRED || {
  rc=$?
  if [[ -z "$PLANET_REQUIRED" ]]; then
    echo "[S0] Planet step exited $rc but stage 2 not requested; continuing"
  else
    exit $rc
  fi
}

# --- Phase 5: cam_gen corner files -----------------------------------------
echo "[S0] === phase 5: cam_gen corner files ==="
$PY -m scripts.lib.cam_gen_corners "$CFG" --out-dir "$REPO_ROOT/inputs/cam_gen"

# --- Phase 6: image_mosaic + crop detect (per entity) ----------------------
echo "[S0] === phase 6: image_mosaic + crop detect ==="
mkdir -p "$REPO_ROOT/inputs/mosaics"

# Pull the per-entity work list (entity_id + camera + piece paths) from the
# resolver as a TSV so the shell loop stays simple.
$PY - "$CFG" <<'PYEOF' > "$REPO_ROOT/inputs/_entities.tsv"
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
  MOSAIC="$REPO_ROOT/inputs/mosaics/${EID}.tif"

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
done < "$REPO_ROOT/inputs/_entities.tsv"

rm -f "$REPO_ROOT/inputs/_entities.tsv"

# --- Phase 7: emit resolved manifest ---------------------------------------
echo "[S0] === phase 7: write resolved manifest ==="
$PY -m scripts.lib.resolved "$CFG" --out "$REPO_ROOT/inputs/manifest.resolved.json"

echo "[S0] done."
