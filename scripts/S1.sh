#!/usr/bin/env bash
# Stage 1 — per-pair camera optimization (forward + aft).
#
# Usage:
#   bash scripts/S1.sh [config/config.yaml]
#
# Phase selection (default: from config.s1_phases):
#   PHASES="7 9 11" bash scripts/S1.sh    # skip crop/subres/cam_gen/mapproject,
#                                         # rerun stereo + ba2 + stereo2
#
# Phases (linear cascade; each strip runs the selected phases before the next):
#    1. crop             : gdal_translate fwd + aft from mosaic (full-res)
#    2. subres           : stereo_gui --create-image-pyramids-only (sub2/4/8/16/32)
#    3. cam_gen          : opticalbar .tsai from sample template + corner lon/lat
#    4. mapproj_init     : mapproject sub16 with initial cam_gen cameras
#    5. ba1              : bundle_adjust round 1 (DEM-anchored, solve intrinsics)
#    6. mapproj_ba1      : mapproject sub16 with ba1 cameras
#    7. stereo1          : parallel_stereo (asp_mgm sub16) + point2dem
#    8. dem2gcp          : hillshade + correlator-mode warp + dem2gcp dense GCPs
#                          (ASP docs §8.29.9 — KH-9 horizontal registration)
#    9. ba2              : bundle_adjust round 2 (dense GCPs + heights from SRTM)
#   10. mapproj_ba2      : mapproject sub16 with ba2 cameras
#   11. stereo2          : parallel_stereo (refined cams) + point2dem --tr 16
#                          → S2 input, also archived to DSM-16m/<strip>_DSM.tif
#   12. archive_cams_obc : scale BA2 sub16 .tsai → sub1 (ASP §8.26.2 / §8.29);
#                          mirror sub16+sub1 to <archive>/cameras/OBC/ and
#                          <cameras_repo_dir>/OBC/ (legacy on-repo backup)
#   13. mapproj_archive_16: mapproject BA2 sub16 → mapproject-16m/<entity>.tif (COG)
#   14. mapproj_archive_1 : mapproject BA2 sub1 (full-res) → mapproject-1m/<entity>.tif
#   15. stereo_sub1     : parallel_stereo on mapproject-1m + sub1 cams,
#                         point2dem --tr 1 → DSM-1m/<strip>_DSM.tif
#
# Outputs per strip (consumed by S2):
#   <working_dir>/output/<strip_id>/forward.tif, aft.tif               (full-res crop)
#   <working_dir>/output/<strip_id>/{forward,aft}_{sub16,sub8,sub4}.tif (downsamples)
#   <working_dir>/output/<strip_id>/ba_rpc_gcp_ht/run-run-{forward,aft}_sub16.tsai
#   <working_dir>/output/<strip_id>/stereo_rpc_360/run-DEM.tif
#
# Permanent archives (Phases 11–15):
#   <archive_dir>/cameras/OBC/<entity_id>_{sub16,sub1}.tsai
#   <cameras_repo_dir>/OBC/<entity_id>_{sub16,sub1}.tsai
#   <archive_dir>/images/mapproject-16m/<entity_id>.tif        (Cloud-Optimized GeoTIFF)
#   <archive_dir>/images/mapproject-1m/<entity_id>.tif
#   <archive_dir>/DSM/DSM-16m/<strip_id>_DSM.tif
#   <archive_dir>/DSM/DSM-1m/<strip_id>_DSM.tif

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${1:-${GKP_CONFIG:-$REPO_ROOT/config/config.yaml}}"
export GKP_CONFIG="$CFG"
PY="${PYTHON:-python3}"
cd "$REPO_ROOT"

# Working dir comes from config (load_config().paths.working_dir).  All per-run
# state lives under here: $WORK_DIR/inputs/ (manifest, DEM, mosaics) and
# $WORK_DIR/output/<strip_id>/ (per-strip BA / stereo work).
WORK_DIR="$($PY -c "from scripts.lib.config import load_config; print(load_config('$CFG').paths.working_dir)")"
INPUTS="$WORK_DIR/inputs"
RESOLVED="$INPUTS/manifest.resolved.json"
[[ -f "$RESOLVED" ]] || { echo "[S1] missing $RESOLVED — run S0.sh first" >&2; exit 1; }
DEM="$INPUTS/dem.tif"
[[ -f "$DEM" ]] || { echo "[S1] missing DEM $DEM — run S0.sh" >&2; exit 1; }
# Blurred copy of DEM, used only as the mapprojection surface (ASP §6.1.7.3,
# §8.30.6). cam_gen / BA / dem2gcp / point2dem continue to use $DEM (sharp).
DEM_BLUR="$INPUTS/dem_blur.tif"
[[ -f "$DEM_BLUR" ]] || { echo "[S1] missing $DEM_BLUR — rerun S0.sh (phase 3b)" >&2; exit 1; }
# UTM-projected sharp DEM, used by Phase 8 as the source for the reference
# hillshade.  gdaldem hillshade defaults assume meter-per-meter horizontal/
# vertical scale; a WGS84-geographic DEM (degrees + meters) makes hillshade
# default to washed-out output.  See S0 phase 7b.
DEM_UTM="$INPUTS/dem_utm.tif"
[[ -f "$DEM_UTM" ]] || { echo "[S1] missing $DEM_UTM — rerun S0.sh (phase 7b)" >&2; exit 1; }

# Helper script paths (absolute — the strip loop cd's into $WORK, so `python -m
# scripts.lib.*` would no longer find the `scripts` package).
SCALE_OBC="$REPO_ROOT/scripts/lib/scale_opticalbar.py"

# Permanent archive trees (Phases 11–15). Created once up front so per-strip
# loops can write directly.
ARCHIVE_DIR="$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_dir"])' "$RESOLVED")"
CAMERAS_REPO_DIR="$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["cameras_repo_dir"])' "$RESOLVED")"
mkdir -p \
  "$ARCHIVE_DIR/cameras/OBC" \
  "$ARCHIVE_DIR/cameras/CSM" \
  "$ARCHIVE_DIR/images/mapproject-16m" \
  "$ARCHIVE_DIR/images/mapproject-1m" \
  "$ARCHIVE_DIR/DSM/DSM-16m" \
  "$ARCHIVE_DIR/DSM/DSM-1m" \
  "$CAMERAS_REPO_DIR/OBC" \
  "$CAMERAS_REPO_DIR/CSM"

# Default phase list from config.s1_phases (env PHASES overrides). Falls back
# to 1..15 if the resolved manifest predates the multi-resolution archives.
DEFAULT_PHASES="$($PY -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(str(p) for p in d.get("s1_phases", list(range(1,16)))))' "$RESOLVED")"
PHASES="${PHASES:-$DEFAULT_PHASES}"
run_phase() { [[ " $PHASES " == *" $1 "* ]]; }

echo "[S1] working dir : $WORK_DIR"
echo "[S1] archive dir : $ARCHIVE_DIR"
echo "[S1] cameras repo: $CAMERAS_REPO_DIR"
echo "[S1] phases      : $PHASES"

$PY - "$RESOLVED" <<'PYEOF' > "$INPUTS/_strips.tsv"
import json, sys
data = json.load(open(sys.argv[1]))
utm_zone = data["utm_zone"]
utm_epsg = data["utm_epsg"]
working_dir = data["working_dir"]
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
        utm_zone, utm_epsg, working_dir, threads, jobs,
    ]))
PYEOF

# Generate all pyramid levels (sub2/4/8/16/32) for a single image if missing.
make_subres() {
  local SRC="$1"
  local SUB16="${SRC%.tif}_sub16.tif"
  if [[ -f "$SUB16" ]]; then
    echo "[S1]   pyramids exist: $(basename "$SRC")"
    return 0
  fi
  echo "[S1]   stereo_gui --create-image-pyramids-only $(basename "$SRC")"
  stereo_gui --create-image-pyramids-only "$SRC"
}

while IFS=$'\t' read -r STRIP_ID \
    FWD_EID FWD_MOSAIC FWD_CORNERS \
    AFT_EID AFT_MOSAIC AFT_CORNERS \
    FX FY FW FH \
    AX AY AW AH \
    UTM UTM_EPSG WORKING_DIR THREADS JOBS; do

  WORK="$WORKING_DIR/output/$STRIP_ID"
  echo "[S1] === $STRIP_ID  (UTM zone $UTM)  -> $WORK ==="
  mkdir -p "$WORK"
  cd "$WORK"
  mkdir -p ba ba_rpc_gcp_ht stereo_mgm stereo_rpc_360

  FWD_FULL="$WORK/forward.tif"
  AFT_FULL="$WORK/aft.tif"
  FWD="$WORK/forward_sub16.tif"
  AFT="$WORK/aft_sub16.tif"
  # Templates come from inputs/cameras/ (per-run, S0 phase 7a injects the
  # dynamic mean_surface_elevation).  Falls back to cameras/sample/ if S0 hasn't
  # produced them yet.  Override either via KH9_FWD_TSAI_TEMPLATE / KH9_AFT_TSAI_TEMPLATE.
  FWD_TMPL="${KH9_FWD_TSAI_TEMPLATE:-$INPUTS/cameras/forward_sub16.tsai}"
  AFT_TMPL="${KH9_AFT_TSAI_TEMPLATE:-$INPUTS/cameras/aft_sub16.tsai}"
  [[ -f "$FWD_TMPL" ]] || FWD_TMPL="$REPO_ROOT/cameras/sample/forward_sub16.tsai"
  [[ -f "$AFT_TMPL" ]] || AFT_TMPL="$REPO_ROOT/cameras/sample/aft_sub16.tsai"
  DEM2GCP_OUT="$WORK/ba_rpc_gcp_ht/dem2gcp.gcp"
  WARP_DIR="$WORK/stereo_mgm/warp"
  STEREO_MATCH="$WORK/stereo_mgm/run-disp-forward_sub16__aft_sub16.match"

  # --- Phase 1: crop full-res from the mosaic ---------------------------
  if run_phase 1; then
    if [[ ! -f "$FWD_FULL" ]]; then
      echo "[S1]   gdal_translate fwd  -srcwin $FX $FY $FW $FH"
      gdal_translate -q -srcwin "$FX" "$FY" "$FW" "$FH" "$FWD_MOSAIC" "$FWD_FULL"
    fi
    if [[ ! -f "$AFT_FULL" ]]; then
      echo "[S1]   gdal_translate aft  -srcwin $AX $AY $AW $AH"
      gdal_translate -q -srcwin "$AX" "$AY" "$AW" "$AH" "$AFT_MOSAIC" "$AFT_FULL"
    fi
  fi

  # --- Phase 2: multi-scale downsamples ---------------------------------
  # stereo_gui generates sub2/4/8/16/32 in one pass alongside the source file.
  # S1 runs at sub16; S2 phases 2/17 need sub8, sub4, sub2.
  if run_phase 2; then
    make_subres "$FWD_FULL"
    make_subres "$AFT_FULL"
  fi

  # --- Phase 3: cam_gen (sub16) -----------------------------------------
  if run_phase 3; then
    for _tmpl in "$FWD_TMPL" "$AFT_TMPL"; do
      if [[ ! -f "$_tmpl" ]]; then
        echo "[S1] ERROR: tsai template not found: $_tmpl" >&2
        echo "[S1]        Place forward_sub16.tsai / aft_sub16.tsai under cameras/sample/," >&2
        echo "[S1]        or override via KH9_FWD_TSAI_TEMPLATE / KH9_AFT_TSAI_TEMPLATE." >&2
        exit 1
      fi
    done

    FWD_LL="$(cat "$FWD_CORNERS")"
    AFT_LL="$(cat "$AFT_CORNERS")"

    if [[ ! -f "$WORK/forward_sub16.tsai" ]]; then
      echo "[S1]   cam_gen fwd_sub16"
      cam_gen --sample-file "$FWD_TMPL" --camera-type opticalbar \
        --lon-lat-values "$FWD_LL" \
        "$FWD" --reference-dem "$DEM" --refine-camera \
        --gcp-file "$WORK/forward_sub16.gcp" -o "$WORK/forward_sub16.tsai"
    fi
    if [[ ! -f "$WORK/aft_sub16.tsai" ]]; then
      echo "[S1]   cam_gen aft_sub16"
      cam_gen --sample-file "$AFT_TMPL" --camera-type opticalbar \
        --lon-lat-values "$AFT_LL" \
        "$AFT" --reference-dem "$DEM" --refine-camera \
        --gcp-file "$WORK/aft_sub16.gcp" -o "$WORK/aft_sub16.tsai"
    fi
  fi

  # --- Phase 4: mapproject (initial cameras) ----------------------------
  # Uses blurred DEM (§6.1.7.3) + local UTM target SRS (§6.1.7) per ASP docs.
  if run_phase 4; then
    if [[ ! -f "$WORK/fwd_sub16.map.tif" ]]; then
      echo "[S1]   mapproject fwd_sub16 (initial)"
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$FWD" "$WORK/forward_sub16.tsai" "$WORK/fwd_sub16.map.tif"
    fi
    if [[ ! -f "$WORK/aft_sub16.map.tif" ]]; then
      echo "[S1]   mapproject aft_sub16 (initial)"
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$AFT" "$WORK/aft_sub16.tsai" "$WORK/aft_sub16.map.tif"
    fi
  fi

  # --- Phase 5: bundle_adjust 1 -----------------------------------------
  if run_phase 5; then
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
  fi

  # --- Phase 6: mapproject (ba cameras) ---------------------------------
  if run_phase 6; then
    if [[ ! -f "$WORK/ba/run-forward_sub16.map.tif" ]]; then
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$FWD" "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-forward_sub16.map.tif"
    fi
    if [[ ! -f "$WORK/ba/run-aft_sub16.map.tif" ]]; then
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$AFT" "$WORK/ba/run-aft_sub16.tsai" "$WORK/ba/run-aft_sub16.map.tif"
    fi
  fi

  # --- Phase 7: stereo 1 ------------------------------------------------
  # Trailing DEM arg MUST match what Phase 6 mapprojected against (geoheader
  # check in stereo_parse). Both = $DEM_BLUR here.
  if run_phase 7; then
    if [[ ! -f "$WORK/stereo_mgm/run-PC.tif" ]]; then
      echo "[S1]   parallel_stereo 1"
      parallel_stereo \
        "$WORK/ba/run-forward_sub16.map.tif" "$WORK/ba/run-aft_sub16.map.tif" \
        "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-aft_sub16.tsai" \
        --stereo-algorithm asp_mgm --subpixel-mode 9 \
        --alignment-method none \
        -t opticalbar --skip-rough-homography \
        --num-matches-from-disparity 100000 \
        --disable-tri-ip-filter --ip-detect-method 1 \
        --ip-per-tile 10000 \
        --processes "$JOBS" --threads-multiprocess "$THREADS" \
        "$WORK/stereo_mgm/run" \
        "$DEM_BLUR"
    fi
    if [[ ! -f "$WORK/stereo_mgm/run-DEM.tif" ]]; then
      point2dem --utm "$UTM" --tr 30 "$WORK/stereo_mgm/run-PC.tif"
    fi
  fi

  # --- Phase 8: hillshade matching + dem2gcp (ASP docs §8.29.9) ---------
  # Official KH-9 horizontal-registration correction:
  #   1. gdaldem hillshade on stereo DEM and reference DEM (docs prefer GDAL's
  #      hillshade over ASP's own).
  #   2. parallel_stereo --correlator-mode on the two hillshades to produce a
  #      warp disparity (warp/run-F.tif) describing how the stereo DEM differs
  #      from the reference DEM.
  #   3. dem2gcp turns the disparity into dense GCPs that BA2 consumes to
  #      correct horizontal misregistration while floating intrinsics.
  if run_phase 8; then
    mkdir -p "$WORK/ba_rpc_gcp_ht"
    # ASYMMETRIC hillshade (matches user's working Pamir D3C1216-300814-009 recipe):
    #   stereo: single-azimuth 315/45 — directional shadows for IP detection
    #   ref:    multidirectional + compute_edges on UTM DEM — softer, less
    #           orientation-biased shading. Ref uses $DEM_UTM (S0 phase 7b)
    #           so default -s 1 -z 1 are correct (meters/meters); hillshading
    #           the WGS84-geographic dem.tif with the same defaults produces
    #           washed-out output.
    if [[ ! -f "$WORK/stereo_mgm/run-dem_hill.tif" ]]; then
      gdaldem hillshade "$WORK/stereo_mgm/run-DEM.tif" "$WORK/stereo_mgm/run-dem_hill.tif" \
        -of GTiff -b 1 -z 1.0 -s 1.0 -az 315.0 -alt 45.0
    fi
    if [[ ! -f "$WORK/stereo_mgm/ref-dem_hill.tif" ]]; then
      gdaldem hillshade -multidirectional -compute_edges \
        "$DEM_UTM" "$WORK/stereo_mgm/ref-dem_hill.tif"
    fi
    if [[ ! -f "$WARP_DIR/run-F.tif" ]]; then
      echo "[S1]   parallel_stereo --correlator-mode (warp hillshades)"
      mkdir -p "$WARP_DIR"
      # MANY candidates, STRICT filter defaults (matches the Pamir D3C1216-
      # 300814-009 recipe). --ip-per-tile 100000 (200x docs default) gives the
      # matcher enough material that the default homography/uniqueness filters
      # still leave a usable inlier population. Looser filters with fewer
      # candidates produced noise: a previous attempt with --ip-per-tile 4000 +
      # --skip-rough-homography ran D_sub for 157 s on a 7000-px-wide search
      # window then collapsed to 1x1 full-res with "No tiles were generated."
      parallel_stereo \
        --correlator-mode \
        --stereo-algorithm asp_mgm --subpixel-mode 9 \
        --ip-per-tile 100000 \
        --processes "$JOBS" --threads-multiprocess "$THREADS" \
        "$WORK/stereo_mgm/run-dem_hill.tif" "$WORK/stereo_mgm/ref-dem_hill.tif" \
        "$WARP_DIR/run"
    fi
    if [[ ! -f "$DEM2GCP_OUT" ]]; then
      echo "[S1]   dem2gcp"
      # --warped-dem is the stereo DEM (UTM, from point2dem --utm) and --ref-dem
      # must share that projection. $DEM_UTM is the same SRTM reprojected to local
      # UTM at 30 m/px (S0 phase 7b). Heights are unchanged (gdalwarp bilinear
      # preserves them), so this is still a valid geographic anchor for the GCPs
      # dem2gcp emits.
      dem2gcp \
        --warped-dem "$WORK/stereo_mgm/run-DEM.tif" \
        --ref-dem "$DEM_UTM" \
        --warped-to-ref-disparity "$WARP_DIR/run-F.tif" \
        --left-image  "$FWD"  --right-image "$AFT" \
        --left-camera "$WORK/ba/run-forward_sub16.tsai" \
        --right-camera "$WORK/ba/run-aft_sub16.tsai" \
        --match-file "$STEREO_MATCH" \
        --max-num-gcp 20000 \
        --gcp-sigma 1.0 \
        --output-gcp "$DEM2GCP_OUT"
    fi
  fi

  # --- Phase 9: bundle_adjust 2 with dem2gcp GCPs (ASP docs §8.29.9) ----
  # Dense dem2gcp GCPs provide the horizontal anchor; --heights-from-dem points
  # at the original SRTM reference (the geographic anchor now comes from the
  # GCPs, not from a transformed DEM). --intrinsics-to-float other_intrinsics
  # per the docs (focal length stays fixed; optical centers + distortion float).
  if run_phase 9; then
    if [[ ! -f "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" ]]; then
      echo "[S1]   bundle_adjust 2"
      bundle_adjust \
        "$FWD" "$AFT" \
        "$WORK/ba/run-forward_sub16.tsai" "$WORK/ba/run-aft_sub16.tsai" \
        "$DEM2GCP_OUT" \
        --inline-adjustments \
        --solve-intrinsics --intrinsics-to-float other_intrinsics --intrinsics-to-share none \
        --num-iterations 100 \
        --match-files-prefix "$WORK/stereo_mgm/run-disp-forward_sub16__aft_sub16" \
        --max-pairwise-matches 50000 \
        --remove-outliers-params '75.0 3.0 100 100' \
        --heights-from-dem "$DEM" --heights-from-dem-uncertainty 50 \
        -o "$WORK/ba_rpc_gcp_ht/run"
    fi
  fi

  # --- Phase 10: mapproject (refined cameras) ---------------------------
  if run_phase 10; then
    if [[ ! -f "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif" ]]; then
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$FWD" \
        "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" \
        "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif"
    fi
    if [[ ! -f "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif" ]]; then
      mapproject --tr 12 --t_srs "EPSG:$UTM_EPSG" "$DEM_BLUR" "$AFT" \
        "$WORK/ba_rpc_gcp_ht/run-run-aft_sub16.tsai" \
        "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif"
    fi
  fi

  # --- Phase 11: stereo 2 -----------------------------------------------
  # Trailing DEM arg must match Phase 10's mapproject DEM ($DEM_BLUR).
  # point2dem --tr 16 honors the DSM-16m archive name; the resulting DEM is
  # also copied to <archive_dir>/DSM/DSM-16m/<strip_id>_DSM.tif.
  if run_phase 11; then
    if [[ ! -f "$WORK/stereo_rpc_360/run-PC.tif" ]]; then
      echo "[S1]   parallel_stereo 2"
      parallel_stereo \
        "$WORK/ba_rpc_gcp_ht/fwd_sub16.map.tif" "$WORK/ba_rpc_gcp_ht/aft_sub16.map.tif" \
        "$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai" "$WORK/ba_rpc_gcp_ht/run-run-aft_sub16.tsai" \
        --stereo-algorithm asp_mgm --subpixel-mode 9 \
        --alignment-method none \
        -t opticalbar --skip-rough-homography \
        --num-matches-from-disparity 100000 \
        --disable-tri-ip-filter --ip-detect-method 1 \
        --processes "$JOBS" --threads-multiprocess "$THREADS" \
        "$WORK/stereo_rpc_360/run" \
        "$DEM_BLUR"
    fi
    if [[ ! -f "$WORK/stereo_rpc_360/run-DEM.tif" ]]; then
      point2dem --utm "$UTM" --tr 16 "$WORK/stereo_rpc_360/run-PC.tif"
    fi
    DSM16_ARCHIVE="$ARCHIVE_DIR/DSM/DSM-16m/${STRIP_ID}_DSM.tif"
    if [[ ! -f "$DSM16_ARCHIVE" && -f "$WORK/stereo_rpc_360/run-DEM.tif" ]]; then
      echo "[S1]   archive DSM-16m → $DSM16_ARCHIVE"
      gdal_translate -q -of GTiff -co TILED=YES -co COMPRESS=LZW \
        "$WORK/stereo_rpc_360/run-DEM.tif" "$DSM16_ARCHIVE"
    fi
  fi

  # --- Phase 12: archive OBC cameras at sub16 + sub1 -------------------
  # Scale the BA2 refined sub16 .tsai algebraically to sub1 per ASP §8.26.2:
  # image_size and image_center *= 16; pitch /= 16.  --reference-image patches
  # image_size to the actual full-res tif dimensions (absorbs the few-pixel
  # rounding that can show up between sub16 and full-res).  Mirror sub16+sub1
  # to BOTH archives so the F: tree is the canonical home and the C: repo
  # keeps a legacy backup.
  if run_phase 12; then
    BA2_FWD_SUB16="$WORK/ba_rpc_gcp_ht/run-run-forward_sub16.tsai"
    BA2_AFT_SUB16="$WORK/ba_rpc_gcp_ht/run-run-aft_sub16.tsai"
    [[ -f "$BA2_FWD_SUB16" && -f "$BA2_AFT_SUB16" ]] || {
      echo "[S1]   WARNING: BA2 cams missing — run Phase 9 first" >&2
    }

    BA2_FWD_SUB1="$WORK/ba_rpc_gcp_ht/run-run-forward_sub1.tsai"
    BA2_AFT_SUB1="$WORK/ba_rpc_gcp_ht/run-run-aft_sub1.tsai"

    img_size() {
      gdalinfo -json "$1" \
        | $PY -c 'import sys,json; d=json.load(sys.stdin); print(d["size"][0], d["size"][1])'
    }

    if [[ -f "$BA2_FWD_SUB16" && ! -f "$BA2_FWD_SUB1" ]]; then
      echo "[S1]   scale fwd sub16 → sub1"
      read -r FWD_FULL_W FWD_FULL_H <<< "$(img_size "$FWD_FULL")"
      $PY "$SCALE_OBC" "$BA2_FWD_SUB16" "$BA2_FWD_SUB1" \
        --scale 16 --image-size "$FWD_FULL_W" "$FWD_FULL_H"
    fi
    if [[ -f "$BA2_AFT_SUB16" && ! -f "$BA2_AFT_SUB1" ]]; then
      echo "[S1]   scale aft sub16 → sub1"
      read -r AFT_FULL_W AFT_FULL_H <<< "$(img_size "$AFT_FULL")"
      $PY "$SCALE_OBC" "$BA2_AFT_SUB16" "$BA2_AFT_SUB1" \
        --scale 16 --image-size "$AFT_FULL_W" "$AFT_FULL_H"
    fi

    for DEST in "$ARCHIVE_DIR/cameras/OBC" "$CAMERAS_REPO_DIR/OBC"; do
      [[ -f "$BA2_FWD_SUB16" ]] && cp -f "$BA2_FWD_SUB16" "$DEST/${FWD_EID}_sub16.tsai"
      [[ -f "$BA2_AFT_SUB16" ]] && cp -f "$BA2_AFT_SUB16" "$DEST/${AFT_EID}_sub16.tsai"
      [[ -f "$BA2_FWD_SUB1"  ]] && cp -f "$BA2_FWD_SUB1"  "$DEST/${FWD_EID}_sub1.tsai"
      [[ -f "$BA2_AFT_SUB1"  ]] && cp -f "$BA2_AFT_SUB1"  "$DEST/${AFT_EID}_sub1.tsai"
    done
    echo "[S1]   archived OBC cams: ${FWD_EID}, ${AFT_EID} (sub16 + sub1)"
  fi

  # --- Phase 13: mapproject sub16 → archive (Cloud-Optimized GeoTIFF) ---
  # 16 m/px ortho preview using the BA2 sub16 cameras, mapprojected against
  # the blurred DEM (same surface that fed Phases 10/11).  mapproject can't
  # emit COG directly, so it writes a temporary tiled GeoTIFF and gdal_translate
  # -of COG converts in place.
  if run_phase 13; then
    for CAM_TAG in "fwd:$FWD:forward:$FWD_EID" "aft:$AFT:aft:$AFT_EID"; do
      IFS=: read -r TAG IMG CAMSTEM EID <<< "$CAM_TAG"
      OUT="$ARCHIVE_DIR/images/mapproject-16m/${EID}.tif"
      [[ -f "$OUT" ]] && continue
      TMP="$WORK/${TAG}_sub16.archive.tmp.tif"
      echo "[S1]   mapproject-16m $EID"
      mapproject --tr 16 --t_srs "EPSG:$UTM_EPSG" \
        --tif-compress LZW \
        "$DEM_BLUR" "$IMG" \
        "$WORK/ba_rpc_gcp_ht/run-run-${CAMSTEM}_sub16.tsai" \
        "$TMP"
      gdal_translate -q -of COG -co COMPRESS=DEFLATE -co PREDICTOR=YES "$TMP" "$OUT"
      rm -f "$TMP"
    done
  fi

  # --- Phase 14: mapproject sub1 (full-resolution) → archive ------------
  # 1 m/px ortho using the scaled sub1 OBC cameras and the full-res raw tif
  # ($WORK/forward.tif from Phase 1).  Output is a regular tiled GeoTIFF
  # (the "heavy" analysis version; the sub16 COG above is for display).
  # Also serves as input to Phase 15 stereo.
  if run_phase 14; then
    for CAM_TAG in "fwd:$FWD_FULL:forward:$FWD_EID" "aft:$AFT_FULL:aft:$AFT_EID"; do
      IFS=: read -r TAG IMG CAMSTEM EID <<< "$CAM_TAG"
      OUT="$ARCHIVE_DIR/images/mapproject-1m/${EID}.tif"
      [[ -f "$OUT" ]] && continue
      SUB1_TSAI="$WORK/ba_rpc_gcp_ht/run-run-${CAMSTEM}_sub1.tsai"
      if [[ ! -f "$SUB1_TSAI" ]]; then
        echo "[S1]   WARNING: $SUB1_TSAI missing — run Phase 12 first" >&2
        continue
      fi
      echo "[S1]   mapproject-1m  $EID  (heavy, full-res)"
      mapproject --tr 1 --t_srs "EPSG:$UTM_EPSG" \
        --tif-compress LZW --tile-size 1024 \
        "$DEM_BLUR" "$IMG" "$SUB1_TSAI" "$OUT"
    done
  fi

  # --- Phase 15: full-resolution stereo (DSM-1m) ------------------------
  # Re-run the Phase 11 stereo recipe against the Phase 14 mapprojections
  # and sub1 cameras.  Trailing DEM arg = $DEM_BLUR (matches Phase 14 mapproj).
  # Expensive: ~21k × 21k mapprojected pairs per strip, tens of GB of work.
  if run_phase 15; then
    STEREO_SUB1_DIR="$WORK/stereo_sub1_full"
    SUB1_FWD_MAP="$ARCHIVE_DIR/images/mapproject-1m/${FWD_EID}.tif"
    SUB1_AFT_MAP="$ARCHIVE_DIR/images/mapproject-1m/${AFT_EID}.tif"
    SUB1_FWD_TSAI="$WORK/ba_rpc_gcp_ht/run-run-forward_sub1.tsai"
    SUB1_AFT_TSAI="$WORK/ba_rpc_gcp_ht/run-run-aft_sub1.tsai"
    if [[ ! -f "$SUB1_FWD_MAP" || ! -f "$SUB1_AFT_MAP" || ! -f "$SUB1_FWD_TSAI" || ! -f "$SUB1_AFT_TSAI" ]]; then
      echo "[S1]   WARNING: missing sub1 inputs for stereo — run Phases 12+14 first" >&2
    else
      mkdir -p "$STEREO_SUB1_DIR"
      if [[ ! -f "$STEREO_SUB1_DIR/run-PC.tif" ]]; then
        echo "[S1]   parallel_stereo sub1 (full-res) — long-running"
        parallel_stereo \
          "$SUB1_FWD_MAP" "$SUB1_AFT_MAP" \
          "$SUB1_FWD_TSAI" "$SUB1_AFT_TSAI" \
          --stereo-algorithm asp_mgm --subpixel-mode 9 \
          --alignment-method none \
          -t opticalbar --skip-rough-homography \
          --num-matches-from-disparity 100000 \
          --disable-tri-ip-filter --ip-detect-method 1 \
          --processes "$JOBS" --threads-multiprocess "$THREADS" \
          "$STEREO_SUB1_DIR/run" \
          "$DEM_BLUR"
      fi
      if [[ ! -f "$STEREO_SUB1_DIR/run-DEM.tif" ]]; then
        point2dem --utm "$UTM" --tr 1 "$STEREO_SUB1_DIR/run-PC.tif"
      fi
      DSM1_ARCHIVE="$ARCHIVE_DIR/DSM/DSM-1m/${STRIP_ID}_DSM.tif"
      if [[ ! -f "$DSM1_ARCHIVE" && -f "$STEREO_SUB1_DIR/run-DEM.tif" ]]; then
        echo "[S1]   archive DSM-1m → $DSM1_ARCHIVE"
        gdal_translate -q -of GTiff -co TILED=YES -co COMPRESS=LZW \
          "$STEREO_SUB1_DIR/run-DEM.tif" "$DSM1_ARCHIVE"
      fi
    fi
  fi

  cd "$REPO_ROOT"
done < "$INPUTS/_strips.tsv"

rm -f "$INPUTS/_strips.tsv"
echo "[S1] done."
