#!/usr/bin/env bash
# core/partition_layout_detector.sh
# Smart detector for Android partition slot layout:
#   A-only  — single slot, no _a/_b suffixes in LP metadata
#   A/B     — two slots (traditional A/B, no virtual-ab)
#   VAB     — Virtual A/B (retrofit or native)
#
# Detection strategy (in order of confidence):
#   1. lpdump on source super.img  — highest confidence
#   2. Presence of _a/_b images in extracted dir
#   3. Device profile SUPER_SLOT_MODE if already set
#   4. Fallback: warn and assume VAB (safest for modern Xiaomi/HyperOS)
#
# Exported variables:
#   SUPER_SLOT_MODE        A | AB | VAB
#   PARTITION_SUFFIX       _a (A/AB/VAB) | "" (A-only)
#   FASTBOOT_SLOT_MODE     ab_suffix | single
# LF normalized for GitHub raw
set -euo pipefail

# ---------------------------------------------------------------------------
# detect_slot_layout
#   Main entry point. Runs all detection strategies and exports SUPER_SLOT_MODE.
#   Always logs every decision step for auditability.
# ---------------------------------------------------------------------------
detect_slot_layout() {
  log "=== Partition Layout Detection ==="

  # Strategy 1: lpdump on the source super.img
  if _detect_layout_from_lpdump; then
    log "Layout detection: SUCCESS via lpdump"
    _apply_layout_exports
    return 0
  fi

  # Strategy 2: Presence of _a/_b images in $EXTRACTED
  if _detect_layout_from_image_names; then
    log "Layout detection: SUCCESS via image name heuristic"
    _apply_layout_exports
    return 0
  fi

  # Strategy 3: Already set in device profile — honour it
  if [[ -n "${SUPER_SLOT_MODE:-}" ]]; then
    log "Layout detection: using SUPER_SLOT_MODE from device profile: $SUPER_SLOT_MODE"
    _apply_layout_exports
    return 0
  fi

  # Strategy 4: Fallback
  warn "Could not determine partition layout from any source."
  warn "Defaulting to VAB (safest for HyperOS/MIUI Snapdragon & MediaTek)."
  warn "Override in devices/$DEVICE_CODENAME.conf → SUPER_SLOT_MODE=A|AB|VAB"
  export SUPER_SLOT_MODE="VAB"
  _apply_layout_exports
}

# ---------------------------------------------------------------------------
# _detect_layout_from_lpdump
#   Parses lpdump output from source super.img.
#   Returns 0 and sets SUPER_SLOT_MODE on success, 1 on failure.
# ---------------------------------------------------------------------------
_detect_layout_from_lpdump() {
  command -v lpdump >/dev/null 2>&1 || {
    warn "lpdump not available — skipping LP metadata layout detection"
    return 1
  }

  # Prefer the already-dumped log if it exists, else dump now
  local dump_log="$LOGS/lpdump_source_super.log"
  local super_img="$EXTRACTED/super.img"

  if [[ ! -s "$dump_log" ]]; then
    [[ -f "$super_img" ]] || {
      log "source super.img not present in extracted dir — skipping lpdump layout detection"
      return 1
    }
    log "Running lpdump on source super.img for layout detection"
    lpdump "$super_img" > "$dump_log" 2>&1 || {
      warn "lpdump failed on source super.img — cannot detect layout via lpdump"
      return 1
    }
  fi

  local has_virtual_ab=false
  local has_b_group=false
  local has_a_suffix=false
  local has_no_suffix=false
  local group_count=0

  # Check for virtual-ab flag
  if grep -qi "virtual_ab\|VirtualAB\|Flags:.*virtual" "$dump_log"; then
    has_virtual_ab=true
  fi

  # Count partition groups
  group_count="$(grep -c "^Group:" "$dump_log" 2>/dev/null || true)"

  # Check if any group is named *_b or contains _b partitions
  if grep -qi "_b\b" "$dump_log"; then
    has_b_group=true
  fi

  # Check if partitions have _a suffix
  if grep -qiE "^\s+Name:\s+\w+_a\b" "$dump_log" 2>/dev/null; then
    has_a_suffix=true
  fi

  # Check if any partition has NO suffix (A-only pattern)
  # A-only: "system", "vendor" etc without _a/_b
  if grep -qiE "^\s+Name:\s+(system|vendor|product)\s*$" "$dump_log" 2>/dev/null; then
    has_no_suffix=true
  fi

  log "lpdump analysis → virtual_ab=$has_virtual_ab b_group=$has_b_group a_suffix=$has_a_suffix no_suffix=$has_no_suffix groups=$group_count"

  if [[ "$has_virtual_ab" == "true" ]]; then
    export SUPER_SLOT_MODE="VAB"
    log "Detected: VAB (Virtual A/B) — virtual-ab flag present in LP metadata"
    return 0
  fi

  if [[ "$has_b_group" == "true" || "$has_a_suffix" == "true" ]]; then
    export SUPER_SLOT_MODE="AB"
    log "Detected: A/B — _a/_b groups/partitions present in LP metadata (no virtual-ab flag)"
    return 0
  fi

  if [[ "$has_no_suffix" == "true" ]]; then
    export SUPER_SLOT_MODE="A"
    log "Detected: A-only — partitions have no slot suffix in LP metadata"
    return 0
  fi

  warn "lpdump output did not match any known layout pattern — falling through"
  return 1
}

# ---------------------------------------------------------------------------
# _detect_layout_from_image_names
#   Looks at extracted *.img filenames for _a/_b suffix patterns.
#   Less reliable than lpdump but works when lpdump is absent.
# ---------------------------------------------------------------------------
_detect_layout_from_image_names() {
  local count_a count_b count_plain

  count_a="$(find "$EXTRACTED" -maxdepth 1 -name '*_a.img' | wc -l)"
  count_b="$(find "$EXTRACTED" -maxdepth 1 -name '*_b.img' | wc -l)"
  count_plain="$(find "$EXTRACTED" -maxdepth 1 -name '*.img' ! -name '*_a.img' ! -name '*_b.img' | wc -l)"

  log "Image name heuristic → _a images=$count_a  _b images=$count_b  plain images=$count_plain"

  if (( count_a > 0 && count_b > 0 )); then
    # Both slots present — could be AB or VAB; default to VAB for safety
    export SUPER_SLOT_MODE="VAB"
    log "Detected: VAB (assumed) — both _a and _b suffixed images present"
    log "  If device is standard A/B (not virtual), set SUPER_SLOT_MODE=AB in device profile"
    return 0
  fi

  if (( count_a > 0 && count_b == 0 )); then
    # Only _a suffix present — A/B with active slot a, no _b images in package
    export SUPER_SLOT_MODE="AB"
    log "Detected: A/B — _a suffixed images present, no _b images"
    return 0
  fi

  if (( count_plain > 0 && count_a == 0 && count_b == 0 )); then
    export SUPER_SLOT_MODE="A"
    log "Detected: A-only — no _a/_b suffix on any extracted image"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# _apply_layout_exports
#   After SUPER_SLOT_MODE is known, derives and exports the dependent vars.
# ---------------------------------------------------------------------------
_apply_layout_exports() {
  case "${SUPER_SLOT_MODE:-VAB}" in
    A)
      export PARTITION_SUFFIX="${PARTITION_SUFFIX:-}"
      export FASTBOOT_SLOT_MODE="${FASTBOOT_SLOT_MODE:-single}"
      export SUPER_ACTIVE_SLOT="${SUPER_ACTIVE_SLOT:-a}"
      ;;
    AB|VAB)
      export PARTITION_SUFFIX="${PARTITION_SUFFIX:-_a}"
      export FASTBOOT_SLOT_MODE="${FASTBOOT_SLOT_MODE:-ab_suffix}"
      export SUPER_ACTIVE_SLOT="${SUPER_ACTIVE_SLOT:-a}"
      ;;
    *)
      die "Unknown SUPER_SLOT_MODE=$SUPER_SLOT_MODE in _apply_layout_exports"
      ;;
  esac

  log "Layout exports: SUPER_SLOT_MODE=$SUPER_SLOT_MODE  PARTITION_SUFFIX=${PARTITION_SUFFIX:-<empty>}  FASTBOOT_SLOT_MODE=$FASTBOOT_SLOT_MODE  SUPER_ACTIVE_SLOT=$SUPER_ACTIVE_SLOT"
}

# ---------------------------------------------------------------------------
# print_slot_layout_summary
#   Prints a human-readable table of the detected layout.
# ---------------------------------------------------------------------------
print_slot_layout_summary() {
  section "Partition Layout Summary"
  printf '  %-30s %s\n' "Slot mode:"         "${SUPER_SLOT_MODE:-unknown}"
  printf '  %-30s %s\n' "Active slot:"       "${SUPER_ACTIVE_SLOT:-a}"
  printf '  %-30s %s\n' "Partition suffix:"  "${PARTITION_SUFFIX:-(none — A-only)}"
  printf '  %-30s %s\n' "Fastboot slot mode:" "${FASTBOOT_SLOT_MODE:-unknown}"
  printf '  %-30s %s\n' "SUPER_SIZE:"        "${SUPER_SIZE:-unknown} bytes"
  printf '  %-30s %s\n' "Group size:"        "${DYNAMIC_PARTITION_GROUP_SIZE:-unknown} bytes"
  echo
}
