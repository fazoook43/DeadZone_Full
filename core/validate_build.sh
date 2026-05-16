#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

validate_super_zst() {
  [[ -s "$OUTPUT/images/super.img" ]] || die "output/images/super.img is missing or empty"
  [[ -s "$OUTPUT/super.img.zst" ]] || die "output/super.img.zst is missing or empty"
}

_check_no_crlf() {
  local file
  while IFS= read -r -d '' file; do
    if grep -Iq . "$file" && grep -q $'\r' "$file"; then
      die "CRLF detected in shell script: $file"
    fi
  done < <(find "$WORKSPACE" -path "$WORKSPACE/.git" -prune -o -type f -name '*.sh' -print0)
}

_check_shell_syntax() {
  local file
  while IFS= read -r -d '' file; do
    bash -n "$file" || die "Shell syntax check failed: $file"
  done < <(find "$WORKSPACE" -path "$WORKSPACE/.git" -prune -o -type f -name '*.sh' -print0)
}

_check_no_secret_leaks() {
  local secret
  for secret in "${PIXELDRAIN_API_KEY:-}" "${TELEGRAM_BOT_TOKEN:-}" "${TELEGRAM_CHAT_ID:-}" "${GITHUB_TOKEN:-}"; do
    [[ -n "$secret" ]] || continue
    if grep -R --binary-files=without-match -F "$secret" "$LOGS" "$OUTPUT_FINAL" >/dev/null 2>&1; then
      die "A configured secret appears in generated logs or output files"
    fi
  done
}

validate_build() {
  local zip_file="$(final_zip_path)"

  [[ -s "$OUTPUT/images/super.img" ]] || die "output/images/super.img is missing or empty"
  if [[ "${SUPER_OUTPUT_FORMAT:-sparse}" == "sparse" ]]; then
    [[ -s "$LOGS/super_metadata.img" ]] || die "Sparse super metadata validation image is missing"
    [[ -s "$LOGS/lpdump_super.txt" ]] || die "Sparse super lpdump validation log is missing"
  else
    require_tool lpdump
    lpdump "$OUTPUT/images/super.img" >/dev/null 2>&1 || die "lpdump validation failed"
  fi

  if [[ "${SUPER_SLOT_MODE:-A}" == "AB" || "${SUPER_SLOT_MODE:-A}" == "VAB" ]]; then
    local part active_slot inactive_slot
    active_slot="${SUPER_ACTIVE_SLOT:-a}"
    case "$active_slot" in
      a) inactive_slot="b" ;;
      b) inactive_slot="a" ;;
      *) die "Unsupported SUPER_ACTIVE_SLOT=$active_slot" ;;
    esac
    for part in $DYNAMIC_PARTITIONS; do
      grep -q "${part}_${active_slot}" "$LOGS/lpdump_super.txt" || die "${SUPER_SLOT_MODE:-AB} metadata missing active partition entry: ${part}_${active_slot}"
      grep -q "${part}_${inactive_slot}" "$LOGS/lpdump_super.txt" || die "${SUPER_SLOT_MODE:-AB} metadata missing inactive partition entry: ${part}_${inactive_slot}"
    done
  fi

  local img
  for img in ${REQUIRED_FASTBOOT_IMAGES:-boot.img init_boot.img vendor_boot.img vbmeta.img}; do
    [[ -s "$OUTPUT/images/$img" ]] || die "Required image missing: output/images/$img"
  done

  [[ -s "$zip_file" ]] || die "Final fastboot ZIP is missing or empty: $zip_file"
  [[ -s "$OUTPUT_FINAL/sha256sums.txt" ]] || die "sha256sums.txt is missing"
  [[ -s "$OUTPUT_FINAL/build_info.txt" ]] || die "build_info.txt is missing"
  [[ -d "$OUTPUT_FINAL/images" ]] || die "Final images folder is missing"

  for file in windows_install_and_format_data.bat windows_install_upgrade.bat windows_format_data_only.bat; do
    [[ -s "$OUTPUT_FINAL/$file" ]] || die "Missing package file: $file"
  done
  [[ -s "$OUTPUT_FINAL/bin/windows/fastboot.exe" ]] || die "Missing package file: bin/windows/fastboot.exe"
  [[ -s "$OUTPUT_FINAL/bin/windows/AdbWinApi.dll" ]] || die "Missing package file: bin/windows/AdbWinApi.dll"
  [[ -s "$OUTPUT_FINAL/bin/windows/AdbWinUsbApi.dll" ]] || die "Missing package file: bin/windows/AdbWinUsbApi.dll"
  [[ -s "$OUTPUT_FINAL/images/vbmeta.img" ]] || die "Final ZIP staging is missing images/vbmeta.img"

  if [[ "${VBMETA_MODE:-0}" == "3" && "${VBMETA_PATCH_STRATEGY:-binary}" == "binary" ]]; then
    local vbmeta_img vbmeta_name vbmeta_after
    for vbmeta_img in ${VBMETA_IMAGES:-vbmeta.img vbmeta_system.img vbmeta_vendor.img}; do
      [[ -s "$OUTPUT/images/$vbmeta_img" ]] || continue
      vbmeta_name="${vbmeta_img%.img}"
      vbmeta_after="$LOGS/vbmeta_${vbmeta_name}_after.txt"
      [[ -s "$vbmeta_after" ]] || die "Missing vbmeta after log: $vbmeta_after"
      grep -q 'Flags: 3' "$vbmeta_after" || die "vbmeta binary patch validation missing Flags: 3 for $vbmeta_img"
    done
    ! grep -q -- '--disable-verity --disable-verification' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format flash script must not contain vbmeta disable flags"
    ! grep -q -- '--disable-verity --disable-verification' "$OUTPUT_FINAL/windows_install_upgrade.bat" || die "Windows upgrade flash script must not contain vbmeta disable flags"
    ! grep -q -- 'fastboot -w' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format flash script must not contain fastboot -w"
    ! grep -q -- 'fastboot -w' "$OUTPUT_FINAL/windows_install_upgrade.bat" || die "Windows upgrade flash script must not contain fastboot -w"
    ! grep -q -- 'fastboot -w' "$OUTPUT_FINAL/windows_format_data_only.bat" || die "Windows format-only script must not contain fastboot -w"
    grep -q '%fastboot% flash vbmeta_ab images\\vbmeta.img' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing vbmeta flash command"
    grep -q '%fastboot% flash vbmeta_system_ab images\\vbmeta_system.img' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing vbmeta_system flash command"
    grep -q '%fastboot% flash vbmeta_vendor_ab images\\vbmeta_vendor.img' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing vbmeta_vendor flash command"
    grep -q '%fastboot% flash super images\\super.img' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing super flash command"
    grep -q '%fastboot% erase metadata' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing metadata erase"
    grep -q '%fastboot% erase userdata' "$OUTPUT_FINAL/windows_install_and_format_data.bat" || die "Windows format script missing userdata erase"
  fi

  if ! unzip -t "$zip_file" >/dev/null; then
    die "Final ZIP failed integrity check"
  fi

  local zip_entries="$LOGS/public_zip_entries.txt"
  unzip -Z1 "$zip_file" > "$zip_entries" || die "Could not list final ZIP entries"
  cp -f "$zip_entries" "$LOGS/public_zip_listing.txt" || true

  local required_entry
  for required_entry in \
    "bin/windows/fastboot.exe" \
    "bin/windows/AdbWinApi.dll" \
    "bin/windows/AdbWinUsbApi.dll" \
    "images/super.img" \
    "images/boot.img" \
    "images/init_boot.img" \
    "images/vendor_boot.img" \
    "images/vbmeta.img" \
    "windows_install_and_format_data.bat" \
    "windows_install_upgrade.bat" \
    "windows_format_data_only.bat"; do
    grep -Fxq "$required_entry" "$zip_entries" || die "Final ZIP is missing required public package file: $required_entry"
  done

  local entry rest
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    if [[ "$entry" == /* || "$entry" == *\* || "$entry" == ../* || "$entry" == */../* || "$entry" =~ ^[A-Za-z]: ]]; then
      die "Public ZIP contains unsafe path: $entry"
    fi

    case "$entry" in
      bin/|bin/windows/|images/|\
bin/windows/fastboot.exe|\
bin/windows/AdbWinApi.dll|\
bin/windows/AdbWinUsbApi.dll|\
windows_install_and_format_data.bat|\
windows_install_upgrade.bat|\
windows_format_data_only.bat)
        ;;
      images/*.img)
        rest="${entry#images/}"
        [[ "$rest" != */* ]] || die "Public ZIP contains nested image path: $entry"
        ;;
      *)
        die "Public ZIP contains unexpected entry: $entry"
        ;;
    esac
  done < "$zip_entries"

  _check_shell_syntax
  _check_no_crlf
  _check_no_secret_leaks
}
