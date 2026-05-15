#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

_list_words() {
  local value="${1:-}"
  printf '%s\n' $value
}

collect_fastboot_images() {
  mkdir -p "$OUTPUT/images" "$LOGS"
  : > "$LOGS/collected_images.txt"

  local required="${REQUIRED_FASTBOOT_IMAGES:-boot.img init_boot.img vendor_boot.img vbmeta.img}"
  local optional="${OPTIONAL_FASTBOOT_IMAGES:-dtbo.img vbmeta_system.img vbmeta_vendor.img vendor_kernel_boot.img recovery.img logo.img lk.img tee.img scp.img spmfw.img audio_dsp.img dpm.img mcupm.img pi_img.img gz.img md1img.img my_bigball.img my_carrier.img my_company.img my_engineering.img my_heytap.img my_manifest.img my_preload.img my_product.img my_region.img my_stock.img}"
  local img src

  for img in $required; do
    src="$EXTRACTED/$img"
    [[ -s "$src" ]] || die "Required fastboot image is missing: $img"
    cp -f "$src" "$OUTPUT/images/$img"
    printf 'required\t%s\n' "$img" | tee -a "$LOGS/collected_images.txt"
  done

  for img in $optional; do
    src="$EXTRACTED/$img"
    if [[ -s "$src" ]]; then
      cp -f "$src" "$OUTPUT/images/$img"
      printf 'optional\t%s\n' "$img" | tee -a "$LOGS/collected_images.txt"
    fi
  done

  [[ -s "$OUTPUT/images/super.img" ]] || die "super.img is missing from output/images"
  printf 'required\t%s\n' "super.img" | tee -a "$LOGS/collected_images.txt"
}
