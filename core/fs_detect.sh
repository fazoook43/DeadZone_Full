#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

detect_image_fs_type() {
  local img="$1"
  local desc
  desc="$(file "$img" 2>/dev/null || true)"

  if grep -qi "EROFS" <<<"$desc"; then
    printf 'erofs'
  elif grep -qi "ext4" <<<"$desc"; then
    printf 'ext4'
  else
    printf 'unknown'
  fi
}

detect_dynamic_filesystems() {
  require_tool file
  : > "$LOGS/filesystems.txt"

  local part img fs
  for part in $DYNAMIC_PARTITIONS; do
    img="$EXTRACTED/$part.img"
    [[ -f "$img" ]] || continue
    fs="$(detect_image_fs_type "$img")"
    printf '%s\t%s\n' "$part" "$fs" | tee -a "$LOGS/filesystems.txt"

    if [[ "$FS_MODE" == "erofs" && "$fs" == "erofs" ]]; then
      log "Preserving stock EROFS image: $part"
    elif [[ "$FS_MODE" == "erofs" && "$PATCH_LEVEL" == "none" ]]; then
      log "Preserving stock $fs image without conversion: $part"
    fi
  done
}
