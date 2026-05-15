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
source "$WORKSPACE/core/device_probe.sh"
source "$WORKSPACE/core/slot_detect.sh"
source "$WORKSPACE/core/unpacker.sh"
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
  local name="$1"; shift
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
  df -h || true
  du -sh "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" "$LOGS" 2>/dev/null || true

  [[ -n "${ROM_FILE:-}" && -f "$ROM_FILE" ]] && rm -f "$ROM_FILE"
  rm -rf "$INPUT/ota" "$INPUT/payload.bin"

  local part
  for part in $DYNAMIC_PARTITIONS; do
    rm -f \
      "$EXTRACTED/$part.img"         "$EXTRACTED/${part}.raw.img" \
      "$EXTRACTED/${part}_a.img"     "$EXTRACTED/${part}_a.raw.img" \
      "$EXTRACTED/${part}_b.img"     "$EXTRACTED/${part}_b.raw.img"
  done

  find "$OUTPUT" -maxdepth 1 -type f -name 'super.img.zst' -delete 2>/dev/null || true
  [[ -s "$OUTPUT/images/super.img" ]] || die "cleanup removed output/images/super.img"

  df -h || true
  du -sh "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" "$LOGS" 2>/dev/null || true
}

main() {
  local rom_url="${1:-${ROM_URL:-}}"

  # ── DEVICE_CODENAME ────────────────────────────────────────────────────────
  # If the user passes "auto" or leaves it empty we probe the OTA itself.
  # Any other value is treated as a hint that may be overridden by the probe.
  local raw_codename="${2:-${DEVICE_CODENAME:-auto}}"
  if [[ "$raw_codename" == "auto" || -z "$raw_codename" ]]; then
    export DEVICE_CODENAME=""          # probe will fill this
    export DEVICE_PROBE_AUTO="true"
  else
    export DEVICE_CODENAME="${raw_codename,,}"   # lowercase
    export DEVICE_PROBE_AUTO="${DEVICE_PROBE_AUTO:-true}"
  fi
  # ──────────────────────────────────────────────────────────────────────────

  export SKIP_PATCHES="${3:-${SKIP_PATCHES:-true}}"
  export OUTPUT_TYPE="${4:-${OUTPUT_TYPE:-super_zst}}"
  export FS_MODE="${5:-${FS_MODE:-erofs}}"
  export VBMETA_MODE="${6:-${VBMETA_MODE:-3}}"
  export PATCH_LEVEL="${7:-${PATCH_LEVEL:-none}}"
  export BUILD_NAME="${BUILD_NAME:-DeadZone_v1}"
  export ZIP_PRESET="${ZIP_PRESET:-DeadZone_Gaming_V1}"
  export FINAL_ZIP_NAME="${FINAL_ZIP_NAME:-}"
  export ROM_REGION="${ROM_REGION:-auto}"
  export UPLOAD_PIXELDRAIN="${UPLOAD_PIXELDRAIN:-false}"
  export NOTIFY_TELEGRAM="${NOTIFY_TELEGRAM:-false}"
  export CREATE_GITHUB_RELEASE="${CREATE_GITHUB_RELEASE:-false}"
  export VBMETA_PATCH_STRATEGY="${VBMETA_PATCH_STRATEGY:-binary}"

  [[ -n "$rom_url" ]] || die \
    "Usage: ./main.sh <ROM_URL> [DEVICE_CODENAME|auto] [SKIP_PATCHES] [OUTPUT_TYPE] [FS_MODE] [VBMETA_MODE] [PATCH_LEVEL]"

  case "$OUTPUT_TYPE" in
    super_zst|fastboot_zip|full_release) ;;
    *) die "Unsupported output_type=$OUTPUT_TYPE" ;;
  esac
  case "$FS_MODE"     in preserve|erofs)   ;; *) die "Unsupported fs_mode=$FS_MODE"     ;; esac
  case "$VBMETA_MODE" in 0|1|2|3)         ;; *) die "Unsupported vbmeta_mode=$VBMETA_MODE" ;; esac
  case "$PATCH_LEVEL" in none|safe|full)   ;; *) die "Unsupported patch_level=$PATCH_LEVEL"  ;; esac

  # ── Setup ──────────────────────────────────────────────────────────────────
  section "DeadZone ROM Kitchen"
  log "ROM URL           : $rom_url"
  log "Skip patches      : $SKIP_PATCHES"
  log "Output type       : $OUTPUT_TYPE"
  log "fs_mode           : $FS_MODE"
  log "vbmeta_mode       : $VBMETA_MODE"
  log "vbmeta_strategy   : $VBMETA_PATCH_STRATEGY"
  log "patch_level       : $PATCH_LEVEL"
  log "Device probe auto : $DEVICE_PROBE_AUTO"

  prepare_env
  load_device_defaults

  # ── Download ROM ───────────────────────────────────────────────────────────
  fetch_rom "$rom_url"
  export ROM_URL="$rom_url"
  detect_rom_version "$rom_url"
  resolve_rom_region "$rom_url"

  # ── Phase 0: Device Auto-Probe (fast strategies before extraction) ─────────
  section "Device Auto-Probe"
  probe_device_info

  # Now we have DEVICE_CODENAME — update zip name
  resolve_final_zip_name

  log "Device codename   : $DEVICE_CODENAME"
  log "Build name        : $BUILD_NAME"
  log "ROM region        : $ROM_REGION"
  log "ROM version       : ${ROM_VERSION:-unknown}"
  log "Final ZIP name    : $(final_zip_name)"

  # ── Phase 1: Load or auto-generate device profile ─────────────────────────
  section "Device Profile"
  if ! load_device_profile; then
    log "No existing profile for '$DEVICE_CODENAME' — will try auto-generate after extraction"
  fi

  # ── Phase 2: Extract payload ───────────────────────────────────────────────
  section "Payload Extraction"
  extract_payload_all_images
  detect_dynamic_filesystems

  # ── Phase 3: Deep probe — build.prop + super metadata from extracted files ─
  section "Deep Device Probe"
  _probe_from_build_prop  || true    # now system/ is available
  probe_super_metadata               # reads lpdump from extracted super.img

  # Generate conf now if we still don't have one
  if ! load_device_profile 2>/dev/null; then
    generate_device_conf || die "Could not create device profile for '$DEVICE_CODENAME'"
    load_device_profile  || die "Missing device profile: devices/$DEVICE_CODENAME.conf"
  fi

  log "═══ Device Profile Loaded ═══"
  log "Codename    : $DEVICE_CODENAME"
  log "Brand       : ${DEVICE_BRAND:-unknown}"
  log "Model       : ${DEVICE_MODEL:-unknown}"
  log "SoC         : ${DEVICE_SOC:-unknown}"
  log "SUPER_SIZE  : ${SUPER_SIZE:-unknown}"
  log "Group size  : ${DYNAMIC_PARTITION_GROUP_SIZE:-unknown}"

  # ── Phase 4: Slot mode detection ──────────────────────────────────────────
  section "Slot Mode Detection"
  detect_slot_mode
  log "Slot mode: $SUPER_SLOT_MODE — $(describe_slot_mode)"

  detect_partition_images

  # ── Phase 5: Patches ──────────────────────────────────────────────────────
  if [[ "$SKIP_PATCHES" != "true" && "$PATCH_LEVEL" != "none" ]]; then
    run_step apply_patches apply_patches
    detect_dynamic_filesystems
  fi

  # ── Phase 6: Super build ───────────────────────────────────────────────────
  section "Super Build"
  build_super_image
  validate_super_image

  # ── Phase 7: Output ───────────────────────────────────────────────────────
  if [[ "$OUTPUT_TYPE" == "fastboot_zip" || "$OUTPUT_TYPE" == "full_release" ]]; then
    cleanup_for_fastboot_package
    section "Fastboot Package"
    run_step collect_fastboot_images  collect_fastboot_images
    run_step patch_vbmeta_images      patch_vbmeta_images
    run_step package_fastboot_zip     package_fastboot_zip
    run_step validate_build           validate_build
    if [[ "$CREATE_GITHUB_RELEASE" == "true" || \
          "$UPLOAD_PIXELDRAIN"    == "true"  || \
          "$NOTIFY_TELEGRAM"      == "true"  ]]; then
      section "Release Uploads"
      run_step upload_release_artifacts upload_release_artifacts
      run_step validate_build           validate_build
    fi
  else
    compress_super_image
    validate_super_zst
  fi

  section "Done"
  [[ "$OUTPUT_TYPE" == "super_zst" ]] \
    && log "Output : $OUTPUT/super.img.zst" \
    || log "Output : $(final_zip_path)"
  log "Logs   : $LOGS"
}

main "$@"
