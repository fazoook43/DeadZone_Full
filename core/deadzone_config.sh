#!/usr/bin/env bash
set -euo pipefail

_normalize_zip_filename() {
  local name="$1"

  name="${name//$'\r'/}"
  name="${name//$'\n'/}"
  name="${name// /_}"

  [[ -n "$name" ]] || die "Final ZIP name is empty"
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
      if printf '%s\n' "$text" | grep -qiE 'CNXM|China|_cn|/cn'; then
        ROM_REGION="China"
      elif printf '%s\n' "$text" | grep -qiE 'INXM|India|_in|/in'; then
        ROM_REGION="India"
      elif printf '%s\n' "$text" | grep -qiE 'MIXM|GLXM|EUXM|RUXM|TWXM|TRXM|IDXM|Global|EEA|Russia|Taiwan|Turkey|Indonesia'; then
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
