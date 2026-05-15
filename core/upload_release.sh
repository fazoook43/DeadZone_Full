#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

GITHUB_RELEASE_ASSET_MAX_BYTES="${GITHUB_RELEASE_ASSET_MAX_BYTES:-2147483648}"

_bool_true() {
  case "${1:-false}" in true|True|TRUE|1|yes|YES) return 0 ;; *) return 1 ;; esac
}

_release_tag() {
  printf '%s-%s-%s' "$BUILD_NAME" "$DEVICE_CODENAME" "${ROM_VERSION:-unknown}"
}

_zip_path() {
  final_zip_path
}

_append_upload_link() {
  local key="$1"
  local value="$2"
  touch "$OUTPUT_FINAL/upload_links.txt"
  grep -v "^$key=" "$OUTPUT_FINAL/upload_links.txt" > "$OUTPUT_FINAL/upload_links.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$OUTPUT_FINAL/upload_links.tmp"
  mv -f "$OUTPUT_FINAL/upload_links.tmp" "$OUTPUT_FINAL/upload_links.txt"
}

_github_asset_allowed() {
  local file="$1"
  local size
  [[ -s "$file" ]] || return 1
  size="$(file_size "$file")"
  if (( size >= GITHUB_RELEASE_ASSET_MAX_BYTES )); then
    warn "Skipping GitHub Release upload for $(basename "$file"): size $size exceeds GitHub asset limit $GITHUB_RELEASE_ASSET_MAX_BYTES"
    return 1
  fi
  return 0
}

_zip_too_large_for_github() {
  local zip_file="$(_zip_path)"
  [[ -s "$zip_file" ]] || return 1
  (( $(file_size "$zip_file") >= GITHUB_RELEASE_ASSET_MAX_BYTES ))
}

_pixeldrain_url() {
  grep '^PIXELDRAIN_URL=' "$OUTPUT_FINAL/upload_links.txt" 2>/dev/null | cut -d= -f2- || true
}

_upload_github_release() {
  _bool_true "$CREATE_GITHUB_RELEASE" || {
    warn "GitHub Release upload disabled"
    return
  }
  [[ -n "${GITHUB_TOKEN:-}" ]] || {
    warn "GITHUB_TOKEN is missing; skipping GitHub Release"
    return
  }
  require_tool gh

  local tag title zip_file logs_zip url asset uploaded_any
  tag="$(_release_tag)"
  title="$BUILD_NAME $DEVICE_CODENAME ${ROM_VERSION:-unknown}"
  zip_file="$(_zip_path)"
  logs_zip="$OUTPUT_FINAL/logs.zip"
  uploaded_any=false
  [[ -s "$zip_file" ]] || die "Cannot upload missing ZIP: $zip_file"

  if [[ -d "$OUTPUT_FINAL/logs" ]]; then
    (cd "$OUTPUT_FINAL" && zip -qr logs.zip logs) || warn "Could not create logs.zip"
  fi

  export GH_TOKEN="$GITHUB_TOKEN"
  if gh release view "$tag" >/dev/null 2>&1; then
    log "Updating existing GitHub Release: $tag"
  else
    gh release create "$tag" --title "$title" --notes-file "$OUTPUT_FINAL/build_info.txt" >/dev/null
  fi

  url="$(gh release view "$tag" --json url -q .url 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    _append_upload_link "GITHUB_RELEASE_URL" "$url"
    refresh_build_info
    generate_pre_zip_sha256sums
    generate_final_zip_sha256
  fi

  if _github_asset_allowed "$zip_file"; then
    gh release upload "$tag" "$zip_file" --clobber >/dev/null
    uploaded_any=true
  else
    _append_upload_link "GITHUB_RELEASE_ZIP_SKIPPED" "true"
    _append_upload_link "GITHUB_RELEASE_ZIP_SKIP_REASON" "larger_than_2GiB"
  fi

  for asset in \
    "$zip_file.sha256" \
    "$OUTPUT_FINAL/build_info.txt" \
    "$OUTPUT_FINAL/sha256sums.txt" \
    "$OUTPUT_FINAL/upload_links.txt" \
    "$logs_zip"; do
    [[ -s "$asset" ]] || continue
    if _github_asset_allowed "$asset"; then
      gh release upload "$tag" "$asset" --clobber >/dev/null
      uploaded_any=true
    fi
  done

  [[ "$uploaded_any" == "true" ]] || warn "No GitHub Release assets were uploaded"
}

_upload_pixeldrain() {
  _bool_true "$UPLOAD_PIXELDRAIN" || {
    warn "PixelDrain upload disabled"
    if _zip_too_large_for_github; then
      warn "Final ZIP is too large for GitHub Release and PixelDrain upload is disabled."
    fi
    return
  }
  if [[ -z "${PIXELDRAIN_API_KEY:-}" ]]; then
    warn "PIXELDRAIN_API_KEY is missing; skipping PixelDrain upload"
    if _zip_too_large_for_github; then
      die "PixelDrain upload required because final ZIP is too large for GitHub Release, but PIXELDRAIN_API_KEY is missing"
    fi
    return
  fi
  require_tool curl
  require_tool jq

  local zip_file response id
  zip_file="$(_zip_path)"
  [[ -s "$zip_file" ]] || die "Cannot upload missing ZIP: $zip_file"
  log "Uploading fastboot ZIP to PixelDrain"
  response="$(curl -fsS -u ":$PIXELDRAIN_API_KEY" -F "file=@$zip_file" "https://pixeldrain.com/api/file" 2>/dev/null)" || {
    if _zip_too_large_for_github; then
      die "PixelDrain upload failed and final ZIP is too large for GitHub Release"
    fi
    warn "PixelDrain upload failed"
    return
  }
  id="$(printf '%s' "$response" | jq -r '.id // empty')"
  if [[ -z "$id" ]]; then
    if _zip_too_large_for_github; then
      die "PixelDrain upload failed and final ZIP is too large for GitHub Release"
    fi
    warn "PixelDrain upload failed"
    return
  fi
  _append_upload_link "PIXELDRAIN_URL" "https://pixeldrain.com/u/$id"
}

_notify_telegram() {
  _bool_true "$NOTIFY_TELEGRAM" || {
    warn "Telegram notification disabled"
    return
  }
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    warn "Telegram secrets are missing; skipping notification"
    return
  fi
  require_tool curl

  local zip_file sha pd gh size skip_note pd_note message
  zip_file="$(_zip_path)"
  sha="$(cut -d' ' -f1 "$zip_file.sha256" 2>/dev/null || true)"
  pd="$(_pixeldrain_url)"
  gh="$(grep '^GITHUB_RELEASE_URL=' "$OUTPUT_FINAL/upload_links.txt" 2>/dev/null | cut -d= -f2- || true)"
  size="$(human_size "$zip_file")"
  skip_note=""
  pd_note=""
  if _zip_too_large_for_github; then
    skip_note="GitHub Release ZIP skipped because file is larger than 2GiB."
    if [[ -z "$pd" ]]; then
      pd_note="PixelDrain link missing; ZIP too large for GitHub Release."
    fi
  fi
  message=$(cat <<EOF
Build completed
Device: $DEVICE_CODENAME
Build: $BUILD_NAME
ROM version: ${ROM_VERSION:-unknown}
Final ZIP: $(basename "$zip_file")
ZIP size: $size
SHA256: $sha
PixelDrain: ${pd:-not uploaded}
GitHub Release: ${gh:-not uploaded}
${skip_note}
${pd_note}
EOF
)
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$message" >/dev/null || warn "Telegram notification failed"
}

upload_release_artifacts() {
  touch "$OUTPUT_FINAL/upload_links.txt"
  _upload_pixeldrain
  refresh_build_info
  generate_pre_zip_sha256sums
  generate_final_zip_sha256
  _upload_github_release
  _notify_telegram
}
