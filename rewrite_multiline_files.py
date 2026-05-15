from pathlib import Path


FILES = {
    ".github/workflows/build.yml": """name: DeadZone ROM Kitchen Phase 1

on:
  workflow_dispatch:
    inputs:
      rom_url:
        description: OTA zip direct download URL
        required: true
        type: string
      device_codename:
        description: Device codename matching devices/<codename>.conf
        required: true
        type: string
      skip_patches:
        description: Keep Phase 1 unmodified
        required: true
        default: "true"
        type: choice
        options:
          - "true"
          - "false"
      output_type:
        description: Output artifact type
        required: true
        default: super_zst
        type: choice
        options:
          - super_zst

jobs:
  kitchen:
    name: Build super.img.zst
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          echo "=== Disk before ==="
          df -h /
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
          sudo rm -rf /usr/local/share/boost "$AGENT_TOOLSDIRECTORY"
          sudo apt-get clean
          docker rmi $(docker image ls -aq) 2>/dev/null || true
          echo "=== Disk after ==="
          df -h /

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \\
            aria2 \\
            unzip \\
            p7zip-full \\
            zstd \\
            brotli \\
            lz4 \\
            jq \\
            file \\
            curl \\
            ca-certificates \\
            e2fsprogs \\
            erofs-utils \\
            android-sdk-libsparse-utils

      - name: Setup tools
        run: bash core/setup_tools.sh

      - name: Run Phase 1 kitchen
        run: |
          chmod +x main.sh core/*.sh bin/* || true
          ./main.sh \\
            "${{ github.event.inputs.rom_url }}" \\
            "${{ github.event.inputs.device_codename }}" \\
            "${{ github.event.inputs.skip_patches }}" \\
            "${{ github.event.inputs.output_type }}"

      - name: Output info
        if: always()
        run: |
          echo "=== output/ ==="
          ls -lh output/ 2>/dev/null || true
          echo "=== logs/ ==="
          ls -lh logs/ 2>/dev/null || true

      - name: Upload Phase 1 artifact
        if: success()
        uses: actions/upload-artifact@v4
        with:
          name: deadzone-${{ github.event.inputs.device_codename }}-super-zst
          path: |
            output/super.img.zst
            logs/
          retention-days: 7
""",
    "main.sh": """#!/usr/bin/env bash
set -euo pipefail

export WORKSPACE="${WORKSPACE:-$(pwd)}"
export BIN="$WORKSPACE/bin"
export INPUT="$WORKSPACE/input"
export EXTRACTED="$WORKSPACE/extracted"
export OUTPUT="$WORKSPACE/output"
export LOGS="$WORKSPACE/logs"
export DEVICES="$WORKSPACE/devices"
export PATH="$BIN:$PATH"

source "$WORKSPACE/core/utils.sh"
source "$WORKSPACE/core/unpacker.sh"
source "$WORKSPACE/core/repacker.sh"

main() {
    local rom_url="${1:-${ROM_URL:-}}"
    export DEVICE_CODENAME="${2:-${DEVICE_CODENAME:-}}"
    export SKIP_PATCHES="${3:-${SKIP_PATCHES:-true}}"
    export OUTPUT_TYPE="${4:-${OUTPUT_TYPE:-super_zst}}"

    [[ -n "$rom_url" ]] || die "Usage: ./main.sh <ROM_URL> <DEVICE_CODENAME> [SKIP_PATCHES] [OUTPUT_TYPE]"
    [[ -n "$DEVICE_CODENAME" ]] || die "device_codename is required"
    [[ "$OUTPUT_TYPE" == "super_zst" ]] || die "Only output_type=super_zst is supported in Phase 1"

    section "DeadZone ROM Kitchen Phase 1"
    log "Device codename: $DEVICE_CODENAME"
    log "Skip patches: $SKIP_PATCHES"
    log "Output type: $OUTPUT_TYPE"
    if [[ "$SKIP_PATCHES" != "true" ]]; then
        warn "skip_patches=false was requested, but patches are disabled in Phase 1"
    fi

    prepare_env
    load_device_defaults
    fetch_rom "$rom_url"

    section "Payload Extraction"
    extract_payload_partitions
    detect_partition_images

    section "Super Build"
    build_super_image
    compress_super_image

    section "Done"
    log "Output path: $OUTPUT/super.img.zst"
    log "Logs path: $LOGS"
}

main "$@"
""",
    "core/setup_tools.sh": """#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-$(pwd)}"
BIN="$WORKSPACE/bin"
PATH="$BIN:$PATH"

mkdir -p "$BIN"
find "$BIN" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true

log() {
    echo "[$(date +%T)] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

copy_from_path() {
    local tool="$1"
    local src

    src="$(command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$src" ]]; then
        log "  MISSING $tool"
        return 1
    fi

    log "  Found $tool at $src"
    if [[ "$src" != "$BIN/$tool" ]]; then
        cp "$src" "$BIN/$tool"
        chmod +x "$BIN/$tool"
        log "  Copied $tool to $BIN/$tool"
    fi

    return 0
}

install_payload_dumper_go() {
    if command -v payload-dumper-go >/dev/null 2>&1; then
        copy_from_path payload-dumper-go
        return
    fi

    if [[ -x "$BIN/payload-dumper-go" ]]; then
        log "  Found payload-dumper-go at $BIN/payload-dumper-go"
        return
    fi

    log "Installing payload-dumper-go"
    local api="https://api.github.com/repos/ssut/payload-dumper-go/releases/latest"
    local url
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
    log "  Installed payload-dumper-go to $BIN/payload-dumper-go"
}

install_android_partition_tools() {
    local tool

    log "Discovering Android partition tools from PATH/bin"
    for tool in simg2img img2simg lpmake lpdump lpunpack; do
        copy_from_path "$tool" || true
    done

    if ! command -v lpmake >/dev/null 2>&1 || ! command -v lpdump >/dev/null 2>&1; then
        die "lpmake/lpdump missing. Update GitHub Actions apt packages or add a valid prebuilt source."
    fi

    log "Android partition tools ready"
}

install_system_tools() {
    local tool

    log "Discovering compression and filesystem tools from PATH/bin"
    for tool in zstd brotli lz4 mkfs.erofs fsck.erofs dump.erofs mke2fs e2fsck resize2fs; do
        copy_from_path "$tool" || true
    done

    if [[ -x "$BIN/fsck.erofs" && ! -e "$BIN/extract.erofs" ]]; then
        ln -s fsck.erofs "$BIN/extract.erofs"
        log "  Linked extract.erofs to fsck.erofs"
    fi
}

verify_tools() {
    local required=(
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

    local missing=()
    local tool

    log "Tool verification"
    for tool in "${required[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log "  OK $tool ($(command -v "$tool"))"
        else
            missing+=("$tool")
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
""",
    "core/unpacker.sh": """#!/usr/bin/env bash
set -euo pipefail

extract_payload_partitions() {
    require_tool payload-dumper-go
    require_tool unzip

    local payload="$INPUT/payload.bin"
    local unzip_dir="$INPUT/ota"

    case "${ROM_FILE##*.}" in
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

_payload_partition_csv() {
    local csv=""
    local part

    for part in $DYNAMIC_PARTITIONS; do
        csv="${csv:+$csv,}$part"
    done

    printf '%s' "$csv"
}

detect_partition_images() {
    require_tool file

    : > "$WORKSPACE/partitions.tsv"
    : > "$LOGS/partitions.log"

    log "Detecting extracted partition images"
    local extracted=()
    local part img size format fs

    for part in $DYNAMIC_PARTITIONS; do
        img="$EXTRACTED/$part.img"
        if [[ ! -f "$img" ]]; then
            warn "Partition not present in payload: $part"
            continue
        fi

        size="$(file_size "$img")"
        format="$(_detect_image_container "$img")"
        fs="$(_detect_image_filesystem "$img" "$format")"

        if [[ "$format" == "sparse" ]]; then
            local raw_img="$EXTRACTED/${part}.raw.img"
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
        simg2img "$img" "$tmp" >/dev/null 2>&1 || {
            printf 'unknown'
            return
        }
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
""",
    "core/repacker.sh": """#!/usr/bin/env bash
set -euo pipefail

build_super_image() {
    require_tool lpmake

    local metadata_source="profile"
    if _load_super_metadata_from_image; then
        metadata_source="lpdump"
    elif ! load_device_profile; then
        _fail_missing_profile
    fi

    _validate_super_profile

    local total_image_size=0
    local part img size

    while IFS=$'\t' read -r part img size _container _fs; do
        total_image_size=$((total_image_size + size))
    done < "$WORKSPACE/partitions.tsv"

    log "Super metadata source: $metadata_source"
    log "Super size: $SUPER_SIZE"
    log "Group name: $DYNAMIC_PARTITION_GROUP_NAME"
    log "Group size: $DYNAMIC_PARTITION_GROUP_SIZE"
    log "Total image size: $total_image_size"

    if (( total_image_size > DYNAMIC_PARTITION_GROUP_SIZE )); then
        die "Partition images exceed group size: images=$total_image_size group=$DYNAMIC_PARTITION_GROUP_SIZE"
    fi

    local -a cmd
    cmd=(
        lpmake
        --metadata-size "$SUPER_METADATA_SIZE"
        --metadata-slots "$SUPER_METADATA_SLOTS"
        --super-name "${SUPER_NAME:-super}"
        --device "super:$SUPER_SIZE"
        --group "$DYNAMIC_PARTITION_GROUP_NAME:$DYNAMIC_PARTITION_GROUP_SIZE"
    )

    while IFS=$'\t' read -r part img size _container _fs; do
        local lp_name="${part}${PARTITION_SUFFIX:-}"
        cmd+=(--partition "$lp_name:readonly:$size:$DYNAMIC_PARTITION_GROUP_NAME")
        cmd+=(--image "$lp_name=$img")
    done < "$WORKSPACE/partitions.tsv"

    cmd+=(--sparse --output "$OUTPUT/super.img")

    printf '%q ' "${cmd[@]}" > "$LOGS/lpmake-command.log"
    printf '\n' >> "$LOGS/lpmake-command.log"

    log "Running lpmake"
    "${cmd[@]}" 2>&1 | tee "$LOGS/lpmake.log"

    [[ -f "$OUTPUT/super.img" ]] || die "lpmake did not create $OUTPUT/super.img"
    log "Output path: $OUTPUT/super.img"
    log "super.img size: $(file_size "$OUTPUT/super.img") bytes ($(human_size "$OUTPUT/super.img"))"
}

_load_super_metadata_from_image() {
    require_tool lpdump

    local candidate

    for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
        [[ -f "$candidate" ]] || continue
        log "Reading exact super metadata from: $candidate"
        lpdump "$candidate" > "$LOGS/lpdump.log" 2>&1 || return 1

        SUPER_SIZE="$(file_size "$candidate")"
        SUPER_METADATA_SIZE="$(awk '/Metadata max size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"
        SUPER_METADATA_SLOTS="$(awk '/Metadata slot count:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"
        DYNAMIC_PARTITION_GROUP_NAME="$(awk '/Name:/ {name=$2} /Maximum size:/ && name != "" {print name; exit}' "$LOGS/lpdump.log")"
        DYNAMIC_PARTITION_GROUP_SIZE="$(awk '/Maximum size:/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOGS/lpdump.log")"

        [[ -n "${SUPER_METADATA_SIZE:-}" && -n "${SUPER_METADATA_SLOTS:-}" ]] || return 1
        [[ -n "${DYNAMIC_PARTITION_GROUP_NAME:-}" && -n "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]] || return 1
        export SUPER_SIZE SUPER_METADATA_SIZE SUPER_METADATA_SLOTS DYNAMIC_PARTITION_GROUP_NAME DYNAMIC_PARTITION_GROUP_SIZE
        return 0
    done

    return 1
}

compress_super_image() {
    require_tool zstd

    log "Compressing super.img to super.img.zst"
    zstd -T0 -19 -f "$OUTPUT/super.img" -o "$OUTPUT/super.img.zst" 2>&1 | tee "$LOGS/zstd.log"
    log "Output path: $OUTPUT/super.img.zst"
    log "super.img.zst size: $(file_size "$OUTPUT/super.img.zst") bytes ($(human_size "$OUTPUT/super.img.zst"))"
}

_validate_super_profile() {
    local missing=()

    [[ -n "${SUPER_SIZE:-}" ]] || missing+=("SUPER_SIZE")
    [[ -n "${DYNAMIC_PARTITION_GROUP_NAME:-}" ]] || missing+=("DYNAMIC_PARTITION_GROUP_NAME")
    [[ -n "${DYNAMIC_PARTITION_GROUP_SIZE:-}" ]] || missing+=("DYNAMIC_PARTITION_GROUP_SIZE")
    [[ -n "${SUPER_METADATA_SIZE:-}" ]] || missing+=("SUPER_METADATA_SIZE")
    [[ -n "${SUPER_METADATA_SLOTS:-}" ]] || missing+=("SUPER_METADATA_SLOTS")

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Device profile devices/$DEVICE_CODENAME.conf is missing: ${missing[*]}"
    fi
}

_fail_missing_profile() {
    cat >&2 <<EOF
[ERROR] Exact super metadata was not available from the OTA payload, and no profile exists for '$DEVICE_CODENAME'.

Create devices/$DEVICE_CODENAME.conf with these values:
SUPER_SIZE=<bytes>
DYNAMIC_PARTITION_GROUP_NAME=<group_name, for example qti_dynamic_partitions>
DYNAMIC_PARTITION_GROUP_SIZE=<bytes>
SUPER_METADATA_SIZE=<bytes, commonly 65536>
SUPER_METADATA_SLOTS=<number, commonly 2 or 3>
SUPER_NAME=super
PARTITION_SUFFIX=<optional, for example _a if logical partition names require it>

Tip: get exact values from a stock super.img using lpdump, or from the device board config.
EOF
    exit 1
}
""",
    "core/utils.sh": """#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[$(date +%T)] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo "  $*"
    echo "============================================================"
}

require_tool() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
}

file_size() {
    stat -c%s "$1"
}

human_size() {
    du -h "$1" | awk '{print $1}'
}

prepare_env() {
    log "Preparing workspace"
    rm -rf "$INPUT" "$EXTRACTED" "$OUTPUT" "$LOGS" "$WORKSPACE/rom_info.env" "$WORKSPACE/partitions.tsv"
    mkdir -p "$INPUT" "$EXTRACTED" "$OUTPUT" "$LOGS"
}

load_device_defaults() {
    local default_conf="$DEVICES/default.conf"
    [[ -f "$default_conf" ]] || die "Missing $default_conf"
    source "$default_conf"
    [[ -n "${DYNAMIC_PARTITIONS:-}" ]] || die "DYNAMIC_PARTITIONS is missing in $default_conf"
    export DYNAMIC_PARTITIONS
}

load_device_profile() {
    local profile="$DEVICES/$DEVICE_CODENAME.conf"
    [[ -f "$profile" ]] || return 1
    log "Using device profile: $profile"
    source "$profile"
}

fetch_rom() {
    local url="$1"
    log "Downloading OTA"
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$INPUT" "$url" || die "Download failed"

    local rom_file
    rom_file="$(find "$INPUT" -maxdepth 1 -type f | head -n 1)"
    [[ -f "$rom_file" ]] || die "Downloaded ROM file not found"

    export ROM_FILE="$rom_file"
    log "Downloaded file: $(basename "$ROM_FILE")"
    log "Downloaded file size: $(file_size "$ROM_FILE") bytes ($(human_size "$ROM_FILE"))"
}
""",
    "devices/default.conf": """# Dynamic partitions to dump from OTA payload.bin in Phase 1.
DYNAMIC_PARTITIONS="system product system_ext vendor vendor_dlkm system_dlkm odm odm_dlkm mi_ext"
""",
    "devices/zircon.conf": """# Redmi Note 13 Pro+ (zircon)
# Verify SUPER_SIZE and DYNAMIC_PARTITION_GROUP_SIZE with:
# fastboot getvar partition-size:super
DEVICE_CODENAME=zircon
SUPER_SIZE=9126805504
DYNAMIC_PARTITION_GROUP_NAME=qti_dynamic_partitions
DYNAMIC_PARTITION_GROUP_SIZE=9122611200
SUPER_METADATA_SIZE=65536
SUPER_METADATA_SLOTS=2
SUPER_NAME=super
PARTITION_SUFFIX=_a

SUPER_PARTITIONS=(
  system
  product
  system_ext
  vendor
  vendor_dlkm
  system_dlkm
  odm
  odm_dlkm
  mi_ext
)
""",
}


def main() -> None:
    for path, content in FILES.items():
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
