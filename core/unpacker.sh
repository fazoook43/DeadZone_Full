#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

_payload_partition_csv() {
  local csv=""
  local part
  for part in $DYNAMIC_PARTITIONS; do
    csv="${csv:+$csv,}$part"
  done
  printf '%s' "$csv"
}

extract_payload_partitions() {
  require_tool payload-dumper-go
  require_tool unzip

  local payload="$INPUT/payload.bin"
  local unzip_dir="$INPUT/ota"
  local ext="${ROM_FILE##*.}"
  ext="${ext,,}"

  case "$ext" in
    zip)
      log "Extracting payload.bin from OTA zip"
      mkdir -p "$unzip_dir"
      unzip -q "$ROM_FILE" "payload.bin" -d "$unzip_dir" || die "payload.bin was not found in OTA zip"
      payload="$unzip_dir/payload.bin"
      ;;
    bin)
      payload="$ROM_FILE"
      ;;
    *)
      die "Unsupported ROM input. Phase 1 expects an OTA zip with payload.bin or a payload.bin file."
      ;;
  esac

  [[ -f "$payload" ]] || die "payload.bin not found"
  log "Dumping dynamic partitions with payload-dumper-go"
  payload-dumper-go -o "$EXTRACTED" -p "$(_payload_partition_csv)" "$payload" 2>&1 | tee "$LOGS/payload-dumper-go.log"
}

extract_payload_all_images() {
  require_tool payload-dumper-go
  require_tool unzip

  local payload="$INPUT/payload.bin"
  local unzip_dir="$INPUT/ota"
  local ext="${ROM_FILE##*.}"
  ext="${ext,,}"

  case "$ext" in
    zip)
      log "Extracting payload.bin from OTA zip"
      mkdir -p "$unzip_dir"
      unzip -q "$ROM_FILE" "payload.bin" -d "$unzip_dir" || die "payload.bin was not found in OTA zip"
      payload="$unzip_dir/payload.bin"
      ;;
    bin)
      payload="$ROM_FILE"
      ;;
    *)
      die "Unsupported ROM input. Expected an OTA zip with payload.bin or a payload.bin file."
      ;;
  esac

  [[ -f "$payload" ]] || die "payload.bin not found"
  [[ -r "$payload" ]] || die "payload.bin is not readable"
  log "Dumping all payload images with payload-dumper-go"
  payload-dumper-go -o "$EXTRACTED" "$payload" 2>&1 | tee "$LOGS/payload-dumper-go.log"
}

detect_partition_images() {
  require_tool file
  : > "$WORKSPACE/partitions.tsv"
  : > "$LOGS/partitions.log"
  log "Detecting extracted partition images"

  local extracted=()
  local part img size format fs raw_img
  for part in $DYNAMIC_PARTITIONS; do
    img="$EXTRACTED/$part.img"
    if [[ ! -f "$img" ]]; then
      die "Required dynamic partition image is missing after payload dump: $part.img"
    fi

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
    printf '%s\t%s\t%s\t%s\t%s\n' "$part" "$img" "$size" "$format" "$fs" >> "$WORKSPACE/partitions.tsv"
    printf '%-16s size=%-14s container=%-8s fs=%s\n' "$part" "$size" "$format" "$fs" | tee -a "$LOGS/partitions.log"
  done

  [[ ${#extracted[@]} -gt 0 ]] || die "No requested dynamic partitions were extracted from payload.bin"
  log "Extracted partitions: ${extracted[*]}"
}

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
