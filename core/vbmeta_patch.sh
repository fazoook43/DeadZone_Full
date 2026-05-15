#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

_vbmeta_flag_value() {
  case "$VBMETA_MODE" in
    0) printf '0' ;;
    1) printf '1' ;;
    2) printf '2' ;;
    3) printf '3' ;;
    *) die "Unsupported vbmeta_mode=$VBMETA_MODE" ;;
  esac
}

_patch_vbmeta_with_avbtool() {
  local img="$1"
  local flags="$2"
  local tmp="$img.tmp"
  avbtool make_vbmeta_image \
    --include_descriptors_from_image "$img" \
    --flags "$flags" \
    --padding_size 4096 \
    --output "$tmp" >/dev/null 2>&1 || return 1
  [[ -s "$tmp" ]] || return 1
  mv -f "$tmp" "$img"
}

_patch_vbmeta_header_flags() {
  local img="$1"
  local flags="$2"
  python3 - "$img" "$flags" <<'PY'
import os
import struct
import sys

path = sys.argv[1]
flags = int(sys.argv[2])
original_size = os.path.getsize(path)
with open(path, "r+b") as f:
    magic = f.read(4)
    if magic != b"AVB0":
        raise SystemExit("not an AVB vbmeta image")
    f.seek(0x78)
    f.write(struct.pack(">I", flags))
if os.path.getsize(path) != original_size:
    raise SystemExit("vbmeta patch changed file size")
PY
}

_vbmeta_info_image() {
  local img="$1"
  local out="$2"
  if command -v avbtool >/dev/null 2>&1; then
    avbtool info_image --image "$img" > "$out" 2>&1 || return 1
  else
    python3 - "$img" > "$out" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    magic = f.read(4)
    if magic != b"AVB0":
        raise SystemExit("not an AVB vbmeta image")
    f.seek(0x78)
    flags = struct.unpack(">I", f.read(4))[0]
print("Minimum libavb version: unknown")
print(f"Flags: {flags}")
PY
  fi
}

patch_vbmeta_images() {
  mkdir -p "$LOGS"
  : > "$LOGS/vbmeta_patch.txt"
  local strategy="${VBMETA_PATCH_STRATEGY:-binary}"

  if [[ "$VBMETA_MODE" == "0" ]]; then
    {
      echo "vbmeta patch disabled"
      echo "strategy=none"
      echo "mode=0"
    } | tee -a "$LOGS/vbmeta_patch.txt"
    return
  fi

  log "VBMETA_MODE=$VBMETA_MODE"
  log "VBMETA_PATCH_STRATEGY=$strategy"

  case "$strategy" in
    fastboot_flags)
      local images_found=()
      [[ -s "$OUTPUT/images/vbmeta.img" ]] || die "Required vbmeta image is missing: $OUTPUT/images/vbmeta.img"
      local img path
      for img in ${VBMETA_IMAGES:-vbmeta.img vbmeta_system.img vbmeta_vendor.img}; do
        path="$OUTPUT/images/$img"
        [[ -s "$path" ]] || continue
        images_found+=("$img")
      done
      log "Keeping vbmeta images stock; fastboot scripts will use --disable-verity --disable-verification"
      {
        echo "strategy=fastboot_flags"
        echo "mode=$VBMETA_MODE"
        echo "disable_verity=true"
        echo "disable_verification=true"
        printf 'images_found=%s\n' "${images_found[*]}"
      } | tee -a "$LOGS/vbmeta_patch.txt"
      return 0
      ;;
    binary)
      ;;
    none)
      log "vbmeta patch strategy none; keeping vbmeta images stock"
      {
        echo "strategy=none"
        echo "mode=$VBMETA_MODE"
      } | tee -a "$LOGS/vbmeta_patch.txt"
      return 0
      ;;
    *)
      die "Unknown VBMETA_PATCH_STRATEGY=$strategy"
      ;;
  esac

  local flags img path
  flags="$(_vbmeta_flag_value)"
  for img in ${VBMETA_IMAGES:-vbmeta.img vbmeta_system.img vbmeta_vendor.img}; do
    path="$OUTPUT/images/$img"
    if [[ "$img" == "vbmeta.img" && ! -s "$path" ]]; then
      die "Required vbmeta image is missing: $path"
    fi
    [[ -s "$path" ]] || continue

    local name before_log after_log size_before size_after
    name="${img%.img}"
    before_log="$LOGS/vbmeta_${name}_before.txt"
    after_log="$LOGS/vbmeta_${name}_after.txt"
    size_before="$(file_size "$path")"

    echo "Binary patching $img with flags=$flags" | tee -a "$LOGS/vbmeta_patch.txt"
    _vbmeta_info_image "$path" "$before_log" || die "avbtool info_image failed before patch for $img"
    command -v python3 >/dev/null 2>&1 || die "python3 is required for vbmeta header patching"
    echo "patch_method=avb_header_offset_0x78 image=$img flags=$flags" | tee -a "$LOGS/vbmeta_patch.txt"
    _patch_vbmeta_header_flags "$path" "$flags" >> "$LOGS/vbmeta_patch.txt" 2>&1 || die "binary vbmeta patch failed for $img"
    size_after="$(file_size "$path")"
    [[ "$size_after" == "$size_before" ]] || die "binary vbmeta patch changed file size for $img"
    _vbmeta_info_image "$path" "$after_log" || die "avbtool info_image failed after patch for $img"
    grep -q "Flags: $flags" "$after_log" || die "vbmeta patch validation failed for $img; expected Flags: $flags"
    cat "$after_log" >> "$LOGS/vbmeta_patch.txt"
  done
}
