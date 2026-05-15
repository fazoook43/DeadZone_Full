#!/usr/bin/env bash
# LF normalized for GitHub raw
# =============================================================================
#  device_probe.sh — Auto-detect device codename & hardware info
#
#  Sources of truth (in priority order):
#    1. build.prop inside extracted system partition   (most accurate)
#    2. OTA zip metadata  (META-INF/com/android/metadata)
#    3. OTA filename / URL pattern parsing
#    4. payload.bin manifest  (payload-dumper-go --list)
#    5. User-supplied DEVICE_CODENAME env  (fallback / override)
#
#  Exports after probe_device_info():
#    DEVICE_CODENAME       e.g. "garnet"
#    DEVICE_BRAND          e.g. "Xiaomi"
#    DEVICE_MODEL          e.g. "Redmi Note 13 Pro 5G"
#    DEVICE_SOC            e.g. "Snapdragon"  or  "MediaTek"
#    DEVICE_PLATFORM       e.g. "taro"  (board platform)
#    ROM_VERSION           e.g. "OS2.0.6.0.UNFEUXM"
#    ROM_REGION            e.g. "Global"
#    SUPER_SLOT_MODE       e.g. "VAB"  (if readable from OTA metadata)
# =============================================================================
set -euo pipefail

_probe_log()  { log  "[device_probe] $*"; }
_probe_warn() { warn "[device_probe] $*"; }

# ---------------------------------------------------------------------------
# Internal: parse a key=value line from build.prop / ota metadata
# ---------------------------------------------------------------------------
_prop() {
  local file="$1"
  local key="$2"
  grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '\r\n' || true
}

# ---------------------------------------------------------------------------
# Strategy 1: build.prop from extracted system partition
# ---------------------------------------------------------------------------
_probe_from_build_prop() {
  # Try both system/ and system/system/ (Samsung/MIUI style)
  local bp=""
  for candidate in \
      "$EXTRACTED/system/build.prop" \
      "$EXTRACTED/system/system/build.prop" \
      "$PATCH_ROOT/system/build.prop" \
      "$PATCH_ROOT/system/system/build.prop"; do
    [[ -f "$candidate" ]] && bp="$candidate" && break
  done
  [[ -n "$bp" ]] || return 1

  _probe_log "Reading build.prop: $bp"

  local codename brand model platform soc_hint slot_suffix virtual_ab

  codename="$(_prop "$bp" "ro.product.device")"
  [[ -z "$codename" ]] && codename="$(_prop "$bp" "ro.product.system.device")"
  [[ -z "$codename" ]] && codename="$(_prop "$bp" "ro.product.odm.device")"

  brand="$(_prop "$bp" "ro.product.brand")"
  [[ -z "$brand" ]] && brand="$(_prop "$bp" "ro.product.manufacturer")"

  model="$(_prop "$bp" "ro.product.model")"
  [[ -z "$model" ]] && model="$(_prop "$bp" "ro.product.system.model")"

  platform="$(_prop "$bp" "ro.board.platform")"
  [[ -z "$platform" ]] && platform="$(_prop "$bp" "ro.hardware")"

  # Detect SoC family from platform string
  soc_hint="$(_soc_from_platform "$platform")"

  # Slot info from build.prop
  slot_suffix="$(_prop "$bp" "ro.boot.slot_suffix")"
  virtual_ab="$(_prop "$bp" "ro.virtual_ab.enabled")"

  [[ -n "$codename" ]] || return 1

  # Export what we found
  DEVICE_CODENAME="${codename,,}"   # lowercase
  [[ -n "$brand"    ]] && DEVICE_BRAND="$brand"
  [[ -n "$model"    ]] && DEVICE_MODEL="$model"
  [[ -n "$platform" ]] && DEVICE_PLATFORM="$platform"
  [[ -n "$soc_hint" ]] && DEVICE_SOC="$soc_hint"

  # Slot mode hint from build.prop
  if [[ "$virtual_ab" == "true" ]]; then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-VAB}"
  elif [[ -n "$slot_suffix" ]]; then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  fi

  _probe_log "build.prop → codename=$DEVICE_CODENAME brand=${DEVICE_BRAND:-?} model=${DEVICE_MODEL:-?} platform=${DEVICE_PLATFORM:-?} soc=${DEVICE_SOC:-?}"
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 2: OTA metadata file  (META-INF/com/android/metadata)
# ---------------------------------------------------------------------------
_probe_from_ota_metadata() {
  [[ -n "${ROM_FILE:-}" && -f "$ROM_FILE" ]] || return 1
  require_tool unzip

  local meta_tmp="$LOGS/ota_metadata.txt"
  unzip -p "$ROM_FILE" "META-INF/com/android/metadata" > "$meta_tmp" 2>/dev/null || return 1
  [[ -s "$meta_tmp" ]] || return 1

  _probe_log "Reading OTA metadata"

  local codename pre_build ota_type ab_ota

  # pre-device field: e.g. "garnet" or "garnet_global"
  codename="$(grep -m1 '^pre-device=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' | cut -d_ -f1 | tr '[:upper:]' '[:lower:]' || true)"
  pre_build="$(grep -m1 '^pre-build=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' || true)"
  ota_type="$(grep -m1 '^ota-type=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' || true)"
  ab_ota="$(grep -m1 '^ab-ota-updater=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' || true)"

  # Slot hint from ab-ota-updater field
  if [[ "$ab_ota" == "true" ]]; then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  fi

  # ROM version from pre-build  e.g. "garnet-user OS2.0.6.0.UNFEUXM"
  if [[ -n "$pre_build" && -z "${ROM_VERSION:-unknown}" || "${ROM_VERSION:-}" == "unknown" ]]; then
    local ver
    ver="$(printf '%s\n' "$pre_build" | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' | head -n1 || true)"
    [[ -n "$ver" ]] && ROM_VERSION="$ver"
  fi

  [[ -n "$codename" ]] || return 1
  DEVICE_CODENAME="${codename,,}"
  _probe_log "OTA metadata → codename=$DEVICE_CODENAME ab=${ab_ota:-?}"
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 3: parse the OTA filename / URL
#   Xiaomi pattern:  <codename>-ota_full-<version>-user-<...>.zip
#   e.g. garnet-ota_full-OS2.0.6.0.UNFEUXM-user-14-...zip
# ---------------------------------------------------------------------------
_probe_from_filename() {
  local text="${ROM_FILE:-} ${ROM_URL:-}"
  [[ -n "$text" ]] || return 1

  local codename=""
  local version=""

  # Pattern: <codename>-ota_full-  OR  <codename>_ota_full
  codename="$(printf '%s\n' "$text" \
    | grep -oiE '[a-z][a-z0-9_]+-ota_full' \
    | head -n1 \
    | sed 's/-ota_full//' \
    | tr '[:upper:]' '[:lower:]' \
    || true)"

  # Fallback: first path segment after last slash that looks like a codename
  if [[ -z "$codename" ]]; then
    codename="$(printf '%s\n' "$text" \
      | grep -oE '/[a-z][a-z0-9_]+-ota' \
      | head -n1 \
      | sed 's|/||;s/-ota//' \
      | tr '[:upper:]' '[:lower:]' \
      || true)"
  fi

  # Version
  version="$(printf '%s\n' "$text" \
    | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' \
    | head -n1 \
    || true)"

  [[ -n "$codename" ]] || return 1

  DEVICE_CODENAME="${codename,,}"
  [[ -n "$version" ]] && ROM_VERSION="${ROM_VERSION:-$version}"
  _probe_log "Filename → codename=$DEVICE_CODENAME version=${ROM_VERSION:-?}"
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 4: payload-dumper-go --list  (parses metadata partition names)
# ---------------------------------------------------------------------------
_probe_from_payload_manifest() {
  local payload=""
  for candidate in "$INPUT/ota/payload.bin" "$INPUT/payload.bin"; do
    [[ -f "$candidate" ]] && payload="$candidate" && break
  done
  [[ -n "$payload" ]] || return 1
  command -v payload-dumper-go >/dev/null 2>&1 || return 1

  local list_out="$LOGS/payload_list.txt"
  payload-dumper-go --list "$payload" > "$list_out" 2>&1 || return 1
  [[ -s "$list_out" ]] || return 1

  _probe_log "payload manifest available: $list_out"

  # Slot mode from partition names
  local has_a has_b
  has_a="$(grep -c "_a$" "$list_out" 2>/dev/null || true)"
  has_b="$(grep -c "_b$" "$list_out" 2>/dev/null || true)"
  if (( has_a > 0 && has_b > 0 )); then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  elif (( has_a == 0 && has_b == 0 )); then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-A}"
  fi

  # Some payload-dumper-go versions print device info in header
  local codename=""
  codename="$(grep -m1 -oiE 'device[: ]+[a-z][a-z0-9_]+' "$list_out" \
    | grep -oiE '[a-z][a-z0-9_]+$' \
    | tr '[:upper:]' '[:lower:]' \
    || true)"
  [[ -n "$codename" && -z "${DEVICE_CODENAME:-}" ]] && DEVICE_CODENAME="$codename"

  return 0
}

# ---------------------------------------------------------------------------
# Strategy 5: super.img lpdump — slot mode + group info
# ---------------------------------------------------------------------------
_probe_from_lpdump() {
  command -v lpdump >/dev/null 2>&1 || return 1

  local candidate
  for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
    [[ -f "$candidate" ]] || continue
    lpdump "$candidate" > "$LOGS/lpdump_probe.log" 2>&1 || continue

    _probe_log "lpdump from $candidate"

    # Slot mode
    if grep -qi "Virtual AB: *true" "$LOGS/lpdump_probe.log"; then
      SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-VAB}"
    elif grep -qc "Name:.*_a$" "$LOGS/lpdump_probe.log" 2>/dev/null; then
      SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
    fi
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# _soc_from_platform — map platform string → human-readable SoC family
# ---------------------------------------------------------------------------
_soc_from_platform() {
  local plat="${1,,}"
  case "$plat" in
    sm8*|lahaina|taro|kalama|pineapple|crow|sun|cape|ukee|waipio|yupik|parrot|ravelin)
      printf 'Snapdragon' ;;
    mt*|dimensity*|helio*)
      printf 'MediaTek' ;;
    exynos*|s5e*)
      printf 'Exynos' ;;
    tensor*|gs*)
      printf 'Google Tensor' ;;
    kirin*)
      printf 'Kirin' ;;
    *)
      printf '%s' "$plat" ;;
  esac
}

# ---------------------------------------------------------------------------
# generate_device_conf — write devices/<codename>.conf from probed values
#
#  Only generates the conf if:
#    - Auto-probe is enabled  (DEVICE_PROBE_AUTO=true, default)
#    - The conf does NOT already exist
#    - All required super metadata was discovered
# ---------------------------------------------------------------------------
generate_device_conf() {
  local codename="${DEVICE_CODENAME:-}"
  [[ -n "$codename" ]] || return 1

  local conf="$DEVICES/$codename.conf"

  if [[ -f "$conf" ]]; then
    _probe_log "Device profile already exists: $conf (skipping auto-generate)"
    return 0
  fi

  # We need at minimum SUPER_SIZE and GROUP_SIZE to generate a useful conf.
  # If we don't have them yet (no lpdump ran), try once more.
  if [[ -z "${SUPER_SIZE:-}" ]] || [[ -z "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]]; then
    _probe_from_lpdump || true
    # Also try reading from lpdump.log if available
    if [[ -f "$LOGS/lpdump.log" ]]; then
      SUPER_SIZE="${SUPER_SIZE:-$(awk '/Metadata max size:/{found=1} found && /^Total metadata/{print $NF; exit}' "$LOGS/lpdump.log" || true)}"
    fi
  fi

  if [[ -z "${SUPER_SIZE:-}" ]]; then
    _probe_warn "Cannot auto-generate $conf: SUPER_SIZE unknown (run lpdump or set manually)"
    return 1
  fi
  if [[ -z "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]]; then
    _probe_warn "Cannot auto-generate $conf: DYNAMIC_PARTITION_GROUP_SIZE unknown"
    return 1
  fi

  local slot_mode="${SUPER_SLOT_MODE:-VAB}"
  local brand="${DEVICE_BRAND:-Xiaomi}"
  local soc="${DEVICE_SOC:-unknown}"
  local platform="${DEVICE_PLATFORM:-unknown}"
  local model="${DEVICE_MODEL:-}"
  local group_name="${DYNAMIC_PARTITION_GROUP_NAME:-qti_dynamic_partitions}"
  local fastboot_slot="ab_suffix"
  local partition_suffix=""

  if [[ "$slot_mode" == "A" ]]; then
    fastboot_slot="single"
    partition_suffix=""
    group_name="${group_name:-main}"
  fi

  _probe_log "Auto-generating device profile: $conf"

  cat > "$conf" << EOF
# LF normalized for GitHub raw
# Auto-generated by DeadZone device_probe.sh
# Device: ${model:-$codename}  ($brand)
# SoC: $soc  Platform: $platform
# Verify SUPER_SIZE with: fastboot getvar partition-size:super
# Verify GROUP_SIZE with:  lpdump <super.img>

DEVICE_CODENAME=$codename
DEVICE_BRAND=$brand
DEVICE_SOC=$soc

# super partition metadata
SUPER_SIZE=$SUPER_SIZE
SUPER_SLOT_MODE=$slot_mode
SUPER_OUTPUT_FORMAT=sparse
SUPER_ACTIVE_SLOT=a
SUPER_NAME=super
SUPER_METADATA_SIZE=${SUPER_METADATA_SIZE:-65536}
SUPER_METADATA_SLOTS=${SUPER_METADATA_SLOTS:-2}
METADATA_SLOTS=${SUPER_METADATA_SLOTS:-2}

# Partition group
SUPER_GROUP_BASENAME=$group_name
DYNAMIC_PARTITION_GROUP_NAME=$group_name
DYNAMIC_PARTITION_GROUP_SIZE=$DYNAMIC_PARTITION_GROUP_SIZE
PARTITION_SUFFIX=$partition_suffix

# Dynamic partitions
DYNAMIC_PARTITIONS="${DYNAMIC_PARTITIONS:-system product system_ext vendor vendor_dlkm system_dlkm odm odm_dlkm mi_ext}"

# Fastboot images
REQUIRED_FASTBOOT_IMAGES="${REQUIRED_FASTBOOT_IMAGES:-boot.img init_boot.img vendor_boot.img vbmeta.img}"
OPTIONAL_FASTBOOT_IMAGES="${OPTIONAL_FASTBOOT_IMAGES:-dtbo.img vbmeta_system.img vbmeta_vendor.img vendor_kernel_boot.img recovery.img logo.img lk.img tee.img scp.img spmfw.img audio_dsp.img dpm.img mcupm.img pi_img.img gz.img md1img.img}"
VBMETA_IMAGES="vbmeta.img vbmeta_system.img vbmeta_vendor.img"
FASTBOOT_SLOT_MODE=$fastboot_slot
VBMETA_PATCH_STRATEGY=binary
EOF

  log "Auto-generated device profile: $conf"
  return 0
}

# ---------------------------------------------------------------------------
# probe_device_info — main public function
#
#  Call this AFTER fetch_rom and BEFORE load_device_profile.
#  Tries all strategies in order, exports what it finds.
# ---------------------------------------------------------------------------
probe_device_info() {
  local probe_enabled="${DEVICE_PROBE_AUTO:-true}"

  # If user explicitly passed DEVICE_CODENAME and probe is disabled, skip
  if [[ "$probe_enabled" != "true" ]]; then
    _probe_log "DEVICE_PROBE_AUTO=false — skipping auto-probe"
    return 0
  fi

  _probe_log "Starting device auto-probe …"
  _probe_log "ROM_FILE=${ROM_FILE:-<none>}"
  _probe_log "ROM_URL=${ROM_URL:-<none>}"

  local original_codename="${DEVICE_CODENAME:-}"

  # Run strategies — each one fills in what it can
  # (they don't die on failure, they just return 1)

  # Strategy 3 first — fastest, no extraction needed yet
  _probe_from_filename            || true

  # Strategy 2 — OTA zip metadata
  _probe_from_ota_metadata        || true

  # Strategy 4 — payload manifest (needs payload.bin extracted)
  _probe_from_payload_manifest    || true

  # Strategy 5 — lpdump (needs super.img)
  _probe_from_lpdump              || true

  # Strategy 1 — build.prop (needs partitions extracted — run last)
  _probe_from_build_prop          || true

  # If we still have no codename, fall back to what user passed
  if [[ -z "${DEVICE_CODENAME:-}" ]]; then
    if [[ -n "$original_codename" ]]; then
      DEVICE_CODENAME="$original_codename"
      _probe_warn "Could not auto-detect codename; using user-supplied: $DEVICE_CODENAME"
    else
      die "Could not detect device codename. Pass DEVICE_CODENAME explicitly."
    fi
  fi

  # If user passed a codename but probe found something different, trust probe
  if [[ -n "$original_codename" && "$DEVICE_CODENAME" != "${original_codename,,}" ]]; then
    _probe_warn "Probe detected '$DEVICE_CODENAME' but user passed '$original_codename' — using probe result"
    _probe_warn "Set DEVICE_PROBE_AUTO=false to force user-supplied codename"
  fi

  export DEVICE_CODENAME DEVICE_BRAND DEVICE_MODEL DEVICE_SOC DEVICE_PLATFORM \
         ROM_VERSION ROM_REGION SUPER_SLOT_MODE

  _probe_log "═══════════════════════════════════════════"
  _probe_log "Device codename : $DEVICE_CODENAME"
  _probe_log "Brand           : ${DEVICE_BRAND:-unknown}"
  _probe_log "Model           : ${DEVICE_MODEL:-unknown}"
  _probe_log "SoC             : ${DEVICE_SOC:-unknown}"
  _probe_log "Platform        : ${DEVICE_PLATFORM:-unknown}"
  _probe_log "Slot mode       : ${SUPER_SLOT_MODE:-auto}"
  _probe_log "ROM version     : ${ROM_VERSION:-unknown}"
  _probe_log "ROM region      : ${ROM_REGION:-auto}"
  _probe_log "═══════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# probe_super_metadata — run lpdump on extracted super to fill SUPER_* vars
#  Called AFTER extract_payload_all_images, BEFORE build_super_image
# ---------------------------------------------------------------------------
probe_super_metadata() {
  command -v lpdump >/dev/null 2>&1 || {
    _probe_warn "lpdump not available — super metadata must come from device profile"
    return 0
  }

  local candidate
  for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
    [[ -f "$candidate" ]] || continue

    _probe_log "Reading super metadata from $candidate"
    lpdump "$candidate" > "$LOGS/lpdump_meta_probe.log" 2>&1 || continue

    local raw_super_size
    raw_super_size="$(file_size "$candidate")"

    SUPER_SIZE="${SUPER_SIZE:-$raw_super_size}"
    SUPER_METADATA_SIZE="${SUPER_METADATA_SIZE:-$(awk \
      '/Metadata max size:/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}}' \
      "$LOGS/lpdump_meta_probe.log")}"
    SUPER_METADATA_SLOTS="${SUPER_METADATA_SLOTS:-$(awk \
      '/Metadata slot count:/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}}' \
      "$LOGS/lpdump_meta_probe.log")}"
    DYNAMIC_PARTITION_GROUP_NAME="${DYNAMIC_PARTITION_GROUP_NAME:-$(awk \
      '/Name:/{name=$2} /Maximum size:/ && name!=""{print name; exit}' \
      "$LOGS/lpdump_meta_probe.log")}"
    DYNAMIC_PARTITION_GROUP_SIZE="${DYNAMIC_PARTITION_GROUP_SIZE:-$(awk \
      '/Maximum size:/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}}' \
      "$LOGS/lpdump_meta_probe.log")}"

    export SUPER_SIZE SUPER_METADATA_SIZE SUPER_METADATA_SLOTS \
           DYNAMIC_PARTITION_GROUP_NAME DYNAMIC_PARTITION_GROUP_SIZE

    _probe_log "super metadata: size=$SUPER_SIZE meta_size=${SUPER_METADATA_SIZE:-?} slots=${SUPER_METADATA_SLOTS:-?} group=${DYNAMIC_PARTITION_GROUP_NAME:-?} group_size=${DYNAMIC_PARTITION_GROUP_SIZE:-?}"
    return 0
  done

  _probe_warn "No super.img found for metadata probe"
  return 0
}
