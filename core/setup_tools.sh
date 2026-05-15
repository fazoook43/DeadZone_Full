#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

WORKSPACE="${WORKSPACE:-$(pwd)}"
BIN="$WORKSPACE/bin"
LOGS="$WORKSPACE/logs"
PATH="$BIN:$PATH"
MEATOR_ASSETS_CHECKED="$LOGS/meator-assets-checked.txt"

mkdir -p "$BIN" "$LOGS"
exec > >(tee -a "$LOGS/tool-verification.log") 2>&1

find "$BIN" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true

log() { echo "[$(date +%T)] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

copy_from_path() {
  local tool="$1"
  local src=""
  src="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -z "$src" ]]; then
    log "MISSING $tool"
    return 1
  fi

  log "FOUND $tool at $src"
  if [[ "$src" != "$BIN/$tool" ]]; then
    cp "$src" "$BIN/$tool"
    chmod +x "$BIN/$tool"
    log "COPIED $tool to $BIN/$tool"
  fi
  return 0
}

install_payload_dumper_go() {
  if command -v payload-dumper-go >/dev/null 2>&1; then
    copy_from_path payload-dumper-go
    return
  fi

  if [[ -x "$BIN/payload-dumper-go" ]]; then
    log "FOUND payload-dumper-go at $BIN/payload-dumper-go"
    return
  fi

  log "Installing payload-dumper-go"
  local api="https://api.github.com/repos/ssut/payload-dumper-go/releases/latest"
  local url=""
  url="$(curl -fsSL "$api" | jq -r '.assets[] | select(.name | test("linux.*(amd64|x86_64)"; "i")) | .browser_download_url' | head -n 1)"
  [[ -n "$url" && "$url" != "null" ]] || die "Could not find payload-dumper-go linux amd64 release"

  local tmp
  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/payload-dumper-go.tar.gz"
  tar -xf "$tmp/payload-dumper-go.tar.gz" -C "$tmp"
  local found
  found="$(find "$tmp" -type f -name payload-dumper-go | head -n 1)"
  [[ -n "$found" ]] || die "payload-dumper-go binary not found in release archive"
  cp "$found" "$BIN/payload-dumper-go"
  chmod +x "$BIN/payload-dumper-go"
  rm -rf "$tmp"
  log "INSTALLED payload-dumper-go to $BIN/payload-dumper-go"
}

copy_partition_tool_from_tree() {
  local root="$1"
  local name="$2"
  local found=""
  found="$(find "$root" -type f -name "$name" | head -n 1 || true)"
  [[ -n "$found" ]] || return 1
  cp "$found" "$BIN/$name"
  chmod +x "$BIN/$name"
  log "COPIED $name from $found"
}

copy_partition_tools_from_tree() {
  local root="$1"
  local source_name="$2"
  local found tool
  while IFS= read -r found; do
    [[ -n "$found" ]] || continue
    tool="$(basename "$found")"
    cp "$found" "$BIN/$tool"
    chmod +x "$BIN/$tool"
    log "COPIED $tool from $source_name: $found"
  done < <(
    find "$root" -type f \( \
      -name lpdump -o \
      -name lpmake -o \
      -name lpunpack -o \
      -name lpadd -o \
      -name lpflash -o \
      -name simg2img -o \
      -name img2simg -o \
      -name append2simg \
    \) 2>/dev/null | sort
  )
}

print_meator_assets_checked() {
  if [[ -s "$MEATOR_ASSETS_CHECKED" ]]; then
    echo "Downloaded meator assets checked:"
    cat "$MEATOR_ASSETS_CHECKED"
  else
    echo "Downloaded meator assets checked: none"
  fi
}

extract_meator_archive() {
  local archive="$1"
  local tmp="$2"
  tar -xzf "$archive" -C "$tmp"
  copy_partition_tools_from_tree "$tmp" "meator/android-tools-static"
  "$BIN/lpdump" --help >/dev/null 2>&1 || true
  "$BIN/lpmake" --help >/dev/null 2>&1 || true
  [[ -x "$BIN/lpdump" && -x "$BIN/lpmake" ]]
}

install_android_tools_static_extra_from_meator_api() {
  local api tmp assets_json selected_name selected_url
  api="https://api.github.com/repos/meator/android-tools-static/releases?per_page=20"
  tmp="$1"
  assets_json="$tmp/meator-assets.json"

  curl -fsSL "$api" > "$assets_json" || {
    warn "Could not query meator/android-tools-static releases"
    return 1
  }

  jq -r '.[].assets[].name' "$assets_json" > "$MEATOR_ASSETS_CHECKED"
  log "meator/android-tools-static candidate asset names:"
  sed 's/^/[meator asset] /' "$MEATOR_ASSETS_CHECKED" || true

  selected_name="$(
    jq -r '.[].assets[]
      | select(.name | test("standardlayout-extra"; "i"))
      | select(.name | test("linux"; "i"))
      | select(.name | test("x86_64|x86-64|amd64|x64"; "i"))
      | select(.name | test("\\.tar\\.gz$"; "i"))
      | select(.name | test("\\.sha256|\\.sig|\\.asc|sbom|src|source"; "i") | not)
      | .name' "$assets_json" |
      head -n 1
  )"
  selected_url="$(
    jq -r --arg name "$selected_name" '.[].assets[]
      | select(.name == $name)
      | .browser_download_url' "$assets_json" |
      head -n 1
  )"

  [[ -n "$selected_name" && -n "$selected_url" && "$selected_url" != "null" ]] || {
    warn "Could not select meator standardlayout-extra Linux x86_64 tar.gz asset from releases list"
    return 1
  }

  log "Selected meator asset: $selected_name"
  curl -fL "$selected_url" -o "$tmp/$selected_name" || return 1
  extract_meator_archive "$tmp/$selected_name" "$tmp"
}

install_android_tools_static_extra_from_meator_tag() {
  local tmp archive
  tmp="$1"

  command -v gh >/dev/null 2>&1 || {
    warn "gh is unavailable; cannot use meator 35.0.2-rc.1 emergency fallback"
    return 1
  }

  log "Trying meator/android-tools-static emergency fallback tag 35.0.2-rc.1"
  mkdir -p "$tmp/meator-gh"
  gh release download 35.0.2-rc.1 \
    --repo meator/android-tools-static \
    --pattern "*linux*standardlayout-extra*.tar.gz" \
    --dir "$tmp/meator-gh" || return 1

  while IFS= read -r archive; do
    [[ -n "$archive" ]] || continue
    basename "$archive" >> "$MEATOR_ASSETS_CHECKED"
    log "Selected meator emergency asset: $(basename "$archive")"
    extract_meator_archive "$archive" "$tmp" && return 0
  done < <(find "$tmp/meator-gh" -type f -name '*.tar.gz' 2>/dev/null | sort)

  return 1
}

install_android_tools_static_extra_from_meator() {
  log "Trying meator/android-tools-static standardlayout-extra package"
  local tmp
  : > "$MEATOR_ASSETS_CHECKED"
  tmp="$(mktemp -d)"

  install_android_tools_static_extra_from_meator_api "$tmp" ||
    install_android_tools_static_extra_from_meator_tag "$tmp" || {
      warn "Failed to install lpdump/lpmake from meator/android-tools-static"
      rm -rf "$tmp"
      return 1
    }

  rm -rf "$tmp"

  [[ -x "$BIN/lpdump" && -x "$BIN/lpmake" ]]
}

install_android_tools_static_extra_from_rprop() {
  log "Trying Rprop/aosp15_partition_tools fallback source"
  local tmp
  tmp="$(mktemp -d)"

  if git clone --depth=1 https://github.com/Rprop/aosp15_partition_tools "$tmp/aosp15_partition_tools"; then
    copy_partition_tools_from_tree "$tmp/aosp15_partition_tools/linux_glibc_x86_64" "Rprop/aosp15_partition_tools" || true
  else
    warn "Could not clone Rprop/aosp15_partition_tools fallback"
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
  [[ -x "$BIN/lpdump" && -x "$BIN/lpmake" ]]
}

install_android_tools_static_extra() {
  if [[ -x "$BIN/lpdump" && -x "$BIN/lpmake" ]]; then
    log "lpdump and lpmake already available in $BIN"
    return
  fi

  install_android_tools_static_extra_from_meator || install_android_tools_static_extra_from_rprop || true

  chmod +x "$BIN"/* 2>/dev/null || true
  export PATH="$BIN:$PATH"
  hash -r

  if command -v lpdump >/dev/null 2>&1; then
    log "lpdump came from $(command -v lpdump)"
    log "lpdump help: $(lpdump --help 2>&1 | head -n 1 || true)"
  else
    warn "lpdump still missing after static partition tools install"
  fi

  if command -v lpmake >/dev/null 2>&1; then
    log "lpmake came from $(command -v lpmake)"
    log "lpmake help: $(lpmake --help 2>&1 | head -n 1 || true)"
  else
    warn "lpmake still missing after static partition tools install"
  fi

  command -v lpdump >/dev/null 2>&1 || true
  command -v lpmake >/dev/null 2>&1 || true
  lpdump --help >/dev/null 2>&1 || true
  lpmake --help >/dev/null 2>&1 || true

  if ! command -v lpdump >/dev/null 2>&1; then
    echo "::error::lpdump is still missing after meator + Rprop installers"
    print_meator_assets_checked
    exit 1
  fi
  command -v lpmake >/dev/null 2>&1 || die "Missing required tools: lpmake"
}

install_android_partition_tools() {
  log "Discovering Android partition tools from PATH/bin"
  local tool
  for tool in lpmake lpdump lpunpack lpadd lpflash simg2img img2simg append2simg; do
    copy_from_path "$tool" || true
  done

  if [[ ! -x "$BIN/lpdump" || ! -x "$BIN/lpmake" ]]; then
    install_android_tools_static_extra
  fi

  chmod +x "$BIN"/* 2>/dev/null || true
  export PATH="$BIN:$PATH"
  hash -r
  log "Android partition tools discovery finished"
}

install_system_tools() {
  log "Discovering compression and filesystem tools from PATH/bin"
  local tool
  for tool in aria2c unzip zip zstd brotli lz4 jq file curl git gh avbtool sha256sum mkfs.erofs extract.erofs fsck.erofs dump.erofs mke2fs e2fsck resize2fs; do
    copy_from_path "$tool" || true
  done
}

verify_tools() {
  local required=(
    aria2c
    curl
    jq
    unzip
    zip
    file
    payload-dumper-go
    lpmake
    lpdump
    simg2img
    img2simg
    zstd
    brotli
    lz4
    mkfs.erofs
    extract.erofs
    mke2fs
    e2fsck
    resize2fs
  )
  local optional=(
    lpunpack
    lpadd
    lpflash
    append2simg
    gh
    avbtool
    fsck.erofs
    dump.erofs
    sha256sum
  )
  local missing=()
  local tool

  log "Tool verification"
  for tool in "${required[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      log "OK required $tool ($(command -v "$tool"))"
    else
      missing+=("$tool")
    fi
  done

  for tool in "${optional[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      log "OK optional $tool ($(command -v "$tool"))"
    else
      warn "Optional tool missing: $tool"
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

install_payload_dumper_go
install_android_partition_tools
install_system_tools
verify_tools
