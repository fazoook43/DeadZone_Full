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
#  Called by:  main.sh (after payload is extracted, before build_super_image)
#  Safe to call multiple times — skips if SUPER_SLOT_MODE already set to a
#  valid value via device profile.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_slot_log()  { log  "[slot_detect] $*"; }
_slot_warn() { warn "[slot_detect] $*"; }

# Return 0 if a value is one of the three valid modes
_is_valid_slot_mode() {
  case "${1:-}" in
    A|AB|VAB) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Strategy 1: read lpdump output from an existing super image
#  lpdump prints:
#    Virtual AB: true/false
#    Groups:
#      Name: qti_dynamic_partitions_a
#      Name: qti_dynamic_partitions_b
#      ...
# ---------------------------------------------------------------------------

_slot_from_lpdump() {
  local dump_file="$1"

  [[ -s "$dump_file" ]] || return 1

  # Virtual A/B
  if grep -qi "Virtual AB: *true" "$dump_file"; then
    printf 'VAB'
    return 0
  fi

  # A/B — two groups with _a / _b suffix
  local group_count_a group_count_b
  group_count_a=$(grep -c "Name:.*_a$" "$dump_file" 2>/dev/null || true)
  group_count_b=$(grep -c "Name:.*_b$" "$dump_file" 2>/dev/null || true)

  if (( group_count_a > 0 && group_count_b > 0 )); then
    printf 'AB'
    return 0
  fi

  # Check partition entries for _a/_b suffixes
  local part_a part_b
  part_a=$(grep -c "^  Name:.*_a$" "$dump_file" 2>/dev/null || true)
  part_b=$(grep -c "^  Name:.*_b$" "$dump_file" 2>/dev/null || true)

  if (( part_a > 0 && part_b > 0 )); then
    printf 'AB'
    return 0
  fi

  # No _a/_b suffixes anywhere → A-only
  printf 'A'
  return 0
}

# ---------------------------------------------------------------------------
# Strategy 2: inspect payload.bin directly via payload-dumper-go --list
#  Modern versions print slot info in their manifest JSON or partition names
# ---------------------------------------------------------------------------

_slot_from_payload_list() {
  local payload="$1"
  [[ -f "$payload" ]] || return 1
  command -v payload-dumper-go >/dev/null 2>&1 || return 1

  local tmp_list
  tmp_list="$(mktemp)"
  payload-dumper-go --list "$payload" > "$tmp_list" 2>&1 || { rm -f "$tmp_list"; return 1; }

  # Partition names like system_a / system_b → AB or VAB
  local has_a has_b
  has_a=$(grep -c "_a$" "$tmp_list" 2>/dev/null || true)
  has_b=$(grep -c "_b$" "$tmp_list" 2>/dev/null || true)
  rm -f "$tmp_list"

  if (( has_a > 0 && has_b > 0 )); then
    # Can't distinguish AB vs VAB from names alone; return AB as safe default
    # (VAB is handled by lpdump strategy which has richer info)
    printf 'AB'
    return 0
  fi

  if (( has_a == 0 && has_b == 0 )); then
    printf 'A'
    return 0
  fi

  return 1  # ambiguous
}

# ---------------------------------------------------------------------------
# Strategy 3: inspect extracted partition image names
#  After payload-dumper-go runs, we may have:
#    system.img          → A-only
#    system_a.img        → AB/VAB
# ---------------------------------------------------------------------------

_slot_from_extracted_images() {
  [[ -d "$EXTRACTED" ]] || return 1

  local has_a_img has_plain_img
  has_a_img=0
  has_plain_img=0

  # Check the primary dynamic partition (system is always present)
  if [[ -f "$EXTRACTED/system_a.img" || -f "$EXTRACTED/system_b.img" ]]; then
    has_a_img=1
  fi
  if [[ -f "$EXTRACTED/system.img" ]]; then
    has_plain_img=1
  fi

  if (( has_a_img == 1 )); then
    # Check lpdump log for VAB flag
    if [[ -f "$LOGS/lpdump.log" ]] && grep -qi "Virtual AB: *true" "$LOGS/lpdump.log"; then
      printf 'VAB'
    else
      printf 'AB'
    fi
    return 0
  fi

  if (( has_plain_img == 1 )); then
    printf 'A'
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Strategy 4: check lpdump on extracted super.img (if present)
# ---------------------------------------------------------------------------

_slot_from_extracted_super() {
  command -v lpdump >/dev/null 2>&1 || return 1

  local candidate
  for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img"; do
    [[ -f "$candidate" ]] || continue

    local tmp_dump
    tmp_dump="$LOGS/lpdump_slot_detect.log"
    lpdump "$candidate" > "$tmp_dump" 2>&1 || continue

    local mode
    mode="$(_slot_from_lpdump "$tmp_dump")"
    if _is_valid_slot_mode "$mode"; then
      printf '%s' "$mode"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# Strategy 5: heuristic from DYNAMIC_PARTITION_GROUP_NAME
#   qti_dynamic_partitions_a → AB/VAB
#   qti_dynamic_partitions   → A-only
# ---------------------------------------------------------------------------

_slot_from_group_name() {
  local group="${DYNAMIC_PARTITION_GROUP_NAME:-}"
  [[ -n "$group" ]] || return 1

  if [[ "$group" == *_a || "$group" == *_b ]]; then
    # VAB can't be determined here, default to AB
    printf 'AB'
    return 0
  fi

  # Single group name → A-only
  printf 'A'
  return 0
}

# ---------------------------------------------------------------------------
# Main public function: detect_slot_mode
# ---------------------------------------------------------------------------

detect_slot_mode() {
  # If device profile already set a valid mode, trust it
  if _is_valid_slot_mode "${SUPER_SLOT_MODE:-}"; then
    _slot_log "SUPER_SLOT_MODE already set to '$SUPER_SLOT_MODE' (from device profile)"
    export SUPER_SLOT_MODE
    return 0
  fi

  _slot_log "Auto-detecting slot mode …"

  local detected=""

  # 1. Try lpdump on any available super image
  if [[ -z "$detected" ]]; then
    for candidate in "$EXTRACTED/super.img" "$INPUT/super.img" "$INPUT/super_raw.img" "$WORKSPACE/super.img"; do
      [[ -f "$candidate" ]] || continue
      if command -v lpdump >/dev/null 2>&1; then
        local tmp_ld="$LOGS/lpdump_slot_probe.log"
        lpdump "$candidate" > "$tmp_ld" 2>&1 || true
        local m
        m="$(_slot_from_lpdump "$tmp_ld")"
        if _is_valid_slot_mode "$m"; then
          detected="$m"
          _slot_log "Strategy lpdump($candidate): $detected"
          break
        fi
      fi
    done
  fi

  # 2. payload-dumper-go --list
  if [[ -z "$detected" ]]; then
    local payload_candidate
    for payload_candidate in "$INPUT/payload.bin" "$INPUT/ota/payload.bin"; do
      [[ -f "$payload_candidate" ]] || continue
      local m
      m="$(_slot_from_payload_list "$payload_candidate")" || continue
      if _is_valid_slot_mode "$m"; then
        detected="$m"
        _slot_log "Strategy payload_list($payload_candidate): $detected"
        break
      fi
    done
  fi

  # 3. Extracted image names
  if [[ -z "$detected" ]]; then
    local m
    m="$(_slot_from_extracted_images)" || true
    if _is_valid_slot_mode "$m"; then
      detected="$m"
      _slot_log "Strategy extracted_images: $detected"
    fi
  fi

  # 4. Extracted super.img
  if [[ -z "$detected" ]]; then
    local m
    m="$(_slot_from_extracted_super)" || true
    if _is_valid_slot_mode "$m"; then
      detected="$m"
      _slot_log "Strategy extracted_super: $detected"
    fi
  fi

  # 5. Group name heuristic
  if [[ -z "$detected" ]]; then
    local m
    m="$(_slot_from_group_name)" || true
    if _is_valid_slot_mode "$m"; then
      detected="$m"
      _slot_log "Strategy group_name_heuristic: $detected"
    fi
  fi

  if [[ -z "$detected" ]]; then
    _slot_warn "Could not auto-detect slot mode; defaulting to VAB (safest for Xiaomi/HyperOS)"
    detected="VAB"
  fi

  SUPER_SLOT_MODE="$detected"
  export SUPER_SLOT_MODE

  _slot_log "Final SUPER_SLOT_MODE = $SUPER_SLOT_MODE"
}

# ---------------------------------------------------------------------------
# Public helper: print a human-readable description of the detected mode
# ---------------------------------------------------------------------------

describe_slot_mode() {
  case "${SUPER_SLOT_MODE:-}" in
    A)   printf 'A-only (no slots — single partition copy)\n' ;;
    AB)  printf 'A/B (two physical slot copies — _a and _b)\n' ;;
    VAB) printf 'Virtual A/B (one physical copy, virtual snapshots for OTA)\n' ;;
    *)   printf 'unknown\n' ;;
  esac
}
