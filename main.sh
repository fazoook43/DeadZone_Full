#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

export WORKSPACE="${WORKSPACE:-$(pwd)}"
export BIN="$WORKSPACE/bin"
export INPUT="$WORKSPACE/input"
export EXTRACTED="$WORKSPACE/extracted"
export OUTPUT="$WORKSPACE/output"
export OUTPUT_FINAL="$WORKSPACE/output_final"
export LOGS="$OUTPUT/logs"
export DEVICES="$WORKSPACE/devices"
export PATH="$BIN:$PATH"

source "$WORKSPACE/core/utils.sh"
source "$WORKSPACE/core/deadzone_config.sh"
source "$WORKSPACE/core/unpacker.sh"
source "$WORKSPACE/core/fastboot_unpacker.sh"
source "$WORKSPACE/core/partition_layout_detector.sh"
source "$WORKSPACE/core/repacker.sh"
source "$WORKSPACE/core/fs_detect.sh"
source "$WORKSPACE/core/collect_images.sh"
source "$WORKSPACE/core/vbmeta_patch.sh"
source "$WORKSPACE/core/package_fastboot.sh"
source "$WORKSPACE/core/upload_release.sh"
source "$WORKSPACE/core/validate_build.sh"
source "$WORKSPACE/core/patcher.sh"

_err_trap() {
  local rc=$?
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local func="${FUNCNAME[1]:-main}"
  echo "::error file=$src,line=$line::Command failed in $func rc=$rc: $BASH_COMMAND" >&2
  exit "$rc"
}
trap _err_trap ERR

run_step() {
  local name="$1"
  shift
  log "STEP: $name start"
  "$@"
  log "STEP: $name done"
}

cleanup_for_fastboot_package() {
  case "$OUTPUT_TYPE" in
    fastboot_zip|full_release) ;;
    *) return 0 ;;
  esac

  section "Fastboot Package Cleanup"
  log "Disk usage before cleanup"
  df -h || true
  du -sh "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" "$LOGS" 2>/dev/null || true

  if [[ -n "${ROM_FILE:-}" && -f "$ROM_FILE" ]]; then
    rm -f "$ROM_FILE"
    log "Removed downloaded OTA: $ROM_FILE"
  fi
  rm -rf "$INPUT/ota" "$INPUT/payload.bin"

  local part
  for part in $DYNAMIC_PARTITIONS; do
    rm -f \
      "$EXTRACTED/$part.img" \
      "$EXTRACTED/${part}.raw.img" \
      "$EXTRACTED/${part}_a.img" \
      "$EXTRACTED/${part}_a.raw.img" \
      "$EXTRACTED/${part}_b.img" \
      "$EXTRACTED/${part}_b.raw.img"
  done

  find "$OUTPUT" -maxdepth 1 -type f -name 'super.img.zst' -delete 2>/dev/null || true
  [[ -s "$OUTPUT/images/super.img" ]] || die "cleanup removed output/images/super.img"

  log "Disk usage after cleanup"
  df -h || true
  du -sh "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" "$LOGS" 2>/dev/null || true
}

main() {
  local rom_url="${1:-${ROM_URL:-}}"
  export DEVICE_CODENAME="${2:-${DEVICE_CODENAME:-}}"
  export SKIP_PATCHES="${3:-${SKIP_PATCHES:-true}}"
  export OUTPUT_TYPE="${4:-${OUTPUT_TYPE:-super_zst}}"
  export FS_MODE="${5:-${FS_MODE:-erofs}}"
  export VBMETA_MODE="${6:-${VBMETA_MODE:-3}}"
  export PATCH_LEVEL="${7:-${PATCH_LEVEL:-none}}"
  # INPUT_TYPE: ota_zip (default) | fastboot_zip
  # ota_zip      → standard OTA with payload.bin inside
  # fastboot_zip → Fastboot package with images/super.img (no payload.bin)
  export INPUT_TYPE="${INPUT_TYPE:-ota_zip}"
  export BUILD_NAME="${BUILD_NAME:-DeadZone_v1}"
  export ZIP_PRESET="${ZIP_PRESET:-DeadZone_Gaming_V1}"
  export FINAL_ZIP_NAME="${FINAL_ZIP_NAME:-}"
  export ROM_REGION="${ROM_REGION:-auto}"
  resolve_final_zip_name
  export UPLOAD_PIXELDRAIN="${UPLOAD_PIXELDRAIN:-false}"
  export NOTIFY_TELEGRAM="${NOTIFY_TELEGRAM:-false}"
  export CREATE_GITHUB_RELEASE="${CREATE_GITHUB_RELEASE:-false}"
  export VBMETA_PATCH_STRATEGY="${VBMETA_PATCH_STRATEGY:-}"

  [[ -n "$rom_url" ]] || die "Usage: ./main.sh <ROM_URL> <DEVICE_CODENAME> [SKIP_PATCHES] [OUTPUT_TYPE] [FS_MODE] [VBMETA_MODE] [PATCH_LEVEL]"
  [[ -n "$DEVICE_CODENAME" ]] || die "device_codename is required"
  case "$OUTPUT_TYPE" in
    super_zst|fastboot_zip|full_release) ;;
    *) die "Unsupported output_type=$OUTPUT_TYPE" ;;
  esac
  case "$INPUT_TYPE" in
    ota_zip|fastboot_zip) ;;
    *) die "Unsupported INPUT_TYPE=$INPUT_TYPE (use ota_zip or fastboot_zip)" ;;
  esac
  case "$FS_MODE" in preserve|erofs) ;; *) die "Unsupported fs_mode=$FS_MODE" ;; esac
  case "$VBMETA_MODE" in 0|1|2|3) ;; *) die "Unsupported vbmeta_mode=$VBMETA_MODE" ;; esac
  case "$PATCH_LEVEL" in none|safe|full) ;; *) die "Unsupported patch_level=$PATCH_LEVEL" ;; esac
  if [[ -z "$VBMETA_PATCH_STRATEGY" ]]; then
    case "$OUTPUT_TYPE" in
      fastboot_zip|full_release|super_zst) VBMETA_PATCH_STRATEGY=binary ;;
      *) VBMETA_PATCH_STRATEGY=binary ;;
    esac
    export VBMETA_PATCH_STRATEGY
  fi

  section "DeadZone ROM Kitchen"
  log "Device codename : $DEVICE_CODENAME"
  log "Input type      : $INPUT_TYPE"
  log "Build name      : $BUILD_NAME"
  log "Skip patches    : $SKIP_PATCHES"
  log "Output type     : $OUTPUT_TYPE"
  log "fs_mode         : $FS_MODE"
  log "vbmeta_mode     : $VBMETA_MODE"
  log "vbmeta_strategy : $VBMETA_PATCH_STRATEGY"
  log "patch_level     : $PATCH_LEVEL"

  prepare_env
  load_device_defaults
  load_device_profile || die "Missing device profile: devices/$DEVICE_CODENAME.conf"
  fetch_rom "$rom_url"
  export ROM_URL="$rom_url"
  detect_rom_version "$rom_url"
  resolve_rom_region "$rom_url"
  log "ROM region: $ROM_REGION"
  log "Final ZIP name: $(final_zip_name)"

  # ── Extraction phase ──────────────────────────────────────────────────────
  case "$INPUT_TYPE" in
    ota_zip)
      section "Payload Extraction (OTA)"
      extract_payload_all_images
      detect_partition_images
      ;;
    fastboot_zip)
      section "Fastboot ZIP Extraction"
      # 1. Extract all *.img from the fastboot package
      extract_fastboot_zip
      # 2. Read real super.img size and LP metadata (overrides profile if needed)
      read_super_real_size_from_image
      # 3. Smart slot layout detection (A / A/B / VAB)
      detect_slot_layout
      print_slot_layout_summary
      # 4. Build partitions.tsv from extracted images
      detect_partition_images_from_fastboot
      ;;
  esac

  detect_dynamic_filesystems

  if [[ "$SKIP_PATCHES" != "true" && "$PATCH_LEVEL" != "none" ]]; then
    run_step apply_patches apply_patches
    detect_dynamic_filesystems
  fi

  section "Super Build"
  build_super_image
  validate_super_image

  if [[ "$OUTPUT_TYPE" == "fastboot_zip" || "$OUTPUT_TYPE" == "full_release" ]]; then
    cleanup_for_fastboot_package
    section "Fastboot Package"
    run_step collect_fastboot_images collect_fastboot_images
    run_step patch_vbmeta_images patch_vbmeta_images
    run_step package_fastboot_zip package_fastboot_zip
    run_step validate_build validate_build
    if [[ "$CREATE_GITHUB_RELEASE" == "true" || "$UPLOAD_PIXELDRAIN" == "true" || "$NOTIFY_TELEGRAM" == "true" ]]; then
      section "Release Uploads"
      run_step upload_release_artifacts upload_release_artifacts
      run_step validate_build validate_build
    fi
  else
    compress_super_image
    validate_super_zst
  fi

  section "Done"
  if [[ "$OUTPUT_TYPE" == "super_zst" ]]; then
    log "Output path: $OUTPUT/super.img.zst"
  else
    log "Output path: $(final_zip_path)"
  fi
  log "Logs path: $LOGS"
}

main "$@"
