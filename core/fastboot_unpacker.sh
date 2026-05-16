#!/usr/bin/env bash
# core/fastboot_unpacker.sh
# Handles extraction of Fastboot ZIPs (images/super.img layout).
# Detects the real super.img size and unpacks all partition images.
# LF normalized for GitHub raw
set -euo pipefail

# ---------------------------------------------------------------------------
# _detect_fastboot_zip_layout
#   Inspects a ZIP and returns "fastboot" if it contains images/super.img,
#   "flat_fastboot" if super.img is at the root, or "unknown".
# ---------------------------------------------------------------------------
_detect_fastboot_zip_layout() {
  local zip="$1"
  require_tool unzip

  if unzip -l "$zip" 2>/dev/null | grep -qE '^\s+[0-9]+\s.*images/super\.img'; then
    printf 'fastboot'
  elif unzip -l "$zip" 2>/dev/null | grep -qE '^\s+[0-9]+\s.*super\.img'; then
    printf 'flat_fastboot'
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# extract_fastboot_zip
#   Extracts all *.img files from a Fastboot ZIP into $EXTRACTED.
#   Supports two layouts:
#     - images/super.img  (standard DeadZone/MI fastboot package layout)
#     - super.img         (flat layout, e.g. some MTK bundles)
#   Sets:
#     FASTBOOT_SUPER_REAL_SIZE  — byte size of the extracted super.img
#     FASTBOOT_LAYOUT           — "fastboot" | "flat_fastboot"
# ---------------------------------------------------------------------------
extract_fastboot_zip() {
  require_tool unzip
  require_tool file

  local zip="$ROM_FILE"
  [[ -f "$zip" ]] || die "Fastboot ZIP not found: $zip"
  [[ -r "$zip" ]] || die "Fastboot ZIP is not readable: $zip"

  local layout
  layout="$(_detect_fastboot_zip_layout "$zip")"
  export FASTBOOT_LAYOUT="$layout"

  log "Fastboot ZIP layout detected: $layout"

  case "$layout" in
    fastboot)
      log "Extracting images/*.img from fastboot ZIP"
      unzip -q -o "$zip" "images/*.img" -d "$INPUT/fastboot_extract" \
        2>&1 | tee "$LOGS/fastboot_unzip.log" || die "Failed to extract images/*.img from fastboot ZIP"
      # Move all images flat into $EXTRACTED
      find "$INPUT/fastboot_extract/images" -maxdepth 1 -type f -name '*.img' \
        -exec cp -f {} "$EXTRACTED/" \;
      ;;
    flat_fastboot)
      log "Extracting *.img from flat fastboot ZIP"
      unzip -q -o "$zip" "*.img" -d "$INPUT/fastboot_extract" \
        2>&1 | tee "$LOGS/fastboot_unzip.log" || die "Failed to extract *.img from fastboot ZIP"
      find "$INPUT/fastboot_extract" -maxdepth 2 -type f -name '*.img' \
        -exec cp -f {} "$EXTRACTED/" \;
      ;;
    *)
      die "Cannot determine fastboot ZIP layout for: $(basename "$zip"). Expected images/super.img or super.img at root."
      ;;
  esac

  local super_img="$EXTRACTED/super.img"
  [[ -f "$super_img" ]] || die "super.img was not found in fastboot ZIP after extraction"
  [[ -s "$super_img" ]] || die "super.img extracted from fastboot ZIP is empty"

  local real_size
  real_size="$(file_size "$super_img")"
  export FASTBOOT_SUPER_REAL_SIZE="$real_size"

  log "super.img extracted successfully"
  log "super.img real size: $real_size bytes ($(human_size "$super_img"))"

  # Sanity: verify it looks like a valid super (Android sparse or raw LP)
  local magic
  magic="$(file "$super_img")"
  if printf '%s\n' "$magic" | grep -qiE 'Android sparse|Linux.*partition'; then
    log "super.img magic check passed: $magic"
  else
    warn "super.img magic may be unexpected (not sparse/raw LP): $magic"
    warn "Proceeding anyway — verify manually with lpdump if build fails."
  fi
}

# ---------------------------------------------------------------------------
# read_super_real_size_from_image
#   After extract_fastboot_zip, sets SUPER_SIZE to the byte-exact size of the
#   extracted super.img — overriding any device profile value so lpmake
#   receives the correct --device super:<size> for this exact ROM.
#   Also reads metadata from lpdump when available to get group sizes.
# ---------------------------------------------------------------------------
read_super_real_size_from_image() {
  local super_img="$EXTRACTED/super.img"

  [[ -f "$super_img" ]] || die "super.img not found at $super_img — run extract_fastboot_zip first"

  local real_size
  real_size="$(file_size "$super_img")"

  if [[ "${SUPER_SIZE:-0}" != "$real_size" ]]; then
    log "Overriding SUPER_SIZE from device profile (${SUPER_SIZE:-unset}) → real image size ($real_size bytes)"
    export SUPER_SIZE="$real_size"
  else
    log "SUPER_SIZE matches real image: $real_size bytes"
  fi

  # Try to read LP metadata directly — gives exact group sizes and slot mode
  if command -v lpdump >/dev/null 2>&1; then
    log "Reading LP metadata from extracted super.img via lpdump"
    lpdump "$super_img" > "$LOGS/lpdump_source_super.log" 2>&1 || {
      warn "lpdump failed on source super.img — will rely on device profile for group sizes"
      return 0
    }

    local meta_group_size meta_metadata_size meta_metadata_slots
    meta_group_size="$(awk '/Maximum size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' \
      "$LOGS/lpdump_source_super.log" || true)"
    meta_metadata_size="$(awk '/Metadata max size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' \
      "$LOGS/lpdump_source_super.log" || true)"
    meta_metadata_slots="$(awk '/Metadata slot count:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' \
      "$LOGS/lpdump_source_super.log" || true)"

    if [[ -n "$meta_group_size" ]]; then
      log "lpdump group size from source super: $meta_group_size"
      # Only override if profile didn't set one
      if [[ -z "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]]; then
        export DYNAMIC_PARTITION_GROUP_SIZE="$meta_group_size"
        log "Set DYNAMIC_PARTITION_GROUP_SIZE=$DYNAMIC_PARTITION_GROUP_SIZE from source super lpdump"
      fi
    fi
    if [[ -n "$meta_metadata_size" && -z "${SUPER_METADATA_SIZE:-}" ]]; then
      export SUPER_METADATA_SIZE="$meta_metadata_size"
      log "Set SUPER_METADATA_SIZE=$SUPER_METADATA_SIZE from source super lpdump"
    fi
    if [[ -n "$meta_metadata_slots" && -z "${SUPER_METADATA_SLOTS:-}" ]]; then
      export SUPER_METADATA_SLOTS="$meta_metadata_slots"
      log "Set SUPER_METADATA_SLOTS=$SUPER_METADATA_SLOTS from source super lpdump"
    fi
  else
    warn "lpdump not available — SUPER_SIZE set from file size; group sizes from device profile"
  fi
}

# ---------------------------------------------------------------------------
# detect_partition_images_from_fastboot
#   After extracting a fastboot ZIP the images are already raw (not payload).
#   This function builds partitions.tsv the same way unpacker.sh does for OTA,
#   but skips payload-dumper-go since images are already present.
#   Only processes partitions listed in $DYNAMIC_PARTITIONS.
#   Sparse images are converted to raw with simg2img.
# ---------------------------------------------------------------------------
detect_partition_images_from_fastboot() {
  require_tool file

  : > "$WORKSPACE/partitions.tsv"
  : > "$LOGS/partitions.log"
  log "Cataloguing dynamic partition images from fastboot extraction"

  local part img size format fs raw_img
  local extracted=()

  for part in $DYNAMIC_PARTITIONS; do
    # Fastboot images may come with _a suffix or without
    local candidate=""
    for try in "$EXTRACTED/${part}_a.img" "$EXTRACTED/$part.img"; do
      [[ -f "$try" ]] && { candidate="$try"; break; }
    done

    if [[ -z "$candidate" ]]; then
      warn "Dynamic partition image not found in fastboot ZIP: $part — skipping"
      continue
    fi

    img="$candidate"
    size="$(file_size "$img")"
    format="$(_detect_image_container_fb "$img")"
    fs="$(_detect_image_filesystem_fb "$img" "$format")"

    if [[ "$format" == "sparse" ]]; then
      raw_img="$EXTRACTED/${part}.raw.img"
      log "Converting sparse → raw for lpmake: $part"
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

  if [[ ${#extracted[@]} -eq 0 ]]; then
    die "No dynamic partition images were found in the fastboot ZIP for partitions: $DYNAMIC_PARTITIONS"
  fi
  log "Catalogued fastboot partitions: ${extracted[*]}"
}

_detect_image_container_fb() {
  local img="$1"
  if file "$img" | grep -qi "Android sparse"; then
    printf 'sparse'
  else
    printf 'raw'
  fi
}

_detect_image_filesystem_fb() {
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
