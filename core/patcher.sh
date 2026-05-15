#!/usr/bin/env bash
set -euo pipefail

source "$WORKSPACE/core/dna_patches.sh"

PATCH_ROOT="${PATCH_ROOT:-$OUTPUT/patch_root}"
PATCH_IMAGE_PARTITIONS="${PATCH_IMAGE_PARTITIONS:-system product system_ext vendor mi_ext}"

_partition_img() {
  local part="$1"
  if [[ -s "$EXTRACTED/$part.img" ]]; then
    printf '%s\n' "$EXTRACTED/$part.img"
  elif [[ -s "$EXTRACTED/${part}_a.img" ]]; then
    printf '%s\n' "$EXTRACTED/${part}_a.img"
  else
    return 1
  fi
}

_extract_erofs_image() {
  local img="$1"
  local out="$2"
  local raw="$img"

  rm -rf "$out"
  mkdir -p "$out"

  local desc
  desc="$(file "$img" 2>/dev/null || true)"
  if grep -qi 'Android sparse image' <<<"$desc"; then
    require_tool simg2img
    raw="$out.__raw.img"
    simg2img "$img" "$raw"
  fi

  require_tool fsck.erofs
  log "Extract EROFS: $img -> $out"
  fsck.erofs --extract="$out" "$raw" > "$LOGS/erofs-extract-$(basename "$img").log" 2>&1 \
    || die "Failed to extract EROFS image: $img"

  [[ "$raw" == "$img" ]] || rm -f "$raw"
}

_repack_erofs_image() {
  local part="$1"
  local root="$2"
  local img="$3"
  local tmp="$OUTPUT/${part}.patched.img"

  require_tool mkfs.erofs
  rm -f "$tmp"

  log "Repack EROFS partition: $part"
  mkfs.erofs -zlz4hc,9 --mount-point "/$part" "$tmp" "$root" \
    > "$LOGS/erofs-repack-$part.log" 2>&1 \
    || die "Failed to repack EROFS partition: $part. See $LOGS/erofs-repack-$part.log"

  [[ -s "$tmp" ]] || die "Patched image is empty: $tmp"
  mv -f "$tmp" "$img"

  local size
  size="$(file_size "$img")"
  awk -F '\t' -v OFS='\t' -v p="$part" -v sz="$size" '
    $1 == p { $3 = sz }
    { print }
  ' "$WORKSPACE/partitions.tsv" > "$WORKSPACE/partitions.tsv.tmp"
  mv -f "$WORKSPACE/partitions.tsv.tmp" "$WORKSPACE/partitions.tsv"

  log "Updated partition size: $part=$size"
}

_prepare_patch_root() {
  rm -rf "$PATCH_ROOT"
  mkdir -p "$PATCH_ROOT" "$LOGS"

  local part img fs
  for part in $PATCH_IMAGE_PARTITIONS; do
    img="$(_partition_img "$part" 2>/dev/null || true)"
    [[ -n "$img" ]] || {
      log "Patch partition not present, skip: $part"
      continue
    }

    fs="$(detect_image_fs_type "$img")"
    if [[ "$fs" != "erofs" ]]; then
      warn "Patch partition is not EROFS, skip: $part fs=$fs"
      continue
    fi

    _extract_erofs_image "$img" "$PATCH_ROOT/$part"
    mkdir -p "$PATCH_ROOT/.extracted"
    : > "$PATCH_ROOT/.extracted/$part"
  done
}

_repack_changed_partitions() {
  [[ -d "$PATCH_ROOT/.changed" ]] || {
    log "No ROM patch changes detected; skipping partition repack"
    return 0
  }

  local marker part img
  for marker in "$PATCH_ROOT/.changed"/*; do
    [[ -e "$marker" ]] || continue
    part="$(basename "$marker")"

    [[ -e "$PATCH_ROOT/.extracted/$part" ]] || {
      warn "Partition changed marker exists but partition was not extracted: $part"
      continue
    }

    img="$(_partition_img "$part" 2>/dev/null || true)"
    [[ -n "$img" ]] || die "Cannot find image for changed partition: $part"

    _repack_erofs_image "$part" "$PATCH_ROOT/$part" "$img"
    deadzone_report_mark_repacked_partition "$part"
  done
}

apply_patches() {
  if [[ "${SKIP_PATCHES:-true}" == "true" || "${PATCH_LEVEL:-none}" == "none" ]]; then
    log "Patches skipped: SKIP_PATCHES=${SKIP_PATCHES:-true}, PATCH_LEVEL=${PATCH_LEVEL:-none}"
    return 0
  fi

  case "${PATCH_LEVEL:-none}" in
    safe|full) ;;
    *) die "Unsupported PATCH_LEVEL for ROM patches: ${PATCH_LEVEL:-}" ;;
  esac

  section "DeadZone Phase 2 Patcher"
  log "ROM region: ${ROM_REGION:-unknown}"
  log "Patch level: ${PATCH_LEVEL:-none}"
  log "Patch image partitions: $PATCH_IMAGE_PARTITIONS"

  _prepare_patch_root
  apply_dna_style_patches_to_root
  _repack_changed_partitions
  write_deadzone_patch_report
}
