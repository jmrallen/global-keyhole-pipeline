#!/usr/bin/env bash
# Stage 1 — per-pair camera optimization (forward + aft).
#
# For each strip in inputs/manifest.resolved.json:
#   1. Crop the entity mosaic (full-res) using the persisted crop window.
#   2. Build sub16, sub8, sub4 downsamples (jitter pipeline scales up from sub16).
#   3. Run the parameterized KH9_ortho.sh flow at sub16 through stereo_rpc_360.
#
# Outputs per strip (consumed by S2):
#   <output_dir>/<strip_id>/forward.tif, aft.tif                       (full-res crop)
#   <output_dir>/<strip_id>/{forward,aft}_{sub16,sub8,sub4}.tif        (downsamples)
#   <output_dir>/<strip_id>/ba_rpc_gcp_ht/run-run-{forward,aft}_sub16.tsai
#   <output_dir>/<strip_id>/stereo_rpc_360/run-DEM.tif

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${1:-${GKP_CONFIG:-$REPO_ROOT/config/config.yaml}}"
export GKP_CONFIG="$CFG"
PY="${PYTHON:-python3}"
cd "$REPO_ROOT"

RESOLVED="$REPO_ROOT/inputs/manifest.resolved.json"
[[ -f "$RESOLVED" ]] || { echo "[S1] missing $RESOLVED — run S0.sh first" >&2; exit 1; }
DEM="$REPO_ROOT/inputs/dem.tif"
[[ -f "$DEM" ]] || { echo "[S1] missing DEM $DEM — run S0.sh" >&2; exit 1; }

$PY - "$RESOLVED" <<'PYEOF' > "$REPO_ROOT/inputs/_strips.tsv"
import json, sys
data = json.load(open(sys.argv[1]))
utm_zone = data["utm_zone"]
output_dir = data["output_dir"]
threads = data["compute"]["threads_per_job"]
jobs = data["compute"]["match_jobs"]
for s in data["strips"]:
    fwd, aft = s["fwd"], s["aft"]
    c = fwd["crop"]; ac = aft["crop"]
    if any(v is None for v in c.values()) or any(v is None for v in ac.values()):
        raise SystemExit(f"strip {s['strip_id']} missing crop — rerun S0")
    print("\t".join(str(x) for x in [
        s["strip_id"],
        fwd["entity_id"], fwd["mosaic"], fwd["cam_gen_corners_file"],
        aft["entity_id"], aft["mosaic"], aft["cam_gen_corners_file"],
        c["xoff"], c["yoff"], c["xsize"], c["ysize"],
        ac["xoff"], ac["yoff"], ac["xsize"], ac["ysize"],
        utm_zone, output_dir, threads, jobs,
    ]))
PYEOF

# Downsample a single image to sub<N> if missing.
make_subres() {
  local SRC="$1" DST="$2" N="$3"
  if [[ -f "$DST" ]]; then
    echo "[S1]   sub${N} exists: $(basename "$DST")"
    return 0
  fi
  echo "[S1]   image_mosaic --reduce $N $(basename "$SRC") -> $(basename "$DST")"
  image_mosaic "$SRC" --ot Byte --reduce-percent "$(awk -v n=$N 'BEGIN{printf "%.6f", 100.0/n}')" -o "$DST"
}

while IFS=$'\t' read -r STRIP_ID \
    FWD_EID FWD_MOSAIC FWD_CORNERS \
    AFT_EID AFT_MOSAIC AFT_CORNERS \
    FX FY FW FH \
    AX AY AW AH \
    UTM OUT_DIR THREADS JOBS; do

  WORK="$OUT_DIR/$STRIP_ID"
  echo "[S1] === $STRIP_ID  (UTM zone $UTM)  -> $WORK ==="
  mkdir -p "$WORK"
  cd "$WORK"
  mkdir -p ba ba_rpc_gcp_ht stereo_mgm stereo_rpc_360 warp

  FWD_FULL="$WORK/forward.tif"
  AFT_FULL="$WORK/aft.tif"

  # --- 1. Crop full-res from the mosaic ---------------------------------
  if [[ ! -f "$FWD_FULL" ]]; then
    echo "[S1]   gdal_translate fwd  -srcwin $FX $FY $FW $FH"
    gdal_translate -q -srcwin "$FX" "$FY" "$FW" "$FH" "$FWD_MOSAIC" "$FWD_FULL"
  fi
  if [[ ! -f "$AFT_FULL" ]]; then
    echo "[S1]   gdal_translate aft  -srcwin $AX $AY $AW $AH"
    gdal_translate -q -srcwin "$AX" "$AY" "$AW" "$AH" "$AFT_MOSAIC" "$AFT_FULL"
  fi

  # --- 2. Multi-scale downsamples ---------------------------------------
  # S1 ops run at sub16; S2 needs sub8 and sub4 too (its phase 1 reads sub16,
  # phase 2 scales to sub8 then sub4, phase 17 scales sub4 -> sub2 -> full).
  for N in 16 8 4; do
    make_subres "$FWD_FULL" "$WORK/forward_sub${N}.tif" "$N"
    make_subres "$AFT_FULL" "$WORK/aft_sub${N}.tif" "$N"
  done

  FWD="$WORK/forward_sub16.tif"
  AFT="$WORK/aft_sub16.tif"

  TMPL="${KH9_TSAI_TEMPLATE:-$REPO_ROOT/cameras/sample_sub16.tsai}"
  if [[ ! -f "$TMPL" ]]; then
    echo "[S1] ERROR: tsai template not found at $TMPL." >&2
    echo "[S1]        Set KH9_TSAI_TEMPLATE or place sample_sub16.tsai under cameras/." >&2
    exit 1
  fi

  FWD_LL="$(cat "$FWD_CORNERS")"
  AFT_LL="$(cat "$AFT_CORNERS")"

  # --- 3. cam_gen (sub16) -----------------------------------------------
  if [[ ! -f "$WORK/forward_sub16.tsai" ]]; then
    echo "[S1]   cam_gen fwd_sub16"
    cam_gen --sample-file "$TMPL" --camera-type opticalbar \
      --lon-lat-values "$FWD_LL" \
      "$FWD" --reference-dem "$DEM" --refine-camera \
      --gcp-file "$WORK/forward_sub16.gcp" -o "$WORK/forward_sub16.tsai"
  fi
  if [[ ! -f "$WORK/aft_sub16.tsai" ]]; then
    echo "[S1]   cam_gen aft_sub16"
    cam_gen --sample-file "$TMPL" --camera-type opticalbar \
      --lon-lat-values "$AFT_LL" \
      "$AFT" --reference-dem "$DEM" --refine-camera \
      --gcp-file "$WORK/aft_sub16.gcp" -o "$WORK/aft_sub16.tsai"
  fi

  # --- 4. mapproject (initial cameras) ----------------------------------
  if [[ ! -f "$WORK/fwd_sub16.map.tif" ]]; then
    echo "[S1]   mapproject fwd_sub16 (initial)"
    mapproject --tr 12 "$DEM" "$FWD" "$WORK/forward_sub16.tsai" "$WORK/fwd_sub16.map.tif"
  fi
  if [[ ! -f "$WORK/aft_sub16.map.tif" ]]; then
    echo "[S1]   mapproject aft_sub16 (initial)"
    mapproject --tr 12 "$DEM" "$AFT" "$WORK/aft_sub16.tsai" "$WORK/aft_sub16.map.tif"
  fi

  # --- 5. bundle_adjust 1 -----------------------------------------------
  if [[ ! -f "$WORK/ba/run-forward_sub16.tsai" ]]; then
    echo "[S1]   bundle_adjust 1"
    bundle_adjust \
      "$FWD" "$AFT" \
      "$WORK/forward_sub16.tsai" "$WORK/aft_sub16.tsai" \
      --mapprojected-data "$WORK/fwd_sub16.map.tif $WORK/aft_sub16.map.tif" \
      "$WORK/forward_sub16.gcp" "$WORK/aft_sub16.gcp" \
      --inline-adjustments \
      --solve-intrinsics --intrinsics-to-float other_intrinsics --intrinsics-to-share none \
      --heights-from-dem "$DEM" --heights-from-dem-uncertainty 10000 \
      --ip-per-image 100000 --ip-inlier-factor 1000 \
      --remove-outliers-params '75 3 1000 1000' \
      --num-iterations 250 \
      -o "$WORK/ba/run"
  fi

  # --- 6. mapproject (ba cameras) ---------------------------------------
  if [[ ! -f "$WORK/ba/run-forward_sub16.map.tif" ]]; then
    mapproject --tr 12 "$DEM" "$FWD" "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-forward_sub16.map.tif"
  fi
  if [[ ! -f "$WORK/ba/run-aft_sub16.map.tif" ]]; then
    mapproject --tr 12 "$DEM" "$AFT" "$WORK/ba/run-aft_sub16.tsai" "$WORK/ba/run-aft_sub16.map.tif"
  fi

  # --- 7. stereo 1 ------------------------------------------------------
  if [[ ! -f "$WORK/stereo_mgm/run-PC.tif" ]]; then
    echo "[S1]   parallel_stereo 1"
    parallel_stereo \
      "$WORK/ba/run-forward_sub16.map.tif" "$WORK/ba/run-aft_sub16.map.tif" \
      "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-aft_sub16.tsai" \
      --stereo-algorithm asp_mgm --subpixel-mode 9 \
      --alignment-method affineepipolar \
      -t opticalbar --skip-rough-homography \
      --num-matches-from-disparity 100000 \
      --disable-tri-ip-filter --ip-detect-method 1 \
      --processes "$JOBS" --threads-multiprocess "$THREADS" \
      "$WORK/stereo_mgm/run" \
      "$DEM"
  fi
  if [[ ! -f "$WORK/stereo_mgm/run-DEM.tif" ]]; then
    point2dem --utm "$UTM" --tr 30 "$WORK/stereo_mgm/run-PC.tif"
  fi

  # --- 8. hillshades ----------------------------------------------------
  if [[ ! -f "$WORK/stereo_mgm/run-dem_hill.tif" ]]; then
    gdaldem hillshade "$WORK/stereo_mgm/run-DEM.tif" "$WORK/stereo_mgm/run-dem_hill.tif" \
      -of GTiff -b 1 -z 1.0 -s 1.0 -az 315.0 -alt 45.0
  fi
  if [[ ! -f "$WORK/stereo_mgm/ref-dem_hill.tif" ]]; then
    gdaldem hillshade -multidirectional -compute_edges \
      "$DEM" "$WORK/stereo_mgm/ref-dem_hill.tif"
  fi

  # --- 9. warp disparity (correlator mode) ------------------------------
  if [[ ! -f "$WORK/warp/run-F.tif" ]]; then
    echo "[S1]   parallel_stereo --correlator-mode (warp)"
    parallel_stereo \
      --correlator-mode \
      --stereo-algorithm asp_mgm --subpixel-mode 9 \
      --ip-per-tile 10000 \
      --processes "$JOBS" --threads-multiprocess "$THREADS" \
      "$WORK/stereo_mgm/run-dem_hill.tif" \
      "$WORK/stereo_mgm/ref-dem_hill.tif" \
      "$WORK/warp/run"
  fi

  # --- 10. dem2gcp ------------------------------------------------------
  if [[ ! -f "$WORK/warp/out.gcp" ]]; then
    echo "[S1]   dem2gcp"
    dem2gcp \
      --warped-dem "$WORK/stereo_mgm/run-DEM.tif" \
      --ref-dem "$DEM" \
      --warped-to-ref-disparity "$WORK/warp/run-F.tif" \
      --left-image "$WORK/ba/run-forward_sub16.map.tif" \
      --right-image "$WORK/ba/run-aft_sub16.map.tif" \
      --left-camera "$WORK/ba/run-forward_sub16.tsai" \
      --right-camera "$WORK/ba/run-aft_sub16.tsai" \
      --match-file "$WORK/stereo_mgm/run-disp-forward_sub16__aft_sub16.match" \
      --gcp-sigma 1.0 --max-num-gcp 20000 \
      --output-gcp "$WORK/warp/out.gcp"
  fi

  # --- 11. bundle_adjust 2 ----------------------------------------------
  if [[ ! -f "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" ]]; then
    echo "[S1]   bundle_adjust 2"
    bundle_adjust \
      "$WORK/ba/run-forward_sub16.map.tif" "$WORK/ba/run-aft_sub16.map.tif" \
      "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-aft_sub16.tsai" \
      "$WORK/warp/out.gcp" \
      --inline-adjustments \
      --solve-intrinsics --intrinsics-to-float all --intrinsics-to-share none \
      --num-iterations 100 \
      --match-files-prefix "$WORK/stereo_mgm/run-disp-forward_sub16__aft_sub16" \
      --max-pairwise-matches 50000 \
      --remove-outliers-params '75.0 3.0 100 100' \
      --heights-from-dem "$DEM" --heights-from-dem-uncertainty 250 \
      -o "$WORK/ba_rpc_gcp_ht/run"
  fi

  # --- 12. mapproject (refined cameras) ---------------------------------
  if [[ ! -f "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif" ]]; then
    mapproject --tr 12 "$DEM" "$FWD" \
      "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" \
      "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif"
  fi
  if [[ ! -f "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif" ]]; then
    mapproject --tr 12 "$DEM" "$AFT" \
      "$WORK/ba_rpc_gcp_ht/run-run-aft_sub16.tsai" \
      "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif"
  fi

  # --- 13. stereo 2 -----------------------------------------------------
  if [[ ! -f "$WORK/stereo_rpc_360/run-PC.tif" ]]; then
    echo "[S1]   parallel_stereo 2"
    parallel_stereo \
      "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif" "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif" \
      "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" "$WORK/ba_rpc_gcp_ht/run-run-aft_sub16.tsai" \
      --stereo-algorithm asp_mgm --subpixel-mode 9 \
      --alignment-method affineepipolar \
      -t opticalbar --skip-rough-homography \
      --num-matches-from-disparity 100000 \
      --disable-tri-ip-filter --ip-detect-method 1 \
      --processes "$JOBS" --threads-multiprocess "$THREADS" \
      "$WORK/stereo_rpc_360/run" \
      "$DEM"
  fi
  if [[ ! -f "$WORK/stereo_rpc_360/run-DEM.tif" ]]; then
    point2dem --utm "$UTM" --tr 30 "$WORK/stereo_rpc_360/run-PC.tif"
  fi

  cd "$REPO_ROOT"
done < "$REPO_ROOT/inputs/_strips.tsv"

rm -f "$REPO_ROOT/inputs/_strips.tsv"
echo "[S1] done."
