#!/usr/bin/env bash
# LF normalized for GitHub raw
# =============================================================================
#  device_probe.sh — Auto-detect device info & super partition metadata
#
#  Codename policy
#  ───────────────
#  If CODENAME_LOCKED=true (set by main.sh when the user supplies a non-'auto'
#  codename), the probe NEVER changes DEVICE_CODENAME.  It still runs to fill
#  in brand, model, SoC, and — most importantly — super partition metadata.
#
#  SUPER_SIZE policy
#  ─────────────────
#  Priority (highest → lowest):
#    1. lpdump "Block device table → Size:"  ← exact device partition size
#    2. SUPER_SIZE_OVERRIDE env              ← manual input from workflow
#    3. file_size of super.img               ← last resort approximation
#
#  Exports after probe_device_info():
#    DEVICE_CODENAME       e.g. "sweet"
#    DEVICE_BRAND          e.g. "Xiaomi"
#    DEVICE_MODEL          e.g. "Redmi Note 10"
#    DEVICE_SOC            e.g. "Snapdragon"
#    DEVICE_PLATFORM       e.g. "sm6150"
#    ROM_VERSION           e.g. "OS2.0.6.0.UNFEUXM"
#    ROM_REGION            e.g. "Global"
#    SUPER_SLOT_MODE       e.g. "VAB"
# =============================================================================
set -euo pipefail

_probe_log()  { log  "[device_probe] $*"; }
_probe_warn() { warn "[device_probe] $*"; }

# ---------------------------------------------------------------------------
# Internal: parse a key=value from a props file
# ---------------------------------------------------------------------------
_prop() {
  local file="$1"
  local key="$2"
  grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '\r\n' || true
}

# ---------------------------------------------------------------------------
# _parse_super_size_from_lpdump_log
#  Read the exact partition size from lpdump's "Block device table → Size:"
#  This is the authoritative value — it is embedded in the super image
#  metadata and always reflects the real on-device partition size, even when
#  the image file has been trimmed/sparse-encoded.
#
#  lpdump output fragment:
#    Block device table:
#      Name: super
#      First sector: 2048
#      Size: 9663676416   ← we want this
#      Flags: none
# ---------------------------------------------------------------------------
_parse_super_size_from_lpdump_log() {
  local lpdump_log="$1"
  [[ -s "$lpdump_log" ]] || return 1

  local size
  size=$(awk '
    /Block device table/ { in_bdt=1 }
    in_bdt && /^\s+Size:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/ && ($i + 0) > 1048576) {
          print $i
          exit
        }
      }
    }
  ' "$lpdump_log")

  if [[ -n "${size:-}" ]] && (( size > 0 )); then
    printf '%s' "$size"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _soc_from_platform — map platform string → human-readable SoC family
# ---------------------------------------------------------------------------
_soc_from_platform() {
  local plat="${1,,}"
  case "$plat" in
    sm8*|lahaina|taro|kalama|pineapple|crow|sun|cape|ukee|waipio|yupik|parrot|ravelin|\
    sm6*|bengal|khaje|trinket|atoll|msm8953|msm8998|sdm660|sdm845)
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
# Strategy 1: build.prop from extracted system partition
# ---------------------------------------------------------------------------
_probe_from_build_prop() {
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

  soc_hint="$(_soc_from_platform "$platform")"

  slot_suffix="$(_prop "$bp" "ro.boot.slot_suffix")"
  virtual_ab="$(_prop  "$bp" "ro.virtual_ab.enabled")"

  # Update slot mode from build.prop — can upgrade AB→VAB but never downgrade
  if [[ "$virtual_ab" == "true" ]]; then
    SUPER_SLOT_MODE="VAB"
  elif [[ -n "$slot_suffix" && "${SUPER_SLOT_MODE:-}" != "VAB" ]]; then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  fi

  # Codename: only set if not locked by user input
  if [[ "${CODENAME_LOCKED:-false}" != "true" ]] && [[ -n "$codename" ]]; then
    DEVICE_CODENAME="${codename,,}"
    _probe_log "build.prop → codename=$DEVICE_CODENAME"
  else
    _probe_log "build.prop → codename locked as '$DEVICE_CODENAME' (skipping probe value '${codename:-?}')"
  fi

  [[ -n "$brand"    ]] && DEVICE_BRAND="$brand"
  [[ -n "$model"    ]] && DEVICE_MODEL="$model"
  [[ -n "$platform" ]] && DEVICE_PLATFORM="$platform"
  [[ -n "$soc_hint" ]] && DEVICE_SOC="$soc_hint"

  return 0
}

# ---------------------------------------------------------------------------
# Strategy 2: OTA metadata (META-INF/com/android/metadata)
# ---------------------------------------------------------------------------
_probe_from_ota_metadata() {
  [[ -n "${ROM_FILE:-}" && -f "$ROM_FILE" ]] || return 1
  require_tool unzip

  local meta_tmp="$LOGS/ota_metadata.txt"
  unzip -p "$ROM_FILE" "META-INF/com/android/metadata" > "$meta_tmp" 2>/dev/null || return 1
  [[ -s "$meta_tmp" ]] || return 1

  _probe_log "Reading OTA metadata"

  local codename pre_build ab_ota

  codename="$(grep -m1 '^pre-device=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' | cut -d_ -f1 | tr '[:upper:]' '[:lower:]' || true)"
  pre_build="$(grep -m1 '^pre-build='  "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' || true)"
  ab_ota="$(grep -m1 '^ab-ota-updater=' "$meta_tmp" | cut -d= -f2- | tr -d '\r\n' || true)"

  # Slot hint from OTA metadata — low trust, only set if nothing else has set it
  if [[ "$ab_ota" == "true" ]]; then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  fi

  # ROM version
  if [[ -n "$pre_build" && ( -z "${ROM_VERSION:-}" || "${ROM_VERSION:-}" == "unknown" ) ]]; then
    local ver
    ver="$(printf '%s\n' "$pre_build" | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' | head -n1 || true)"
    [[ -n "$ver" ]] && ROM_VERSION="$ver"
  fi

  # Codename: only set if not locked and not already set by a higher-trust source
  if [[ "${CODENAME_LOCKED:-false}" != "true" ]] && \
     [[ -n "$codename" && -z "${DEVICE_CODENAME:-}" ]]; then
    DEVICE_CODENAME="${codename,,}"
    _probe_log "OTA metadata → codename=$DEVICE_CODENAME ab=${ab_ota:-?}"
  else
    _probe_log "OTA metadata → codename locked or already set, skipping '${codename:-?}'"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Strategy 3: parse OTA filename / URL
# ---------------------------------------------------------------------------
_probe_from_filename() {
  local text="${ROM_FILE:-} ${ROM_URL:-}"
  [[ -n "$text" ]] || return 1

  local codename=""
  local version=""

  codename="$(printf '%s\n' "$text" \
    | grep -oiE '[a-z][a-z0-9_]+-ota_full' \
    | head -n1 \
    | sed 's/-ota_full//' \
    | tr '[:upper:]' '[:lower:]' \
    || true)"

  if [[ -z "$codename" ]]; then
    codename="$(printf '%s\n' "$text" \
      | grep -oE '/[a-z][a-z0-9_]+-ota' \
      | head -n1 \
      | sed 's|/||;s/-ota//' \
      | tr '[:upper:]' '[:lower:]' \
      || true)"
  fi

  version="$(printf '%s\n' "$text" \
    | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z0-9]+' \
    | head -n1 \
    || true)"

  [[ -n "$codename" ]] || return 1

  # Codename: lowest trust — only if not locked and nothing set yet
  if [[ "${CODENAME_LOCKED:-false}" != "true" ]] && \
     [[ -z "${DEVICE_CODENAME:-}" ]]; then
    DEVICE_CODENAME="${codename,,}"
    _probe_log "Filename → codename=$DEVICE_CODENAME"
  fi

  [[ -n "$version" ]] && ROM_VERSION="${ROM_VERSION:-$version}"
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 4: payload-dumper-go --list
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

  _probe_log "payload manifest: $list_out"

  # Slot hint from partition names (low trust — can't distinguish AB from VAB)
  local has_a has_b
  has_a="$(grep -cE "_a$" "$list_out" 2>/dev/null || true)"
  has_b="$(grep -cE "_b$" "$list_out" 2>/dev/null || true)"
  if (( has_a > 0 && has_b > 0 )); then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
  elif (( has_a == 0 && has_b == 0 )); then
    SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-A}"
  fi

  # Some payload-dumper-go versions print device info in header
  if [[ "${CODENAME_LOCKED:-false}" != "true" ]] && [[ -z "${DEVICE_CODENAME:-}" ]]; then
    local codename=""
    codename="$(grep -m1 -oiE 'device[: ]+[a-z][a-z0-9_]+' "$list_out" \
      | grep -oiE '[a-z][a-z0-9_]+$' \
      | tr '[:upper:]' '[:lower:]' \
      || true)"
    [[ -n "$codename" ]] && DEVICE_CODENAME="$codename"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Strategy 5: super.img lpdump — slot mode + super metadata
# ---------------------------------------------------------------------------
_probe_from_lpdump() {
  command -v lpdump >/dev/null 2>&1 || return 1

  local candidate
  for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
    [[ -f "$candidate" ]] || continue
    lpdump "$candidate" > "$LOGS/lpdump_probe.log" 2>&1 || continue

    _probe_log "lpdump from $candidate"

    # Slot mode — high trust
    if grep -qiE "^\s*Virtual AB:\s*true" "$LOGS/lpdump_probe.log"; then
      SUPER_SLOT_MODE="VAB"
    elif grep -qE "^\s+Name:\s+\S+_a\s*$" "$LOGS/lpdump_probe.log" 2>/dev/null; then
      [[ "${SUPER_SLOT_MODE:-}" != "VAB" ]] && SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-AB}"
    fi

    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# generate_device_conf — write devices/<codename>.conf from probed values
# ---------------------------------------------------------------------------
generate_device_conf() {
  local codename="${DEVICE_CODENAME:-}"
  [[ -n "$codename" ]] || return 1

  local conf="$DEVICES/$codename.conf"

  if [[ -f "$conf" ]]; then
    _probe_log "Device profile already exists: $conf (skipping auto-generate)"
    return 0
  fi

  # Ensure we have super metadata — try lpdump one more time
  if [[ -z "${SUPER_SIZE:-}" ]] || [[ -z "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]]; then
    _probe_from_lpdump || true
    # Try reading from existing lpdump logs
    for ldlog in "$LOGS/lpdump.log" "$LOGS/lpdump_probe.log" "$LOGS/lpdump_meta_probe.log"; do
      if [[ -f "$ldlog" && -z "${SUPER_SIZE:-}" ]]; then
        local sz
        sz="$(_parse_super_size_from_lpdump_log "$ldlog" || true)"
        [[ -n "${sz:-}" ]] && SUPER_SIZE="$sz"
      fi
    done
  fi

  # Accept SUPER_SIZE from manual override if auto-detect failed
  if [[ -z "${SUPER_SIZE:-}" ]] && [[ -n "${SUPER_SIZE_OVERRIDE:-}" ]]; then
    SUPER_SIZE="$SUPER_SIZE_OVERRIDE"
    _probe_log "Using SUPER_SIZE_OVERRIDE=$SUPER_SIZE (manual input)"
  fi

  if [[ -z "${SUPER_SIZE:-}" ]]; then
    _probe_warn "Cannot auto-generate $conf: SUPER_SIZE unknown"
    _probe_warn "Set SUPER_SIZE_OVERRIDE in the workflow or create $conf manually"
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
# SUPER_SIZE was read from: lpdump Block device table (exact partition size)
# Verify: fastboot getvar partition-size:super

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
#  Call AFTER fetch_rom, BEFORE load_device_profile.
#  Fills: DEVICE_CODENAME (unless locked), DEVICE_BRAND, DEVICE_MODEL,
#         DEVICE_SOC, DEVICE_PLATFORM, ROM_VERSION, ROM_REGION, SUPER_SLOT_MODE
# ---------------------------------------------------------------------------
probe_device_info() {
  _probe_log "Starting device probe (CODENAME_LOCKED=${CODENAME_LOCKED:-false})"
  _probe_log "ROM_FILE=${ROM_FILE:-<none>}"
  _probe_log "ROM_URL=${ROM_URL:-<none>}"

  if [[ "${CODENAME_LOCKED:-false}" == "true" ]]; then
    _probe_log "Codename locked to '$DEVICE_CODENAME' — will only probe metadata"
  fi

  # Run strategies from fastest → most complete.
  # Each one skips what's already set (except build.prop which can upgrade slot mode).

  # Strategy 3 (filename) — fastest, no IO
  _probe_from_filename         || true

  # Strategy 2 (OTA metadata) — reads one file from zip
  _probe_from_ota_metadata     || true

  # Strategy 4 (payload manifest) — needs payload.bin extracted
  _probe_from_payload_manifest || true

  # Strategy 5 (lpdump) — needs super.img
  _probe_from_lpdump           || true

  # Strategy 1 (build.prop) — needs full partition extraction — highest trust
  _probe_from_build_prop       || true

  # Final codename validation
  if [[ -z "${DEVICE_CODENAME:-}" ]]; then
    die "Could not detect device codename. Pass DEVICE_CODENAME explicitly (not 'auto')."
  fi

  export DEVICE_CODENAME DEVICE_BRAND DEVICE_MODEL DEVICE_SOC DEVICE_PLATFORM \
         ROM_VERSION ROM_REGION SUPER_SLOT_MODE

  _probe_log "══════════════════════════════════════════"
  _probe_log "Device codename : $DEVICE_CODENAME${CODENAME_LOCKED:+ (locked by user)}"
  _probe_log "Brand           : ${DEVICE_BRAND:-unknown}"
  _probe_log "Model           : ${DEVICE_MODEL:-unknown}"
  _probe_log "SoC             : ${DEVICE_SOC:-unknown}"
  _probe_log "Platform        : ${DEVICE_PLATFORM:-unknown}"
  _probe_log "Slot mode       : ${SUPER_SLOT_MODE:-pending detect_slot_mode}"
  _probe_log "ROM version     : ${ROM_VERSION:-unknown}"
  _probe_log "ROM region      : ${ROM_REGION:-auto}"
  _probe_log "══════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# probe_super_metadata — run lpdump on extracted super to fill SUPER_* vars
#  Called AFTER extract_payload_all_images, BEFORE build_super_image.
#
#  SUPER_SIZE is read from the lpdump "Block device table → Size:" field
#  (exact on-device partition size), NOT from file_size() which may differ
#  for trimmed / sparse images.
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

    # ── SUPER_SIZE: parse from block device table (authoritative) ─────────
    local bdt_size
    bdt_size="$(_parse_super_size_from_lpdump_log "$LOGS/lpdump_meta_probe.log" || true)"

    if [[ -n "${bdt_size:-}" ]]; then
      # Block device table size is always the canonical answer
      SUPER_SIZE="$bdt_size"
      _probe_log "SUPER_SIZE=$SUPER_SIZE (from lpdump block device table)"
    elif [[ -z "${SUPER_SIZE:-}" ]]; then
      # Fallback: file_size (less accurate for sparse/trimmed images)
      local file_sz
      file_sz="$(file_size "$candidate")"
      SUPER_SIZE="$file_sz"
      _probe_warn "SUPER_SIZE=$SUPER_SIZE (fallback: file size — verify with 'fastboot getvar partition-size:super')"
    fi

    # ── SUPER_SIZE_OVERRIDE wins over everything if user provided it ──────
    if [[ -n "${SUPER_SIZE_OVERRIDE:-}" ]]; then
      SUPER_SIZE="$SUPER_SIZE_OVERRIDE"
      _probe_log "SUPER_SIZE=$SUPER_SIZE (overridden by user-supplied SUPER_SIZE_OVERRIDE)"
    fi

    # ── Other metadata from lpdump ────────────────────────────────────────
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

  # ── No super.img found — check for SUPER_SIZE_OVERRIDE ───────────────────
  if [[ -n "${SUPER_SIZE_OVERRIDE:-}" ]] && [[ -z "${SUPER_SIZE:-}" ]]; then
    SUPER_SIZE="$SUPER_SIZE_OVERRIDE"
    export SUPER_SIZE
    _probe_log "No super.img found; using SUPER_SIZE_OVERRIDE=$SUPER_SIZE"
  fi

  _probe_warn "No super.img found for metadata probe — super data may come from device profile"
  return 0
}
