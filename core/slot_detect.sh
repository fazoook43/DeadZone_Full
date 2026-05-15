#!/usr/bin/env bash
# LF normalized for GitHub raw
# =============================================================================
#  slot_detect.sh — Auto-detect slot mode from payload.bin / lpdump / device
#
#  Exports:
#    SUPER_SLOT_MODE   → "A"   (no slots, single copy)
#                      → "AB"  (A/B with separate slot groups)
#                      → "VAB" (Virtual A/B, single group)
#
#  Detection priority (highest → lowest trust):
#    1. Device profile .conf          (explicit user config — always wins)
#    2. lpdump on any super.img       (reads actual partition metadata)
#    3. build.prop from extracted FS  (ro.virtual_ab.enabled / ro.boot.slot_suffix)
#    4. payload-dumper-go --list      (partition name heuristics)
#    5. Extracted image filenames     (system_a.img vs system.img)
#    6. DYNAMIC_PARTITION_GROUP_NAME  (group name suffix heuristic)
#
#  IMPORTANT: once a higher-trust source sets the mode, lower-trust sources
#  cannot downgrade it.  A lower-trust source CAN upgrade AB → VAB (additive
#  information), but never VAB → AB (removing information).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_slot_log()  { log  "[slot_detect] $*"; }
_slot_warn() { warn "[slot_detect] $*"; }

# Return 0 if $1 is one of the three valid modes
_is_valid_slot_mode() {
  case "${1:-}" in
    A|AB|VAB) return 0 ;;
    *) return 1 ;;
  esac
}

# Upgrade rule: never downgrade; only allow A→AB, A→VAB, AB→VAB
# Returns 0 if the new mode is an upgrade or equal; 1 if it's a downgrade
_is_upgrade_or_equal() {
  local current="${1:-}"
  local proposed="${2:-}"
  [[ "$current" == "$proposed" ]] && return 0
  [[ "$current" == "A"  && ( "$proposed" == "AB" || "$proposed" == "VAB" ) ]] && return 0
  [[ "$current" == "AB" && "$proposed" == "VAB" ]] && return 0
  return 1
}

# Apply a slot mode candidate: only accept if it's an upgrade (or first result)
# Usage: _apply_slot_candidate "source_name" "VAB"
_apply_slot_candidate() {
  local source="$1"
  local candidate="$2"

  _is_valid_slot_mode "$candidate" || { _slot_warn "[$source] invalid mode: '$candidate' — ignored"; return 1; }

  if [[ -z "${_SLOT_DETECTED:-}" ]]; then
    _SLOT_DETECTED="$candidate"
    _SLOT_SOURCE="$source"
    _slot_log "[$source] initial detection → $candidate"
    return 0
  fi

  if _is_upgrade_or_equal "$_SLOT_DETECTED" "$candidate"; then
    if [[ "$_SLOT_DETECTED" != "$candidate" ]]; then
      _slot_log "[$source] upgrading $SLOT_DETECTED→$candidate (was from $_SLOT_SOURCE)"
      _SLOT_DETECTED="$candidate"
      _SLOT_SOURCE="$source"
    else
      _slot_log "[$source] confirmed $_SLOT_DETECTED"
    fi
  else
    _slot_warn "[$source] proposed '$candidate' would downgrade '$_SLOT_DETECTED' — ignored (trust $_SLOT_SOURCE over $source)"
  fi
}

# ---------------------------------------------------------------------------
# _parse_super_size_from_lpdump_log
#  Parse the actual partition size from lpdump "Block device table → Size:"
#  This is more accurate than file_size() which may reflect a trimmed image.
#
#  lpdump format:
#    Block device table:
#      Name: super
#      First sector: 2048
#      Size: 9663676416       ← we want this
#      Flags: none
# ---------------------------------------------------------------------------
_parse_super_size_from_lpdump_log() {
  local lpdump_log="$1"
  [[ -s "$lpdump_log" ]] || return 1

  local size
  size=$(awk '
    /Block device table/ { in_bdt=1 }
    in_bdt && /^\s+Size:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/ && ($i + 0) > 1048576) {  # sanity: >1 MiB
          print $i
          exit
        }
      }
    }
  ' "$lpdump_log")

  if [[ -n "${size:-}" ]] && (( size > 0 )); then
    printf '%s' "$size"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Strategy 1: parse lpdump output
#
#  VAB  → "Virtual AB: true"  (explicit flag — definitive)
#  AB   → _a AND _b suffixed Name entries (groups OR partitions) + no VAB flag
#  A    → no _a/_b suffixes at all
#
#  Uses \s+ in regex to handle any indentation produced by different lpdump
#  versions; does NOT hard-code the two-space indent.
# ---------------------------------------------------------------------------
_slot_from_lpdump() {
  local dump_file="$1"
  [[ -s "$dump_file" ]] || return 1

  # --- VAB: definitive flag -------------------------------------------------
  # "Virtual AB: true" appears in the metadata header (lpdump >= r29)
  if grep -qiE "^\s*Virtual AB:\s*true" "$dump_file"; then
    printf 'VAB'
    return 0
  fi

  # --- AB: both _a and _b Name entries exist --------------------------------
  # This matches group names (qti_dynamic_partitions_a) and partition names
  # (system_a, vendor_a …) regardless of indentation depth.
  local count_a count_b
  count_a=$(grep -cE "^\s+Name:\s+\S+_a\s*$" "$dump_file" 2>/dev/null || true)
  count_b=$(grep -cE "^\s+Name:\s+\S+_b\s*$" "$dump_file" 2>/dev/null || true)

  if (( count_a > 0 && count_b > 0 )); then
    printf 'AB'
    return 0
  fi

  # --- A-only: no slot suffixes found anywhere ------------------------------
  printf 'A'
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 2: payload-dumper-go --list
#  Limitation: partition names alone cannot distinguish AB from VAB.
#  We return AB as the conservative answer; a later higher-trust strategy
#  (build.prop or lpdump on super.img) can upgrade to VAB.
# ---------------------------------------------------------------------------
_slot_from_payload_list() {
  local payload="$1"
  [[ -f "$payload" ]] || return 1
  command -v payload-dumper-go >/dev/null 2>&1 || return 1

  local tmp_list
  tmp_list="$(mktemp)"
  payload-dumper-go --list "$payload" > "$tmp_list" 2>&1 || { rm -f "$tmp_list"; return 1; }

  local has_a has_b
  has_a=$(grep -cE "_a$" "$tmp_list" 2>/dev/null || true)
  has_b=$(grep -cE "_b$" "$tmp_list" 2>/dev/null || true)
  rm -f "$tmp_list"

  if (( has_a > 0 && has_b > 0 )); then
    # Cannot distinguish AB from VAB from names alone.
    # Return AB; lpdump/build.prop may upgrade to VAB later.
    printf 'AB'
    return 0
  fi

  if (( has_a == 0 && has_b == 0 )); then
    printf 'A'
    return 0
  fi

  # Asymmetric (only _a or only _b) — ambiguous, skip
  return 1
}

# ---------------------------------------------------------------------------
# Strategy 3: extracted image filenames
#  system_a.img → AB or VAB (check lpdump log for VAB upgrade)
#  system.img   → A
# ---------------------------------------------------------------------------
_slot_from_extracted_images() {
  [[ -d "$EXTRACTED" ]] || return 1

  if [[ -f "$EXTRACTED/system_a.img" || -f "$EXTRACTED/system_b.img" ]]; then
    # Check if lpdump already confirmed VAB so we can report correctly
    for ldlog in "$LOGS/lpdump.log" "$LOGS/lpdump_probe.log" \
                 "$LOGS/lpdump_meta_probe.log" "$LOGS/lpdump_slot_probe.log"; do
      if [[ -f "$ldlog" ]] && grep -qiE "^\s*Virtual AB:\s*true" "$ldlog"; then
        printf 'VAB'
        return 0
      fi
    done
    printf 'AB'
    return 0
  fi

  if [[ -f "$EXTRACTED/system.img" ]]; then
    printf 'A'
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Strategy 4: build.prop (high-trust — reads actual device properties)
#  ro.virtual_ab.enabled=true  → VAB (can upgrade AB → VAB)
#  ro.boot.slot_suffix=_a      → AB  (only if no VAB flag)
#  neither                     → A
# ---------------------------------------------------------------------------
_slot_from_build_prop() {
  local bp=""
  for candidate in \
      "$EXTRACTED/system/build.prop" \
      "$EXTRACTED/system/system/build.prop"; do
    [[ -f "$candidate" ]] && bp="$candidate" && break
  done
  [[ -n "$bp" ]] || return 1

  local virtual_ab slot_suffix
  virtual_ab=$(grep -m1 "^ro\.virtual_ab\.enabled=" "$bp" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
  slot_suffix=$(grep -m1 "^ro\.boot\.slot_suffix=" "$bp" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)

  if [[ "$virtual_ab" == "true" ]]; then
    printf 'VAB'
    return 0
  fi

  if [[ -n "$slot_suffix" ]]; then
    printf 'AB'
    return 0
  fi

  printf 'A'
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 5: DYNAMIC_PARTITION_GROUP_NAME heuristic
#  qti_dynamic_partitions_a → AB (conservative; may be upgraded later)
#  qti_dynamic_partitions   → A
# ---------------------------------------------------------------------------
_slot_from_group_name() {
  local group="${DYNAMIC_PARTITION_GROUP_NAME:-}"
  [[ -n "$group" ]] || return 1

  if [[ "$group" == *_a || "$group" == *_b ]]; then
    printf 'AB'
    return 0
  fi

  printf 'A'
  return 0
}

# ---------------------------------------------------------------------------
# _run_lpdump_strategy — run lpdump on a super.img candidate and process result
# ---------------------------------------------------------------------------
_run_lpdump_strategy() {
  local candidate="$1"
  local log_dest="$2"

  command -v lpdump >/dev/null 2>&1 || return 1
  [[ -f "$candidate" ]] || return 1

  lpdump "$candidate" > "$log_dest" 2>&1 || return 1

  # Opportunistically capture SUPER_SIZE from block device table
  if [[ -z "${SUPER_SIZE:-}" ]]; then
    local sz
    sz="$(_parse_super_size_from_lpdump_log "$log_dest" || true)"
    if [[ -n "${sz:-}" ]]; then
      SUPER_SIZE="$sz"
      export SUPER_SIZE
      _slot_log "Captured SUPER_SIZE=$SUPER_SIZE from lpdump block device table"
    fi
  fi

  local mode
  mode="$(_slot_from_lpdump "$log_dest")"
  _is_valid_slot_mode "$mode" || return 1
  printf '%s' "$mode"
  return 0
}

# ---------------------------------------------------------------------------
# Main public function: detect_slot_mode
#
#  Called from main.sh AFTER payload extraction.
#  Runs all strategies and applies the most authoritative result.
#
#  NOTE: Only a device profile .conf value (set before this function runs)
#  is treated as ground truth and skips detection entirely.
#  Any SUPER_SLOT_MODE set by lower-trust sources (OTA metadata, probe hints)
#  is treated as an unconfirmed hint and will be re-evaluated here.
# ---------------------------------------------------------------------------

detect_slot_mode() {
  # Trust device profile .conf only — NOT auto-probe hints from OTA metadata.
  # The device profile has SUPER_SLOT_MODE set explicitly by the maintainer.
  if [[ "${_DEVICE_PROFILE_LOADED:-false}" == "true" ]] && \
     _is_valid_slot_mode "${SUPER_SLOT_MODE:-}"; then
    _slot_log "SUPER_SLOT_MODE='$SUPER_SLOT_MODE' from device profile — skipping detection"
    export SUPER_SLOT_MODE
    return 0
  fi

  _slot_log "Running slot detection (strategies: lpdump → build.prop → payload_list → image_names → group_name)"

  # State variables (local to this invocation)
  local _SLOT_DETECTED=""
  local _SLOT_SOURCE=""

  # ── Strategy 1: lpdump on any available super.img (highest trust) ─────────
  local super_candidates=(
    "$EXTRACTED/super.img"
    "$INPUT/super.img"
    "$INPUT/super_raw.img"
    "$WORKSPACE/super.img"
  )
  for candidate in "${super_candidates[@]}"; do
    local tmp_log="$LOGS/lpdump_slot_detect_$(basename "$candidate" .img).log"
    local m
    m="$(_run_lpdump_strategy "$candidate" "$tmp_log" || true)"
    if _is_valid_slot_mode "$m"; then
      _apply_slot_candidate "lpdump($(basename "$candidate"))" "$m"
      # lpdump is highest trust — if it says VAB, we're done
      [[ "$_SLOT_DETECTED" == "VAB" ]] && break
    fi
  done

  # ── Strategy 2: build.prop (high trust — can upgrade AB→VAB) ─────────────
  local m
  m="$(_slot_from_build_prop || true)"
  if _is_valid_slot_mode "$m"; then
    _apply_slot_candidate "build.prop" "$m"
  fi

  # ── Strategy 3: payload-dumper-go --list ──────────────────────────────────
  if [[ "$_SLOT_DETECTED" != "VAB" ]]; then
    for payload_candidate in "$INPUT/payload.bin" "$INPUT/ota/payload.bin"; do
      m="$(_slot_from_payload_list "$payload_candidate" || true)"
      if _is_valid_slot_mode "$m"; then
        _apply_slot_candidate "payload_list($(basename "$payload_candidate"))" "$m"
        break
      fi
    done
  fi

  # ── Strategy 4: extracted image filenames ─────────────────────────────────
  if [[ -z "$_SLOT_DETECTED" ]]; then
    m="$(_slot_from_extracted_images || true)"
    if _is_valid_slot_mode "$m"; then
      _apply_slot_candidate "extracted_images" "$m"
    fi
  fi

  # ── Strategy 5: group name heuristic (lowest trust) ───────────────────────
  if [[ -z "$_SLOT_DETECTED" ]]; then
    m="$(_slot_from_group_name || true)"
    if _is_valid_slot_mode "$m"; then
      _apply_slot_candidate "group_name_heuristic" "$m"
    fi
  fi

  # ── Fallback ──────────────────────────────────────────────────────────────
  if [[ -z "$_SLOT_DETECTED" ]]; then
    _slot_warn "All strategies failed — defaulting to VAB (safest for modern Xiaomi/HyperOS)"
    _SLOT_DETECTED="VAB"
    _SLOT_SOURCE="fallback_default"
  fi

  SUPER_SLOT_MODE="$_SLOT_DETECTED"
  export SUPER_SLOT_MODE

  _slot_log "Final SUPER_SLOT_MODE='$SUPER_SLOT_MODE' (source: $_SLOT_SOURCE)"
}

# ---------------------------------------------------------------------------
# Public helper: human-readable description of the detected mode
# ---------------------------------------------------------------------------
describe_slot_mode() {
  case "${SUPER_SLOT_MODE:-}" in
    A)   printf 'A-only (no slots — single partition copy)\n' ;;
    AB)  printf 'A/B (two physical slot copies — _a and _b)\n' ;;
    VAB) printf 'Virtual A/B (one physical copy, virtual snapshots for OTA)\n' ;;
    *)   printf 'unknown\n' ;;
  esac
}
