#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

FASTBOOT_FLASH_ORDER="apusys audio_dsp boot ccu connsys_bt connsys_gnss connsys_wifi dpm dtbo gpueb gz init_boot lk logo mcf_ota mcupm md1img mvpu_algo pi_img preloader_raw scp spmfw sspm tee vbmeta vbmeta_system vbmeta_vendor vcp vendor_boot super"
ROM_ZIP_COMPRESSION_LEVEL="${ROM_ZIP_COMPRESSION_LEVEL:-9}"

_fastboot_target_for_image() {
  local img="$1"
  local part="${img%.img}"
  if [[ "$part" == "super" ]]; then
    printf 'super'
    return
  fi
  case "${FASTBOOT_SLOT_MODE:-single}" in
    ab_suffix) printf '%s_ab' "$part" ;;
    *) printf '%s' "$part" ;;
  esac
}

_is_vbmeta_image() {
  case "${1%.img}" in
    vbmeta|vbmeta_system|vbmeta_vendor) return 0 ;;
    *) return 1 ;;
  esac
}

_vbmeta_fastboot_flags() {
  printf ''
}

_write_windows_flash_commands() {
  local file="$1"
  local wipe="$2"
  {
    printf '@echo off\r\n'
    printf 'cd %%~dp0\r\n'
    printf 'set fastboot=bin\\windows\\fastboot.exe\r\n'
    printf 'if not exist %%fastboot%% echo %%fastboot%% not found. & pause & exit /B 1\r\n'
    printf 'echo Waiting for device...\r\n'
    printf 'set device=unknown\r\n'
    printf 'for /f "tokens=2" %%%%D in ('\''%%fastboot%% getvar product 2^>^&1 ^| findstr /l /b /c:"product:"'\'') do set device=%%%%D\r\n'
    printf '\r\n'
    printf 'echo Detected device: %%device%%\r\n'
    printf '\r\n'
    if [[ "$wipe" == "true" ]]; then
      printf 'echo WARNING: This will erase metadata and userdata.\r\n'
      printf 'choice /C YN /M "Continue with format data install?"\r\n'
      printf 'if errorlevel 2 exit /B 1\r\n'
    fi
    printf '%%fastboot%% set_active a\r\n'
    local part img target
    for part in $FASTBOOT_FLASH_ORDER; do
      img="$OUTPUT_FINAL/images/$part.img"
      [[ -s "$img" ]] || continue
      if [[ "$part" == "super" ]]; then
        printf '%%fastboot%% flash super images\\super.img\r\n'
      else
        target="$(_fastboot_target_for_image "$part.img")"
        printf '%%fastboot%% flash %s images\\%s.img\r\n' "$target" "$part"
      fi
    done
    if [[ "$wipe" == "true" ]]; then
      printf '%%fastboot%% erase metadata\r\n'
      printf '%%fastboot%% erase userdata\r\n'
    fi
    printf '%%fastboot%% reboot\r\n'
  } > "$file"
  log "Generated Windows flash script: $(basename "$file")"
}

_write_windows_format_data_only() {
  local file="$1"
  {
    printf '@echo off\r\n'
    printf 'cd %%~dp0\r\n'
    printf 'set fastboot=bin\\windows\\fastboot.exe\r\n'
    printf 'if not exist %%fastboot%% echo %%fastboot%% not found. & pause & exit /B 1\r\n'
    printf 'echo WARNING: This will erase metadata and userdata.\r\n'
    printf 'choice /C YN /M "Continue with format data only?"\r\n'
    printf 'if errorlevel 2 exit /B 1\r\n'
    printf '%%fastboot%% set_active a\r\n'
    printf '%%fastboot%% erase metadata\r\n'
    printf '%%fastboot%% erase userdata\r\n'
    printf '%%fastboot%% reboot\r\n'
  } > "$file"
  log "Generated Windows format script: $(basename "$file")"
}

_generate_readme_txt() {
  cat > "$OUTPUT_FINAL/README.txt" <<EOF
DeadZone fastboot package

Build: $BUILD_NAME
Device: $DEVICE_CODENAME
ROM: ${ROM_VERSION:-unknown}

Use windows_install_and_format_data.bat or flash_all.sh for a clean first flash.
Use windows_install_upgrade.bat only when intentionally preserving data.

Never lock the bootloader from this package.
EOF
}

_image_list() {
  find "$OUTPUT/images" -maxdepth 1 -type f -name '*.img' -printf '%f\n' | sort
}

generate_pre_zip_sha256sums() {
  local sums="$OUTPUT_FINAL/sha256sums.txt"

  : > "$sums"
  (
    cd "$OUTPUT_FINAL"

    log "Hashing staged images" >&2
    if find images -type f -name '*.img' -print -quit | grep -q .; then
      find images -type f -name '*.img' -print0 | sort -z | xargs -0 sha256sum
    else
      echo "::error::No images found for sha256" >&2
      exit 1
    fi

    log "Hashing build_info.txt" >&2
    if [[ -f build_info.txt ]]; then
      sha256sum build_info.txt
    else
      echo "::error::build_info.txt missing for sha256" >&2
      exit 1
    fi

  ) > "$sums"

  log "sha256sums generated"
}

generate_final_zip_sha256() {
  local zip_name="$(final_zip_name)"
  local zip_file="$(final_zip_path)"

  [[ -s "$zip_file" ]] || die "Final ZIP missing for sha256: $zip_file"
  log "Hashing final ZIP"
  (cd "$OUTPUT_FINAL" && sha256sum "$zip_name") > "$OUTPUT_FINAL/$zip_name.sha256"
  grep -v "  $zip_name$" "$OUTPUT_FINAL/sha256sums.txt" > "$OUTPUT_FINAL/sha256sums.tmp" 2>/dev/null || true
  mv -f "$OUTPUT_FINAL/sha256sums.tmp" "$OUTPUT_FINAL/sha256sums.txt"
  cat "$OUTPUT_FINAL/$zip_name.sha256" >> "$OUTPUT_FINAL/sha256sums.txt"
  log "sha256sums generated"
}

stage_windows_fastboot_tools() {
  local dest="$OUTPUT_FINAL/bin/windows"
  mkdir -p "$dest"

  if [[ -d "$WORKSPACE/templates/fastboot/deadzone/bin/windows" ]]; then
    cp -f "$WORKSPACE/templates/fastboot/deadzone/bin/windows"/fastboot.exe "$dest/" 2>/dev/null || true
    cp -f "$WORKSPACE/templates/fastboot/deadzone/bin/windows"/AdbWinApi.dll "$dest/" 2>/dev/null || true
    cp -f "$WORKSPACE/templates/fastboot/deadzone/bin/windows"/AdbWinUsbApi.dll "$dest/" 2>/dev/null || true
  fi

  if [[ ! -s "$dest/fastboot.exe" || ! -s "$dest/AdbWinApi.dll" || ! -s "$dest/AdbWinUsbApi.dll" ]]; then
    log "Downloading official Windows platform-tools"
    local tmp zip_file
    tmp="$(mktemp -d)"
    zip_file="$tmp/platform-tools-windows.zip"
    curl -fL "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -o "$zip_file"
    unzip -q "$zip_file" -d "$tmp"
    cp -f "$tmp/platform-tools/fastboot.exe" "$dest/fastboot.exe"
    cp -f "$tmp/platform-tools/AdbWinApi.dll" "$dest/AdbWinApi.dll"
    cp -f "$tmp/platform-tools/AdbWinUsbApi.dll" "$dest/AdbWinUsbApi.dll"
    rm -rf "$tmp"
  fi

  [[ -s "$dest/fastboot.exe" ]] || die "Missing bin/windows/fastboot.exe"
  [[ -s "$dest/AdbWinApi.dll" ]] || die "Missing bin/windows/AdbWinApi.dll"
  [[ -s "$dest/AdbWinUsbApi.dll" ]] || die "Missing bin/windows/AdbWinUsbApi.dll"
}

refresh_build_info() {
  local zip_file="$(final_zip_path)"
  local pd_link gh_link
  pd_link="$(grep '^PIXELDRAIN_URL=' "$OUTPUT_FINAL/upload_links.txt" 2>/dev/null | cut -d= -f2- || true)"
  gh_link="$(grep '^GITHUB_RELEASE_URL=' "$OUTPUT_FINAL/upload_links.txt" 2>/dev/null | cut -d= -f2- || true)"

  {
    echo "Build name: $BUILD_NAME"
    echo "Final ZIP name: $(final_zip_name)"
    echo "Device codename: $DEVICE_CODENAME"
    echo "ROM URL: ${ROM_URL:-unknown}"
    echo "ROM version: ${ROM_VERSION:-unknown}"
    echo "ROM region: ${ROM_REGION:-unknown}"
    echo "Date UTC: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Git commit SHA: ${GITHUB_SHA:-unknown}"
    echo "output_type: $OUTPUT_TYPE"
    echo "fs_mode: $FS_MODE"
    echo "vbmeta_mode: $VBMETA_MODE"
    echo "vbmeta_patch_strategy: ${VBMETA_PATCH_STRATEGY:-unknown}"
    echo "patch_level: $PATCH_LEVEL"
    echo "super.img size: $(file_size "$OUTPUT/images/super.img")"
    if [[ -f "$zip_file" ]]; then
      echo "final ZIP size: $(file_size "$zip_file")"
    else
      echo "final ZIP size: pending"
    fi
    echo "Images included:"
    _image_list | sed 's/^/- /'
    echo "PixelDrain link: ${pd_link:-not uploaded}"
    echo "GitHub Release link: ${gh_link:-not uploaded}"
  } > "$OUTPUT_FINAL/build_info.txt"
}

create_logs_archive() {
  [[ -d "$LOGS" ]] || return 0
  log "Creating logs sidecar archive"
  rm -f "$OUTPUT_FINAL/logs.zip"
  if ! (cd "$LOGS" && zip -r -q "$OUTPUT_FINAL/logs.zip" .); then
    warn "Could not create logs.zip sidecar"
    rm -f "$OUTPUT_FINAL/logs.zip"
    return 0
  fi
  [[ -s "$OUTPUT_FINAL/logs.zip" ]] && log "logs.zip created: $OUTPUT_FINAL/logs.zip"
}

package_fastboot_zip() {
  log "Packaging fastboot ZIP"
  log "Checking zip tool"
  require_tool zip
  require_tool unzip
  require_tool curl
  log "Checking sha256sum tool"
  require_tool sha256sum
  case "$ROM_ZIP_COMPRESSION_LEVEL" in
    0|1|2|3|4|5|6|7|8|9) ;;
    *) die "ROM_ZIP_COMPRESSION_LEVEL must be 0-9, got $ROM_ZIP_COMPRESSION_LEVEL" ;;
  esac

  local zip_name="$(final_zip_name)"
  local zip_file="$(final_zip_path)"

  [[ -d "$OUTPUT/images" ]] || die "Missing directory: $OUTPUT/images"
  [[ -s "$OUTPUT/images/super.img" ]] || die "Missing required package image: $OUTPUT/images/super.img"
  [[ -s "$OUTPUT/images/vbmeta.img" ]] || die "Missing required package image: $OUTPUT/images/vbmeta.img"
  mkdir -p "$OUTPUT_FINAL" || die "Could not create output_final: $OUTPUT_FINAL"

  rm -rf "$OUTPUT_FINAL/images" "$OUTPUT_FINAL/logs" "$OUTPUT_FINAL/bin"
  rm -f "$OUTPUT_FINAL/logs.zip"
  mkdir -p "$OUTPUT_FINAL/images"
  log "Staging Windows platform-tools"
  stage_windows_fastboot_tools
  log "Staging images"
  if ! cp -al "$OUTPUT/images"/*.img "$OUTPUT_FINAL/images/" 2>/dev/null; then
    warn "Hardlink image staging failed; falling back to copy"
    cp -f "$OUTPUT/images"/*.img "$OUTPUT_FINAL/images/" || die "Failed to stage fastboot images"
  fi
  find "$OUTPUT_FINAL/images" -maxdepth 1 -type f -name '*.img' | grep -q . || die "No images were staged"
  [[ -s "$OUTPUT_FINAL/images/super.img" ]] || die "Staged images missing super.img"
  [[ -s "$OUTPUT_FINAL/images/vbmeta.img" ]] || die "Staged images missing vbmeta.img"

  log "Generating Windows flash scripts"
  _write_windows_flash_commands "$OUTPUT_FINAL/windows_install_and_format_data.bat" true
  _write_windows_flash_commands "$OUTPUT_FINAL/windows_install_upgrade.bat" false
  _write_windows_format_data_only "$OUTPUT_FINAL/windows_format_data_only.bat"
  rm -f "$OUTPUT_FINAL/README.txt"
  log "Generating build_info"
  refresh_build_info
  [[ -s "$OUTPUT_FINAL/build_info.txt" ]] || die "build_info.txt was not created"
  create_logs_archive

  rm -f "$zip_file"
  log "Creating ZIP"
  df -h || true
  du -sh "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" "$INPUT" "$EXTRACTED" 2>/dev/null || true
  local staged_size
  staged_size="$(du -sh "$OUTPUT_FINAL/images" "$OUTPUT_FINAL/bin" 2>/dev/null | awk '{sum=sum" "$1} END {print sum}' || true)"
  if ! (
    cd "$OUTPUT_FINAL" &&
      zip -r "-${ROM_ZIP_COMPRESSION_LEVEL}" "$zip_name" \
        bin \
        images \
        windows_install_and_format_data.bat \
        windows_install_upgrade.bat \
        windows_format_data_only.bat
  ); then
    df -h || true
    du -sh "$OUTPUT" "$OUTPUT/images" "$OUTPUT_FINAL" 2>/dev/null || true
    die "zip packaging failed"
  fi
  [[ -s "$zip_file" ]] || die "Final fastboot ZIP was not created"
  log "Staged size:$staged_size"
  log "Compression level: $ROM_ZIP_COMPRESSION_LEVEL"
  log "ZIP created: $zip_file size=$(file_size "$zip_file") bytes ($(human_size "$zip_file"))"
  log "Refreshing final build_info"
  refresh_build_info
  log "Refreshing final checksums"
  generate_pre_zip_sha256sums
  [[ -s "$OUTPUT_FINAL/sha256sums.txt" ]] || die "sha256sums.txt was not created"
  generate_final_zip_sha256
}
