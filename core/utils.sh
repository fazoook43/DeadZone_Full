#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

log() { echo "[$(date +%T)] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

section() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
}

file_size() {
  stat -c%s "$1"
}

human_size() {
  du -h "$1" | awk '{print $1}'
}

_normalize_zip_filename() {
  local name="$1"

  name="${name//$'\r'/}"
  name="${name//$'\n'/}"
  name="${name// /_}"

  [[ -n "$name" ]] || return 1
  [[ "$name" != */* && "$name" != *\\* ]] || die "Final ZIP name must not contain path separators: $name"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Final ZIP name contains unsupported characters: $name"

  case "$name" in
    *.zip) printf '%s\n' "$name" ;;
    *) printf '%s.zip\n' "$name" ;;
  esac
}

resolve_final_zip_name() {
  local custom="${FINAL_ZIP_NAME:-}"
  local preset="${ZIP_PRESET:-DeadZone_Gaming_V1}"
  local chosen=""

  if [[ -n "$custom" ]]; then
    chosen="$custom"
  else
    case "$preset" in
      DeadZone_Gaming_V1|DeadZone_EPiC_V1)
        chosen="$preset"
        ;;
      custom|"")
        chosen="${BUILD_NAME}_${DEVICE_CODENAME}_fastboot"
        ;;
      *)
        chosen="$preset"
        ;;
    esac
  fi

  FINAL_ZIP_NAME="$(_normalize_zip_filename "$chosen")"
  export FINAL_ZIP_NAME
}

final_zip_name() {
  if [[ -z "${FINAL_ZIP_NAME:-}" ]]; then
    resolve_final_zip_name
  fi
  printf '%s\n' "$FINAL_ZIP_NAME"
}

final_zip_path() {
  printf '%s/%s\n' "$OUTPUT_FINAL" "$(final_zip_name)"
}

resolve_rom_region() {
  local requested="${ROM_REGION:-auto}"
  local text="${ROM_URL:-} ${ROM_FILE:-} ${ROM_VERSION:-} ${1:-}"

  case "$requested" in
    China|china|CN|cn)
      ROM_REGION="China"
      ;;
    Global|global|GL|gl)
      ROM_REGION="Global"
      ;;
    India|india|IN|in)
      ROM_REGION="India"
      ;;
    auto|Auto|AUTO|"")
      if printf '%s\n' "$text" | grep -qiE 'CNXM|[^A-Z]CN[^A-Z]|China'; then
        ROM_REGION="China"
      elif printf '%s\n' "$text" | grep -qiE 'INXM|[^A-Z]IN[^A-Z]|India'; then
        ROM_REGION="India"
      elif printf '%s\n' "$text" | grep -qiE 'MIXM|GLXM|Global|GLOBAL'; then
        ROM_REGION="Global"
      else
        ROM_REGION="Global"
        warn "Could not auto-detect ROM region from OTA; defaulting ROM_REGION=Global"
      fi
      ;;
    *)
      die "Unsupported ROM_REGION=$requested. Use auto, China, Global, or India"
      ;;
  esac

  export ROM_REGION
}


prepare_env() {
  log "Preparing workspace"
  rm -rf "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT_FINAL" "$WORKSPACE/rom_info.env" "$WORKSPACE/partitions.tsv"
  mkdir -p "$INPUT" "$EXTRACTED" "$OUTPUT" "$OUTPUT/images" "$LOGS" "$OUTPUT_FINAL"
}

load_device_defaults() {
  local default_conf="$DEVICES/default.conf"
  [[ -f "$default_conf" ]] || die "Missing $default_conf"
  # shellcheck disable=SC1090
  source "$default_conf"
  [[ -n "${DYNAMIC_PARTITIONS:-}" ]] || die "DYNAMIC_PARTITIONS is missing in $default_conf"
  export DYNAMIC_PARTITIONS
}

load_device_profile() {
  local profile="$DEVICES/$DEVICE_CODENAME.conf"
  [[ -f "$profile" ]] || return 1
  log "Using device profile: $profile"
  # shellcheck disable=SC1090
  source "$profile"

  if [[ -z "${DYNAMIC_PARTITIONS:-}" && "$(declare -p SUPER_PARTITIONS 2>/dev/null)" =~ "declare -a" ]]; then
    DYNAMIC_PARTITIONS="${SUPER_PARTITIONS[*]}"
  fi

  [[ -n "${DYNAMIC_PARTITIONS:-}" ]] || die "DYNAMIC_PARTITIONS is missing in $profile"
  [[ -n "${SUPER_METADATA_SLOTS:-}" && -z "${METADATA_SLOTS:-}" ]] && METADATA_SLOTS="$SUPER_METADATA_SLOTS"
  [[ -n "${METADATA_SLOTS:-}" && -z "${SUPER_METADATA_SLOTS:-}" ]] && SUPER_METADATA_SLOTS="$METADATA_SLOTS"
  export DYNAMIC_PARTITIONS SUPER_SIZE DYNAMIC_PARTITION_GROUP_NAME DYNAMIC_PARTITION_GROUP_SIZE
  export DYNAMIC_PARTITION_GROUP_SIZE_A DYNAMIC_PARTITION_GROUP_SIZE_B
  export SUPER_METADATA_SIZE SUPER_METADATA_SLOTS SUPER_NAME PARTITION_SUFFIX
  export SUPER_SLOT_MODE SUPER_OUTPUT_FORMAT SUPER_ACTIVE_SLOT SUPER_GROUP_BASENAME
  export REQUIRED_FASTBOOT_IMAGES OPTIONAL_FASTBOOT_IMAGES VBMETA_IMAGES FASTBOOT_SLOT_MODE VBMETA_PATCH_STRATEGY
}

fetch_rom() {
  local url="$1"
  log "Downloading OTA"
  aria2c -x 16 -s 16 -k 1M --continue=true -d "$INPUT" "$url" || die "Download failed"

  local rom_file
  rom_file="$(find "$INPUT" -maxdepth 1 -type f ! -name '*.aria2' | head -n 1)"
  [[ -f "$rom_file" ]] || die "Downloaded ROM file not found"

  export ROM_FILE="$rom_file"
  log "Downloaded file: $(basename "$ROM_FILE")"
  log "Downloaded file size: $(file_size "$ROM_FILE") bytes ($(human_size "$ROM_FILE"))"
  [[ -r "$ROM_FILE" ]] || die "Downloaded ROM file is not readable: $ROM_FILE"
}

detect_rom_version() {
  local source_text="${1:-}"
  local version=""
  version="$(printf '%s\n' "$source_text" | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' | head -n 1 || true)"
  if [[ -z "$version" && -n "${ROM_FILE:-}" ]]; then
    version="$(basename "$ROM_FILE" | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' | head -n 1 || true)"
  fi
  ROM_VERSION="${version:-unknown}"
  export ROM_VERSION
}
