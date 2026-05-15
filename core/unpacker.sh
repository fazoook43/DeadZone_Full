#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

# ---------------------------------------------------------------------------
# _payload_partition_csv — build comma-separated list for payload-dumper-go -p
# ---------------------------------------------------------------------------

_payload_partition_csv() {
  local csv=""
  local part
  for part in $DYNAMIC_PARTITIONS; do
    csv="${csv:+$csv,}$part"
  done
  printf '%s' "$csv"
}

# ---------------------------------------------------------------------------
# _resolve_payload — locate payload.bin from a ZIP or raw .bin file
#   Sets: local variable `payload` in caller via nameref
# ---------------------------------------------------------------------------

_resolve_payload() {
  local -n _out_payload="$1"
  local ext="${ROM_FILE##*.}"
  ext="${ext,,}"

  local unzip_dir="$INPUT/ota"

  case "$ext" in
    zip)
      log "Extracting payload.bin from OTA zip"
      mkdir -p "$unzip_dir"
      unzip -q "$ROM_FILE" "payload.bin" -d "$unzip_dir" || die "payload.bin was not found in OTA zip"
      _out_payload="$unzip_dir/payload.bin"
      ;;
    bin)
      _out_payload="$ROM_FILE"
      ;;
    *)
      die "Unsupported ROM input. Expected an OTA zip with payload.bin or a payload.bin file."
      ;;
  esac

  [[ -f "$_out_payload" ]] || die "payload.bin not found at: $_out_payload"
  [[ -r "$_out_payload" ]] || die "payload.bin is not readable: $_out_payload"
}

# ---------------------------------------------------------------------------
# extract_payload_partitions — dump only DYNAMIC_PARTITIONS
# ---------------------------------------------------------------------------

extract_payload_partitions() {
  require_tool payload-dumper-go
  require_tool unzip

  local payload=""
  _resolve_payload payload

  log "Dumping dynamic partitions with payload-dumper-go"
  payload-dumper-go -o "$EXTRACTED" -p "$(_payload_partition_csv)" "$payload" \
    2>&1 | tee "$LOGS/payload-dumper-go.log"
}

# ---------------------------------------------------------------------------
# extract_payload_all_images — dump every image in payload.bin
# ---------------------------------------------------------------------------

extract_payload_all_images() {
  require_tool payload-dumper-go
  require_tool unzip

  local payload=""
  _resolve_payload payload

  log "Dumping all payload images with payload-dumper-go"
  payload-dumper-go -o "$EXTRACTED" "$payload" \
    2>&1 | tee "$LOGS/payload-dumper-go.log"
}

# ---------------------------------------------------------------------------
# detect_partition_images
#
#  Scans EXTRACTED for each partition listed in DYNAMIC_PARTITIONS.
#  Handles three naming conventions produced by different payload-dumper-go
#  versions and OTA types:
#
#    A-only  :  system.img
#    A/B,VAB :  system_a.img   (active)  +  system_b.img  (inactive, optional)
#    Legacy  :  system_a.img   with no  system.img
#
#  Writes $WORKSPACE/partitions.tsv with columns:
#    part  img  size  container  fs
#
#  For A/B and VAB devices the ACTIVE slot image is always the primary row.
#  Inactive-slot images are handled in repacker.sh.
# ---------------------------------------------------------------------------

detect_partition_images() {
  require_tool file
  : > "$WORKSPACE/partitions.tsv"
  : > "$LOGS/partitions.log"
  log "Detecting extracted partition images (SUPER_SLOT_MODE=${SUPER_SLOT_MODE:-?})"

  # Determine active-slot suffix (e.g. "_a") for A/B & VAB
  local active_suffix=""
  case "${SUPER_SLOT_MODE:-A}" in
    AB|VAB) active_suffix="_${SUPER_ACTIVE_SLOT:-a}" ;;
    A)      active_suffix="" ;;
    *)      die "detect_partition_images: unsupported SUPER_SLOT_MODE=$SUPER_SLOT_MODE" ;;
  esac

  local extracted=()
  local part img size format fs raw_img

  for part in $DYNAMIC_PARTITIONS; do
    img=""

    # --- locate the image file -------------------------------------------------
    if [[ -f "$EXTRACTED/${part}${active_suffix}.img" ]]; then
      # Preferred: matches slot convention  (system_a.img for AB/VAB, system.img for A)
      img="$EXTRACTED/${part}${active_suffix}.img"
    elif [[ -z "$active_suffix" && -f "$EXTRACTED/${part}_a.img" ]]; then
      # A-only profile but payload-dumper-go output _a suffixes — remap
      img="$EXTRACTED/${part}_a.img"
      log "A-only remap: using ${part}_a.img as ${part}.img for partition $part"
    elif [[ -n "$active_suffix" && -f "$EXTRACTED/${part}.img" ]]; then
      # AB/VAB profile but payload is A-only style — auto-upgrade detection
      img="$EXTRACTED/${part}.img"
      log "Slot-mode mismatch: found $part.img (no suffix) for AB/VAB device — treating as active slot"
    else
      die "Required dynamic partition image is missing after payload dump: $part${active_suffix}.img"
    fi
    # --------------------------------------------------------------------------

    size="$(file_size "$img")"
    format="$(_detect_image_container "$img")"
    fs="$(_detect_image_filesystem "$img" "$format")"

    if [[ "$format" == "sparse" ]]; then
      raw_img="$EXTRACTED/${part}.raw.img"
      log "Converting sparse image to raw for lpmake: $part"
      simg2img "$img" "$raw_img" || die "simg2img failed for $part"
      img="$raw_img"
      size="$(file_size "$img")"
    fi

    extracted+=("$part")
    printf '%s\t%s\t%s\t%s\t%s\n' "$part" "$img" "$size" "$format" "$fs" \
      >> "$WORKSPACE/partitions.tsv"
    printf '%-20s size=%-14s container=%-8s fs=%s\n' \
      "$part" "$size" "$format" "$fs" | tee -a "$LOGS/partitions.log"
  done

  [[ ${#extracted[@]} -gt 0 ]] || \
    die "No requested dynamic partitions were extracted from payload.bin"
  log "Extracted partitions: ${extracted[*]}"
}

# ---------------------------------------------------------------------------
# Internal: image format & filesystem probes
# ---------------------------------------------------------------------------

_detect_image_container() {
  local img="$1"
  if file "$img" | grep -qi "Android sparse"; then
    printf 'sparse'
  else
    printf 'raw'
  fi
}

_detect_image_filesystem() {
  local img="$1"
  local container="$2"
  local probe="$img"
  local tmp=""

  if [[ "$container" == "sparse" ]]; then
    require_tool simg2img
    tmp="$LOGS/$(basename "$img").raw.probe"
    simg2img "$img" "$tmp" >/dev/null 2>&1 || { printf 'unknown'; return; }
    probe="$tmp"
  fi

  local desc
  desc="$(file "$probe")"
  rm -f "$tmp"

  if grep -qi "EROFS" <<<"$desc"; then
    printf 'erofs'
  elif grep -qi "ext4" <<<"$desc"; then
    printf 'ext4'
  else
    printf 'unknown'
  fi
}
