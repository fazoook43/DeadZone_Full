#!/usr/bin/env bash
# LF normalized for GitHub raw
set -euo pipefail

validate_super_zst() {
  [[ -s "$OUTPUT/images/super.img" ]] || die "output/images/super.img is missing or empty"
  [[ -s "$OUTPUT/super.img.zst"    ]] || die "output/super.img.zst is missing or empty"
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
  for secret in "${PIXELDRAIN_API_KEY:-}" "${TELEGRAM_BOT_TOKEN:-}" \
                "${TELEGRAM_CHAT_ID:-}"   "${GITHUB_TOKEN:-}"; do
    [[ -n "$secret" ]] || continue
    if grep -R --binary-files=without-match -F "$secret" \
          "$LOGS" "$OUTPUT_FINAL" >/dev/null 2>&1; then
      die "A configured secret appears in generated logs or output files"
    fi
  done
}

validate_build() {
  local zip_file
  zip_file="$(final_zip_path)"

  [[ -s "$OUTPUT/images/super.img" ]] || die "output/images/super.img is missing or empty"

  if [[ "${SUPER_OUTPUT_FORMAT:-sparse}" == "sparse" ]]; then
    [[ -s "$LOGS/super_metadata.img" ]] || \
      die "Sparse super metadata validation image is missing"
    [[ -s "$LOGS/lpdump_super.txt"   ]] || \
      die "Sparse super lpdump validation log is missing"
  else
    require_tool lpdump
    lpdump "$OUTPUT/images/super.img" >/dev/null 2>&1 || die "lpdump validation failed"
  fi

  local slot_mode="${SUPER_SLOT_MODE:-A}"

  case "$slot_mode" in
    A)
      # A-only: check plain (possibly suffixed) partition names
      local part
      for part in $DYNAMIC_PARTITIONS; do
        local lp_name="${part}${PARTITION_SUFFIX:-}"
        grep -q "$lp_name" "$LOGS/lpdump_super.txt" || \
          die "A-only metadata missing partition entry: $lp_name"
      done
      ;;

    AB|VAB)
      local active_slot="${SUPER_ACTIVE_SLOT:-a}"
      local inactive_slot
      case "$active_slot" in
        a) inactive_slot="b" ;;
        b) inactive_slot="a" ;;
        *) die "Unsupported SUPER_ACTIVE_SLOT=$active_slot" ;;
      esac

      local part
      for part in $DYNAMIC_PARTITIONS; do
        grep -q "${part}_${active_slot}"   "$LOGS/lpdump_super.txt" || \
          die "$slot_mode metadata missing active partition: ${part}_${active_slot}"
        grep -q "${part}_${inactive_slot}" "$LOGS/lpdump_super.txt" || \
          die "$slot_mode metadata missing inactive partition: ${part}_${inactive_slot}"
      done
      ;;
  esac

  log "validate_build passed (slot_mode=$slot_mode)"
}
