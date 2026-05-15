#!/usr/bin/env bash
set -euo pipefail

source "$WORKSPACE/core/debloat_profiles.sh"

PATCH_ROOT="${PATCH_ROOT:-$OUTPUT/patch_root}"
DEADZONE_PATCH_REPORT="${DEADZONE_PATCH_REPORT:-$LOGS/deadzone_patch_report.txt}"
DEADZONE_OAT_REMOVED_COUNT=0
DEADZONE_REMOVED_APP_KEYS=()
DEADZONE_REPORT_REMOVED_EXACT_PATHS=()
DEADZONE_REPORT_REMOVED_SEARCH_MATCHES=()
DEADZONE_REPORT_NOT_FOUND_APPS=()
DEADZONE_REPORT_MOVED_PATHS=()
DEADZONE_REPORT_PROPS_CHANGED=()
DEADZONE_REPORT_OTA_DISABLED_FILES=()
DEADZONE_REPORT_PRIVAPP_PROP_REMOVED_FILES=()
DEADZONE_REPORT_REPACKED_PARTITIONS=()

DEADZONE_APP_SEARCH_ROOTS=(
  "product/app"
  "product/priv-app"
  "product/data-app"
  "system/system/app"
  "system/system/priv-app"
  "system/app"
  "system/priv-app"
  "system_ext/app"
  "system_ext/priv-app"
  "mi_ext/product/app"
  "mi_ext/product/priv-app"
  "mi_ext/product/data-app"
  "vendor/app"
  "vendor/priv-app"
  "odm/app"
  "odm/priv-app"
)

_rom_path() {
  local rel="$1"
  rel="${rel#/}"
  printf '%s/%s\n' "$PATCH_ROOT" "$rel"
}

_touch_partition_by_rel() {
  local rel="${1#/}"
  local part="${rel%%/*}"
  mkdir -p "$PATCH_ROOT/.changed"
  : > "$PATCH_ROOT/.changed/$part"
}

_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

_mark_app_removed_key() {
  local key
  key="$(_lower "$1")"
  _array_contains "$key" "${DEADZONE_REMOVED_APP_KEYS[@]}" || DEADZONE_REMOVED_APP_KEYS+=("$key")
}

_was_app_removed() {
  local alias
  for alias in "$@"; do
    _array_contains "$(_lower "$alias")" "${DEADZONE_REMOVED_APP_KEYS[@]}" && return 0
  done
  return 1
}

_is_safe_contains_alias() {
  local alias="$1"
  _array_contains "$alias" "${DEBLOAT_SAFE_CONTAINS_ALIASES[@]:-}"
}

_count_oat_artifacts_for_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || {
    printf '0\n'
    return 0
  }

  find "$dir" \( \
    -type d \( -name oat -o -name arm -o -name arm64 -o -name lib \) -o \
    -type f \( \
      -name '*.odex' -o \
      -name '*.vdex' -o \
      -name '*.art' -o \
      -name '*.prof' -o \
      -name '*.dm' \
    \) \
  \) -print 2>/dev/null | wc -l | tr -d ' '
}

_remove_oat_for_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local count
  count="$(_count_oat_artifacts_for_dir "$dir")"
  DEADZONE_OAT_REMOVED_COUNT=$((DEADZONE_OAT_REMOVED_COUNT + count))

  find "$dir" -type d \( -name oat -o -name arm -o -name arm64 -o -name lib \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$dir" -type f \( \
    -name '*.odex' -o \
    -name '*.vdex' -o \
    -name '*.art' -o \
    -name '*.prof' -o \
    -name '*.dm' \
  \) -delete 2>/dev/null || true
}

_safe_remove_path() {
  local rel="${1#/}"
  local abs
  abs="$(_rom_path "$rel")"

  [[ -e "$abs" ]] || return 0

  case "$rel" in
    product/app/*|product/priv-app/*|product/data-app/*|\
mi_ext/product/app/*|mi_ext/product/priv-app/*|mi_ext/product/data-app/*|\
system/system/app/*|system/system/priv-app/*|system/app/*|system/priv-app/*|\
system_ext/app/*|system_ext/priv-app/*|vendor/app/*|vendor/priv-app/*|\
odm/app/*|odm/priv-app/*|system_ext/cust)
      ;;
    *)
      die "Refusing unsafe debloat path: $rel"
      ;;
  esac

  log "Debloat remove: /$rel"
  _remove_oat_for_dir "$abs"
  rm -rf "$abs"
  DEADZONE_REPORT_REMOVED_EXACT_PATHS+=("$rel")
  _mark_app_removed_key "$(basename "$rel")"
  _touch_partition_by_rel "$rel"
}

_apk_path_matches_alias() {
  local app_dir="$1"
  local alias="$2"
  local alias_l apk apk_base apk_base_l apk_path_l
  alias_l="$(_lower "$alias")"

  while IFS= read -r -d '' apk; do
    apk_base="$(basename "$apk" .apk)"
    apk_base_l="$(_lower "$apk_base")"
    apk_path_l="$(_lower "${apk#$PATCH_ROOT/}")"
    if [[ "$apk_base" == "$alias" || "$apk_base_l" == "$alias_l" || "$apk_path_l" == *"/$alias_l/"* || "$apk_path_l" == *"/$alias_l.apk" ]]; then
      return 0
    fi
  done < <(find "$app_dir" -maxdepth 3 -type f -name '*.apk' -print0 2>/dev/null)

  return 1
}

_app_dir_matches_alias() {
  local app_dir="$1"
  local alias="$2"
  local base base_l alias_l rel_l
  base="$(basename "$app_dir")"
  base_l="$(_lower "$base")"
  alias_l="$(_lower "$alias")"
  rel_l="$(_lower "${app_dir#$PATCH_ROOT/}")"

  [[ "$base" == "$alias" || "$base_l" == "$alias_l" ]] && return 0
  [[ "$rel_l" == *"/$alias_l/"* || "$rel_l" == *"/$alias_l" ]] && return 0
  _apk_path_matches_alias "$app_dir" "$alias" && return 0

  if _is_safe_contains_alias "$alias"; then
    [[ "$base_l" == *"$alias_l"* || "$rel_l" == *"$alias_l"* ]] && return 0
  fi

  return 1
}

search_remove_app_with_oat() {
  local canonical="$1"
  shift || true
  local aliases=("$canonical" "$@")
  local matches=()
  local root root_abs app_dir alias rel match_key

  for root in "${DEADZONE_APP_SEARCH_ROOTS[@]}"; do
    root_abs="$(_rom_path "$root")"
    [[ -d "$root_abs" ]] || continue

    while IFS= read -r -d '' app_dir; do
      for alias in "${aliases[@]}"; do
        [[ -n "$alias" ]] || continue
        if _app_dir_matches_alias "$app_dir" "$alias"; then
          match_key="${app_dir#$PATCH_ROOT/}"
          _array_contains "$match_key" "${matches[@]}" || matches+=("$match_key")
          break
        fi
      done
    done < <(find "$root_abs" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  done

  if (( ${#matches[@]} == 0 )); then
    if ! _was_app_removed "${aliases[@]}"; then
      warn "Debloat search not found: $canonical"
      DEADZONE_REPORT_NOT_FOUND_APPS+=("$canonical")
    fi
    return 0
  fi

  for rel in "${matches[@]}"; do
    app_dir="$(_rom_path "$rel")"
    [[ -e "$app_dir" ]] || continue
    log "Debloat search remove: $canonical -> /$rel"
    _remove_oat_for_dir "$app_dir"
    rm -rf "$app_dir"
    DEADZONE_REPORT_REMOVED_SEARCH_MATCHES+=("$canonical -> $rel")
    _mark_app_removed_key "$canonical"
    for alias in "${aliases[@]}"; do
      _mark_app_removed_key "$alias"
    done
    _touch_partition_by_rel "$rel"
  done
}

_prop_append_once() {
  local file="$1"
  local key="$2"
  local line="$3"

  [[ -f "$file" ]] || return 0

  if grep -qE "^${key//./\\.}=" "$file"; then
    sed -i -E "s|^${key//./\\.}=.*|$line|" "$file"
  else
    echo "$line" >> "$file"
  fi
  DEADZONE_REPORT_PROPS_CHANGED+=("${file#$PATCH_ROOT/}:$key")
}

_extract_os_base_version() {
  local text="${ROM_VERSION:-} ${ROM_URL:-}"
  local base
  base="$(printf '%s\n' "$text" | grep -oE 'OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [[ -n "$base" ]] || base="${ROM_VERSION:-OS3.0.303.0}"
  printf '%s\n' "$base"
}

patch_privapp_permissions() {
  local file changed=0
  for file in \
    "$PATCH_ROOT/vendor/build.prop" \
    "$PATCH_ROOT/vendor/etc/build.prop" \
    "$PATCH_ROOT/system/system/build.prop" \
    "$PATCH_ROOT/system/build.prop"; do
    [[ -f "$file" ]] || continue
    if grep -q '^ro.control_privapp_permissions=' "$file"; then
      log "Patch priv-app permissions: removing ro.control_privapp_permissions from ${file#$PATCH_ROOT/}"
      sed -i '/^ro.control_privapp_permissions=/d' "$file"
      changed=1
      DEADZONE_REPORT_PRIVAPP_PROP_REMOVED_FILES+=("${file#$PATCH_ROOT/}")
      case "$file" in
        "$PATCH_ROOT/vendor"/*) _touch_partition_by_rel "vendor/build.prop" ;;
        "$PATCH_ROOT/system"/*) _touch_partition_by_rel "system/build.prop" ;;
      esac
    fi
  done
  [[ "$changed" == "1" ]] || log "Patch priv-app permissions: prop not found, nothing to remove"
}

disable_ota_update() {
  local dir="$PATCH_ROOT/product/etc/device_features"
  [[ -d "$dir" ]] || {
    log "Disable OTA update: product/etc/device_features not found"
    return 0
  }

  local changed=0
  while IFS= read -r -d '' xml; do
    if grep -q 'name="support_ota_validate">true<' "$xml"; then
      log "Disable OTA validate in ${xml#$PATCH_ROOT/}"
      sed -i 's|<bool name="support_ota_validate">true</bool>|<bool name="support_ota_validate">false</bool>|g' "$xml"
      changed=1
      DEADZONE_REPORT_OTA_DISABLED_FILES+=("${xml#$PATCH_ROOT/}")
    fi
  done < <(find "$dir" -type f -name '*.xml' -print0)

  if [[ "$changed" == "1" ]]; then
    _touch_partition_by_rel "product/etc/device_features"
  else
    log "Disable OTA update: support_ota_validate=true not found"
  fi
}

remove_oat_dirs() {
  [[ -d "$PATCH_ROOT" ]] || return 0
  log "Removing oat/odex/vdex/art leftovers"
  local dir f rel
  while IFS= read -r dir; do
    log "Remove oat dir: ${dir#$PATCH_ROOT/}"
    DEADZONE_OAT_REMOVED_COUNT=$((DEADZONE_OAT_REMOVED_COUNT + 1))
    rm -rf "$dir"
    rel="${dir#$PATCH_ROOT/}"
    _touch_partition_by_rel "$rel"
  done < <(find "$PATCH_ROOT" -type d -name oat -prune -print)

  while IFS= read -r f; do
    rel="${f#$PATCH_ROOT/}"
    log "Remove precompiled artifact: $rel"
    DEADZONE_OAT_REMOVED_COUNT=$((DEADZONE_OAT_REMOVED_COUNT + 1))
    rm -f "$f"
    _touch_partition_by_rel "$rel"
  done < <(find "$PATCH_ROOT" -type f \( \
    -name '*.odex' -o \
    -name '*.vdex' -o \
    -name '*.art' -o \
    -name '*.prof' -o \
    -name '*.dm' \
  \) -print)
}

_apply_debloat_search_records() {
  local record canonical aliases joined
  local -a fields
  for record in "$@"; do
    IFS='|' read -r -a fields <<< "$record"
    canonical="${fields[0]:-}"
    [[ -n "$canonical" ]] || continue
    aliases=("${fields[@]:1}")
    search_remove_app_with_oat "$canonical" "${aliases[@]}"
  done
}

_apply_debloat_profile() {
  local region="${ROM_REGION:-Global}"
  local item

  case "$region" in
    China)
      log "Applying China debloat profile"
      for item in "${DEBLOAT_CHINA_PATHS[@]}"; do
        _safe_remove_path "$item"
      done
      _apply_debloat_search_records "${DEBLOAT_CHINA_APPS[@]}"
      ;;
    Global|India)
      log "Applying Global-compatible debloat profile for region=$region"
      for item in "${DEBLOAT_GLOBAL_PATHS[@]}"; do
        _safe_remove_path "$item"
      done
      _apply_debloat_search_records "${DEBLOAT_GLOBAL_APPS[@]}"
      ;;
    *)
      die "Unsupported ROM_REGION for debloat: $region"
      ;;
  esac
}

_move_dir_children() {
  local src_rel="${1#/}"
  local dst_rel="${2#/}"
  local src dst

  src="$(_rom_path "$src_rel")"
  dst="$(_rom_path "$dst_rel")"

  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"

  shopt -s nullglob dotglob
  local item
  for item in "$src"/*; do
    [[ -e "$item" ]] || continue
    log "Move ${item#$PATCH_ROOT/} -> /$dst_rel/"
    rm -rf "$dst/$(basename "$item")"
    mv "$item" "$dst/"
    DEADZONE_REPORT_MOVED_PATHS+=("${item#$PATCH_ROOT/} -> $dst_rel/$(basename "$item")")
  done
  shopt -u nullglob dotglob

  _touch_partition_by_rel "$src_rel"
  _touch_partition_by_rel "$dst_rel"
}

_post_debloat_moves() {
  case "${ROM_REGION:-Global}" in
    China)
      _move_dir_children "product/data-app" "product/app"
      ;;
    Global|India)
      _move_dir_children "mi_ext/product/overlay" "product/overlay"
      _move_dir_children "mi_ext/product/etc/sysconfig" "product/etc/sysconfig"
      _move_dir_children "mi_ext/product/etc/permissions" "product/etc/permissions"
      _move_dir_children "mi_ext/product/app" "product/app"
      _move_dir_children "mi_ext/product/priv-app" "product/priv-app"
      _move_dir_children "mi_ext/product/data-app" "product/data-app"
      ;;
  esac
}

apply_deadzone_build_props() {
  local base display_id
  base="$(_extract_os_base_version)"
  display_id="DeadZoneRomEPiC-${base}-${ROM_REGION:-China}Stable"

  local system_prop=""
  for system_prop in "$PATCH_ROOT/system/system/build.prop" "$PATCH_ROOT/system/build.prop"; do
    [[ -f "$system_prop" ]] || continue
    log "Apply DeadZone system build.prop: ${system_prop#$PATCH_ROOT/}"
    _prop_append_once "$system_prop" "ro.build.display.id" "ro.build.display.id=$display_id"
    _prop_append_once "$system_prop" "ro.build.host" "ro.build.host=MezoDevelopment"
    _prop_append_once "$system_prop" "ro.product.locale" "ro.product.locale=en-US"
    grep -q '^# DeadZoneRomEPiC related props #' "$system_prop" || {
      echo ""
      echo "# DeadZoneRomEPiC related props #"
    } >> "$system_prop"
    _touch_partition_by_rel "system/build.prop"
    break
  done

  local product_prop=""
  for product_prop in "$PATCH_ROOT/product/etc/build.prop" "$PATCH_ROOT/system/product/etc/build.prop"; do
    [[ -f "$product_prop" ]] || continue
    log "Apply DeadZone product build.prop: ${product_prop#$PATCH_ROOT/}"

    _prop_append_once "$product_prop" "persist.sys.precache.appstrs1" "persist.sys.precache.appstrs1=com.whatsapp,com.facebook.katana"
    _prop_append_once "$product_prop" "persist.sys.precache.appstrs2" "persist.sys.precache.appstrs2=com.miui.weather2,com.miui.home,com.android.systemui"
    _prop_append_once "$product_prop" "debug.graphics.game_default_frame_rate.disabled" "debug.graphics.game_default_frame_rate.disabled=1"

    grep -q '^# DeadZoneRomEPiC related props #' "$product_prop" || {
      echo ""
      echo "# DeadZoneRomEPiC related props #"
    } >> "$product_prop"

    local line key
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      _prop_append_once "$product_prop" "$key" "$line"
    done <<'EOF'
ro.product.camera.livephoto.support=3
persist.dbg.ims_volte_enable=1
persist.dbg.volte_avail_ovr=1
persist.dbg.vt_avail_ovr=1
persist.dbg.wfc_avail_ovr=1
persist.data.iwlan.enable=true
persist.data.iwlan=1
persist.rcs.supported=1
persist.radio.calls.on.ims=1
persist.radio.VT_ENABLE=1
ro.config.cpu_boost=1
ro.config.hw_fast_dormancy=1
touch.boost.enabled=1
vendor.display.use_smooth_motion=1
vendor.display.enable_camera_smooth=1
persist.vendor.dpm.loglevel=0
persist.vendor.dpmhalservice.loglevel=0
debug.performance.tuning=1
debug.egl.buffcount=4
persist.vendor.camera.gesture.emoji.support=1
ro.com.google.ime.system_lm_dir=product/usr/share/ime/google/d3_lms/
setupwizard.feature.baseline_setupwizard_enabled=true
ro.com.google.lens.oem_camera_package=com.android.camera
ro.com.google.lens.oem_image_package=com.miui.gallery
ro.setupwizard.rotation_locked=true
setupwizard.theme=glif_v3_light
persist.sys.background_blur_version=2
persist.sys.background_blur_supported=true
persist.sys.background_blur_status_default=false
persist.sys.advanced_visual_release=4
EOF

    _touch_partition_by_rel "product/etc/build.prop"
    break
  done
}

apply_dna_style_patches_to_root() {
  section "DNA-style ROM Patches"
  patch_privapp_permissions
  disable_ota_update
  remove_oat_dirs
  _apply_debloat_profile
  _post_debloat_moves
  apply_deadzone_build_props
}

deadzone_report_mark_repacked_partition() {
  local part="$1"
  _array_contains "$part" "${DEADZONE_REPORT_REPACKED_PARTITIONS[@]}" || DEADZONE_REPORT_REPACKED_PARTITIONS+=("$part")
}

_write_report_list() {
  local title="$1"
  shift
  local items=("$@")
  printf '%s\n' "$title"
  if (( ${#items[@]} == 0 )); then
    printf '  none\n'
    return 0
  fi
  local item
  for item in "${items[@]}"; do
    printf '  - %s\n' "$item"
  done
}

write_deadzone_patch_report() {
  mkdir -p "$LOGS"
  {
    printf 'DeadZone Phase 2 Patch Report\n'
    printf '=============================\n\n'
    printf 'ROM_REGION=%s\n' "${ROM_REGION:-unknown}"
    printf 'PATCH_LEVEL=%s\n' "${PATCH_LEVEL:-none}"
    printf 'PATCH_ROOT=%s\n\n' "$PATCH_ROOT"
    _write_report_list "removed exact paths:" "${DEADZONE_REPORT_REMOVED_EXACT_PATHS[@]}"
    printf '\n'
    _write_report_list "removed search matches:" "${DEADZONE_REPORT_REMOVED_SEARCH_MATCHES[@]}"
    printf '\n'
    _write_report_list "not found apps:" "${DEADZONE_REPORT_NOT_FOUND_APPS[@]}"
    printf '\n'
    _write_report_list "moved paths:" "${DEADZONE_REPORT_MOVED_PATHS[@]}"
    printf '\n'
    _write_report_list "props changed:" "${DEADZONE_REPORT_PROPS_CHANGED[@]}"
    printf '\n'
    _write_report_list "OTA disabled files:" "${DEADZONE_REPORT_OTA_DISABLED_FILES[@]}"
    printf '\n'
    _write_report_list "privapp prop removed files:" "${DEADZONE_REPORT_PRIVAPP_PROP_REMOVED_FILES[@]}"
    printf '\n'
    printf 'oat/art/vdex removed count: %s\n\n' "$DEADZONE_OAT_REMOVED_COUNT"
    _write_report_list "repacked partitions:" "${DEADZONE_REPORT_REPACKED_PARTITIONS[@]}"
  } > "$DEADZONE_PATCH_REPORT"
  log "Patch report written: ${DEADZONE_PATCH_REPORT#$WORKSPACE/}"
}
