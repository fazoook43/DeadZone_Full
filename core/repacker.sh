#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

build_super_image() {
  require_tool lpmake

  prepare_super_lpmake_context

  local -a cmd
  build_lpmake_cmd cmd "$OUTPUT/images/super.img" true "$SUPER_OUTPUT_FORMAT"

  printf '%q ' "${cmd[@]}" > "$LOGS/lpmake-command.log"
  printf '\n' >> "$LOGS/lpmake-command.log"

  log "Running lpmake"
  "${cmd[@]}" 2>&1 | tee "$LOGS/lpmake.log"

  [[ -s "$OUTPUT/images/super.img" ]] || die "lpmake did not create a non-empty $OUTPUT/images/super.img"
  log "Final fastboot super image: output/images/super.img"
  log "Output path: $OUTPUT/images/super.img"
  log "super.img size: $(file_size "$OUTPUT/images/super.img") bytes ($(human_size "$OUTPUT/images/super.img"))"
  file "$OUTPUT/images/super.img" 2>&1 | tee "$LOGS/super_file_type.txt" || true
  file_size "$OUTPUT/images/super.img" > "$LOGS/super_size.txt"
}

prepare_super_lpmake_context() {
  local metadata_source="profile"
  if load_device_profile; then
    metadata_source="profile"
  elif _load_super_metadata_from_image; then
    metadata_source="lpdump"
  else
    _fail_missing_profile
  fi

  _validate_super_profile

  SUPER_TOTAL_IMAGE_SIZE=0
  SUPER_TOTAL_B_IMAGE_SIZE=0
  local part img size container fs b_img b_size group_a_size group_b_size
  while IFS=$'\t' read -r part img size container fs; do
    [[ -n "${part:-}" ]] || continue
    SUPER_TOTAL_IMAGE_SIZE=$((SUPER_TOTAL_IMAGE_SIZE + size))
    b_img="$EXTRACTED/${part}_b.img"
    if [[ -s "$b_img" ]]; then
      b_size="$(file_size "$b_img")"
      SUPER_TOTAL_B_IMAGE_SIZE=$((SUPER_TOTAL_B_IMAGE_SIZE + b_size))
    fi
  done < "$WORKSPACE/partitions.tsv"

  SUPER_SLOT_MODE="${SUPER_SLOT_MODE:-A}"
  SUPER_OUTPUT_FORMAT="${SUPER_OUTPUT_FORMAT:-sparse}"
  SUPER_ACTIVE_SLOT="${SUPER_ACTIVE_SLOT:-a}"
  SUPER_INACTIVE_SLOT="b"
  local group_basename="${SUPER_GROUP_BASENAME:-${DYNAMIC_PARTITION_GROUP_NAME:-qti_dynamic_partitions}}"
  SUPER_ACTIVE_GROUP="${DYNAMIC_PARTITION_GROUP_NAME:-$group_basename}"
  SUPER_INACTIVE_GROUP=""

  case "$SUPER_SLOT_MODE" in
    A|AB|VAB) ;;
    *) die "Unsupported SUPER_SLOT_MODE=$SUPER_SLOT_MODE" ;;
  esac
  case "$SUPER_OUTPUT_FORMAT" in
    sparse|raw) ;;
    *) die "Unsupported SUPER_OUTPUT_FORMAT=$SUPER_OUTPUT_FORMAT" ;;
  esac
  case "$SUPER_ACTIVE_SLOT" in
    a) SUPER_INACTIVE_SLOT="b" ;;
    b) SUPER_INACTIVE_SLOT="a" ;;
    *) die "Unsupported SUPER_ACTIVE_SLOT=$SUPER_ACTIVE_SLOT" ;;
  esac

  if [[ "$SUPER_SLOT_MODE" == "AB" || "$SUPER_SLOT_MODE" == "VAB" ]]; then
    SUPER_ACTIVE_GROUP="${group_basename}_${SUPER_ACTIVE_SLOT}"
    SUPER_INACTIVE_GROUP="${group_basename}_${SUPER_INACTIVE_SLOT}"
    group_a_size="${DYNAMIC_PARTITION_GROUP_SIZE_A:-$DYNAMIC_PARTITION_GROUP_SIZE}"
    if [[ -n "${DYNAMIC_PARTITION_GROUP_SIZE_B:-}" ]]; then
      group_b_size="$DYNAMIC_PARTITION_GROUP_SIZE_B"
    elif (( SUPER_TOTAL_B_IMAGE_SIZE > 0 )); then
      group_b_size="$DYNAMIC_PARTITION_GROUP_SIZE"
    else
      group_b_size=1048576
    fi
  else
    group_a_size="$DYNAMIC_PARTITION_GROUP_SIZE"
    group_b_size=0
  fi
  SUPER_GROUP_A_SIZE="$group_a_size"
  SUPER_GROUP_B_SIZE="$group_b_size"

  log "Super metadata source: $metadata_source"
  log "Super size: $SUPER_SIZE"
  log "SUPER_SLOT_MODE: $SUPER_SLOT_MODE"
  log "SUPER_OUTPUT_FORMAT: $SUPER_OUTPUT_FORMAT"
  log "SUPER_ACTIVE_SLOT: $SUPER_ACTIVE_SLOT"
  log "Active group name: $SUPER_ACTIVE_GROUP"
  [[ -n "$SUPER_INACTIVE_GROUP" ]] && log "Inactive group name: $SUPER_INACTIVE_GROUP"
  log "Active image total size: $SUPER_TOTAL_IMAGE_SIZE"
  log "Inactive image total size: $SUPER_TOTAL_B_IMAGE_SIZE"
  log "Group A size: $SUPER_GROUP_A_SIZE"
  log "Group B size: $SUPER_GROUP_B_SIZE"
  log "Use --virtual-ab: $([[ "$SUPER_SLOT_MODE" == "VAB" ]] && printf true || printf false)"

  if (( SUPER_TOTAL_IMAGE_SIZE > SUPER_GROUP_A_SIZE )); then
    die "Active partition images exceed group A size: images=$SUPER_TOTAL_IMAGE_SIZE group=$SUPER_GROUP_A_SIZE"
  fi
  if (( SUPER_TOTAL_B_IMAGE_SIZE > SUPER_GROUP_B_SIZE )); then
    die "Inactive partition images exceed group B size: images=$SUPER_TOTAL_B_IMAGE_SIZE group=$SUPER_GROUP_B_SIZE"
  fi
}

build_lpmake_cmd() {
  local -n out_cmd="$1"
  local output_path="$2"
  local include_images="$3"
  local output_format="$4"
  local part img size container fs b_img b_size

  out_cmd=(
    lpmake
    --metadata-size "$SUPER_METADATA_SIZE"
    --metadata-slots "$SUPER_METADATA_SLOTS"
    --super-name "${SUPER_NAME:-super}"
    --device "super:$SUPER_SIZE"
    --group "$SUPER_ACTIVE_GROUP:$SUPER_GROUP_A_SIZE"
  )
  if [[ "$SUPER_SLOT_MODE" == "AB" || "$SUPER_SLOT_MODE" == "VAB" ]]; then
    out_cmd+=(--group "$SUPER_INACTIVE_GROUP:$SUPER_GROUP_B_SIZE")
  fi
  [[ "$SUPER_SLOT_MODE" == "VAB" ]] && out_cmd+=(--virtual-ab)
  [[ "$output_format" == "sparse" ]] && out_cmd+=(--sparse)

  while IFS=$'\t' read -r part img size container fs; do
    [[ -n "${part:-}" ]] || continue
    if [[ "$SUPER_SLOT_MODE" == "A" ]]; then
      local lp_name="${part}${PARTITION_SUFFIX:-}"
      out_cmd+=(--partition "$lp_name:readonly:$size:$SUPER_ACTIVE_GROUP")
      [[ "$include_images" == "true" ]] && out_cmd+=(--image "$lp_name=$img")
    else
      local active_lp="${part}_${SUPER_ACTIVE_SLOT}"
      local inactive_lp="${part}_${SUPER_INACTIVE_SLOT}"
      out_cmd+=(--partition "$active_lp:readonly:$size:$SUPER_ACTIVE_GROUP")
      [[ "$include_images" == "true" ]] && out_cmd+=(--image "$active_lp=$img")

      b_img="$EXTRACTED/${part}_${SUPER_INACTIVE_SLOT}.img"
      if [[ -s "$b_img" ]]; then
        b_size="$(file_size "$b_img")"
        out_cmd+=(--partition "$inactive_lp:readonly:$b_size:$SUPER_INACTIVE_GROUP")
        [[ "$include_images" == "true" ]] && out_cmd+=(--image "$inactive_lp=$b_img")
      else
        out_cmd+=(--partition "$inactive_lp:readonly:0:$SUPER_INACTIVE_GROUP")
      fi
    fi
  done < "$WORKSPACE/partitions.tsv"

  out_cmd+=(--output "$output_path")
}

_load_super_metadata_from_image() {
  if ! command -v lpdump >/dev/null 2>&1; then
    warn "lpdump is not available; using devices/$DEVICE_CODENAME.conf if present"
    return 1
  fi

  local candidate
  for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
    [[ -f "$candidate" ]] || continue
    log "Reading exact super metadata from: $candidate"
    lpdump "$candidate" > "$LOGS/lpdump.log" 2>&1 || return 1

    SUPER_SIZE="$(file_size "$candidate")"
    SUPER_METADATA_SIZE="$(awk '/Metadata max size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"
    SUPER_METADATA_SLOTS="$(awk '/Metadata slot count:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"
    DYNAMIC_PARTITION_GROUP_NAME="$(awk '/Name:/ {name=$2} /Maximum size:/ && name != "" {print name; exit}' "$LOGS/lpdump.log")"
    DYNAMIC_PARTITION_GROUP_SIZE="$(awk '/Maximum size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"

    [[ -n "${SUPER_METADATA_SIZE:-}" && -n "${SUPER_METADATA_SLOTS:-}" ]] || return 1
    [[ -n "${DYNAMIC_PARTITION_GROUP_NAME:-}" && -n "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]] || return 1

    export SUPER_SIZE SUPER_METADATA_SIZE SUPER_METADATA_SLOTS DYNAMIC_PARTITION_GROUP_NAME DYNAMIC_PARTITION_GROUP_SIZE
    return 0
  done

  return 1
}

compress_super_image() {
  require_tool zstd
  log "Compressing super.img to super.img.zst"
  zstd -T0 -19 -f "$OUTPUT/images/super.img" -o "$OUTPUT/super.img.zst" 2>&1 | tee "$LOGS/zstd.log"
  log "Output path: $OUTPUT/super.img.zst"
  log "super.img.zst size: $(file_size "$OUTPUT/super.img.zst") bytes ($(human_size "$OUTPUT/super.img.zst"))"
}

validate_super_image() {
  [[ -s "$OUTPUT/images/super.img" ]] || die "super.img is missing or empty"
  require_tool lpdump
  require_tool lpmake

  local validation_source="$OUTPUT/images/super.img"
  if [[ "${SUPER_OUTPUT_FORMAT:-sparse}" == "sparse" ]]; then
    log "SUPER_OUTPUT_FORMAT=sparse; validating with metadata-only non-sparse image"
    validation_source="$LOGS/super_metadata.img"
    local -a metadata_cmd
    build_lpmake_cmd metadata_cmd "$validation_source" false raw
    printf '%q ' "${metadata_cmd[@]}" > "$LOGS/lpmake-metadata-command.log"
    printf '\n' >> "$LOGS/lpmake-metadata-command.log"
    log "Metadata validation image: output/logs/super_metadata.img"
    "${metadata_cmd[@]}" 2>&1 | tee "$LOGS/lpmake_metadata.log"
    [[ -s "$validation_source" ]] || die "metadata validation image was not created"
  fi

  log "lpdump validation source: ${validation_source#$WORKSPACE/}"
  file "$OUTPUT/images/super.img" || true
  file "$validation_source" || true
  lpdump "$validation_source" > "$LOGS/lpdump_super.txt" 2>&1 || die "lpdump validation failed for ${validation_source#$WORKSPACE/}"

  local slot_mode="${SUPER_SLOT_MODE:-A}"
  if [[ "$slot_mode" == "AB" || "$slot_mode" == "VAB" ]]; then
    local part missing_active=() missing_inactive=()
    local active_slot="${SUPER_ACTIVE_SLOT:-a}"
    local inactive_slot
    case "$active_slot" in
      a) inactive_slot="b" ;;
      b) inactive_slot="a" ;;
      *) die "Unsupported SUPER_ACTIVE_SLOT=$active_slot" ;;
    esac

    for part in $DYNAMIC_PARTITIONS; do
      grep -q "${part}_${active_slot}" "$LOGS/lpdump_super.txt" || missing_active+=("${part}_${active_slot}")
      grep -q "${part}_${inactive_slot}" "$LOGS/lpdump_super.txt" || missing_inactive+=("${part}_${inactive_slot}")
    done

    if [[ ${#missing_active[@]} -gt 0 ]]; then
      die "$slot_mode metadata missing active partition entries: ${missing_active[*]}"
    fi
    if [[ ${#missing_inactive[@]} -gt 0 ]]; then
      die "$slot_mode metadata missing inactive _${inactive_slot} partition entries: ${missing_inactive[*]}"
    fi
  fi
}

_validate_super_profile() {
  local missing=()
  [[ -n "${SUPER_SIZE:-}" ]] || missing+=("SUPER_SIZE")
  if [[ "${SUPER_SLOT_MODE:-A}" == "A" ]]; then
    [[ -n "${DYNAMIC_PARTITION_GROUP_NAME:-}" ]] || missing+=("DYNAMIC_PARTITION_GROUP_NAME")
  fi
  [[ -n "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]] || missing+=("DYNAMIC_PARTITION_GROUP_SIZE")
  [[ -n "${SUPER_METADATA_SIZE:-}" ]] || missing+=("SUPER_METADATA_SIZE")
  [[ -n "${SUPER_METADATA_SLOTS:-}" ]] || missing+=("SUPER_METADATA_SLOTS")

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Device profile devices/$DEVICE_CODENAME.conf is missing: ${missing[*]}"
  fi
}

_fail_missing_profile() {
  cat >&2 <<EOF
[ERROR] Could not auto-read super metadata, and no device profile was found.
Create: devices/$DEVICE_CODENAME.conf

Required fields:
SUPER_SIZE=
DYNAMIC_PARTITION_GROUP_NAME=
DYNAMIC_PARTITION_GROUP_SIZE=
SUPER_METADATA_SIZE=
SUPER_METADATA_SLOTS=
SUPER_NAME=super
PARTITION_SUFFIX=

Tip: get exact values from a stock super.img using lpdump, or from the device board config.
EOF
  exit 1
}
