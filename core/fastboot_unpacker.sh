#!/usr/bin/env bash
# LF normalized for GitHub raw
# core/fastboot_unpacker.sh
# Handles fastboot ROM ZIPs (contain super.img directly, not payload.bin).
# Auto-detects: super size, slot mode, partition naming, group metadata.
# Generates a ready-to-use device .conf at the end.
set -euo pipefail

# ---------------------------------------------------------------------------
# PUBLIC ENTRY: full fastboot ROM ingestion pipeline
# Called from main.sh instead of the OTA payload path.
# ---------------------------------------------------------------------------
ingest_fastboot_rom() {
  section "Fastboot ROM Ingestion"
  run_step fastboot_detect_structure      _fastboot_detect_structure
  run_step fastboot_extract_super         _fastboot_extract_super
  run_step fastboot_verify_super_size     _fastboot_verify_super_size
  run_step fastboot_read_super_metadata   _fastboot_read_super_metadata
  run_step fastboot_unpack_super          _fastboot_unpack_super
  run_step fastboot_detect_partition_naming _fastboot_detect_partition_naming
  run_step fastboot_build_partitions_tsv  _fastboot_build_partitions_tsv
  run_step fastboot_extract_other_images  _fastboot_extract_other_images
}

# ---------------------------------------------------------------------------
# STEP 1 – Validate that the ZIP looks like a fastboot ROM
# ---------------------------------------------------------------------------
_fastboot_detect_structure() {
  local ext="${ROM_FILE##*.}"
  ext="${ext,,}"
  [[ "$ext" == "zip" ]] || die "Fastboot ROM must be a ZIP file (got .$ext)"

  log "Scanning fastboot ROM ZIP for super.img..."
  # super.img may live at root or inside an images/ subdirectory
  local listing
  listing="$(unzip -l "$ROM_FILE")"
  printf '%s\n' "$listing" > "$LOGS/fastboot_zip_listing.txt"

  if ! printf '%s\n' "$listing" | grep -qE 'super\.img$'; then
    die "No super.img found in ZIP. This does not appear to be a fastboot ROM."
  fi

  log "super.img confirmed in fastboot ZIP"
  log "Full ZIP listing saved to logs/fastboot_zip_listing.txt"
}

# ---------------------------------------------------------------------------
# STEP 2 – Extract super.img; convert sparse→raw when needed
# ---------------------------------------------------------------------------
_fastboot_extract_super() {
  mkdir -p "$INPUT/fastboot" "$LOGS"

  log "Extracting super.img from fastboot ZIP..."

  # Try root-level first, then inside images/ subdirectory
  if ! unzip -q -o "$ROM_FILE" "super.img" -d "$INPUT/fastboot/" 2>/dev/null; then
    # Try with wildcard path
    local inner_path
    inner_path="$(unzip -l "$ROM_FILE" | awk '$NF ~ /super\.img$/ {print $NF}' | head -1)"
    [[ -n "$inner_path" ]] || die "Could not locate super.img path inside ZIP"
    unzip -q -o "$ROM_FILE" "$inner_path" -d "$INPUT/fastboot/" \
      || die "Failed to extract super.img from ZIP"

    # If extracted into a subdirectory, move it up
    local found
    found="$(find "$INPUT/fastboot" -name "super.img" -type f | head -1)"
    [[ -n "$found" ]] || die "super.img disappeared after extraction"
    if [[ "$found" != "$INPUT/fastboot/super.img" ]]; then
      mv "$found" "$INPUT/fastboot/super.img"
    fi
  fi

  local sparse_img="$INPUT/fastboot/super.img"
  [[ -s "$sparse_img" ]] || die "super.img is empty after extraction"

  export FASTBOOT_SPARSE_IMG="$sparse_img"
  export FASTBOOT_SPARSE_SIZE
  FASTBOOT_SPARSE_SIZE="$(stat -c%s "$sparse_img")"
  log "super.img extracted. Sparse/raw file size: $FASTBOOT_SPARSE_SIZE bytes ($(du -h "$sparse_img" | awk '{print $1}'))"

  # Detect sparse and convert to raw so lpdump/lpunpack always see raw format
  if file "$sparse_img" | grep -qi "Android sparse"; then
    log "super.img is Android sparse format — converting to raw with simg2img..."
    require_tool simg2img
    simg2img "$sparse_img" "$INPUT/fastboot/super_raw.img" \
      || die "simg2img failed converting super.img to raw"
    export FASTBOOT_RAW_IMG="$INPUT/fastboot/super_raw.img"
    log "Raw super.img size: $(stat -c%s "$FASTBOOT_RAW_IMG") bytes ($(du -h "$FASTBOOT_RAW_IMG" | awk '{print $1}'))"
  else
    log "super.img is already raw format"
    export FASTBOOT_RAW_IMG="$sparse_img"
  fi
}

# ---------------------------------------------------------------------------
# STEP 3 – Verify super size (multi-source cross-check)
# A single wrong byte = bricked device. Fail loud on mismatch.
# ---------------------------------------------------------------------------
_fastboot_verify_super_size() {
  local raw_size
  raw_size="$(stat -c%s "$FASTBOOT_RAW_IMG")"
  log "Raw super partition size: $raw_size bytes"

  mkdir -p "$LOGS"
  local log_file="$LOGS/super_size_check.log"
  {
    printf 'raw_file_size\t%s\n' "$raw_size"
  } > "$log_file"

  # ---- Source A: android-info.txt ----------------------------------------
  local android_info=""
  android_info="$(unzip -p "$ROM_FILE" android-info.txt 2>/dev/null || true)"
  if [[ -z "$android_info" ]]; then
    local ai_path
    ai_path="$(unzip -l "$ROM_FILE" | awk '$NF ~ /android-info\.txt$/ {print $NF}' | head -1)"
    [[ -n "$ai_path" ]] && android_info="$(unzip -p "$ROM_FILE" "$ai_path" 2>/dev/null || true)"
  fi

  local manifest_size=""
  if [[ -n "$android_info" ]]; then
    printf '%s\n' "$android_info" > "$LOGS/android-info.txt"
    # Format: require partition-size:super=SIZE  or  partition-size:super=0xHEX
    local raw_val
    raw_val="$(printf '%s\n' "$android_info" \
      | grep -iE 'partition-size.*super|super.*partition-size' \
      | grep -oE '(0x[0-9a-fA-F]+|[0-9]{6,})' | head -1)"
    if [[ -n "$raw_val" ]]; then
      # Convert hex if needed
      if [[ "$raw_val" == 0x* || "$raw_val" == 0X* ]]; then
        manifest_size="$(printf '%d' "$raw_val")"
      else
        manifest_size="$raw_val"
      fi
      log "android-info.txt reports super size: $manifest_size bytes"
      printf 'android_info_size\t%s\n' "$manifest_size" >> "$log_file"
    fi
  fi

  # ---- Source B: flash scripts (.sh / .bat) --------------------------------
  local script_size=""
  local script_content=""
  for script_name in flash-all.sh flash_all.sh flash-super.sh; do
    script_content="$(unzip -p "$ROM_FILE" "$script_name" 2>/dev/null || true)"
    [[ -n "$script_content" ]] && break
    local sp
    sp="$(unzip -l "$ROM_FILE" | awk -v n="$script_name" '$NF ~ n {print $NF}' | head -1)"
    [[ -n "$sp" ]] && script_content="$(unzip -p "$ROM_FILE" "$sp" 2>/dev/null || true)"
    [[ -n "$script_content" ]] && break
  done
  if [[ -n "$script_content" ]]; then
    local sv
    sv="$(printf '%s\n' "$script_content" \
      | grep -iE 'super' \
      | grep -oE '(0x[0-9a-fA-F]{6,}|[0-9]{7,})' | head -1)"
    if [[ -n "$sv" ]]; then
      if [[ "$sv" == 0x* || "$sv" == 0X* ]]; then
        script_size="$(printf '%d' "$sv")"
      else
        script_size="$sv"
      fi
      log "Flash script reports super size hint: $script_size bytes"
      printf 'flash_script_size\t%s\n' "$script_size" >> "$log_file"
    fi
  fi

  # ---- Source C: partition-sizes.txt or similar ---------------------------
  local psizes_content=""
  psizes_content="$(unzip -p "$ROM_FILE" partition-sizes.txt 2>/dev/null || true)"
  if [[ -n "$psizes_content" ]]; then
    local pv
    pv="$(printf '%s\n' "$psizes_content" | grep -i 'super' | grep -oE '[0-9]{7,}' | head -1)"
    if [[ -n "$pv" ]]; then
      log "partition-sizes.txt reports super: $pv bytes"
      printf 'partition_sizes_txt\t%s\n' "$pv" >> "$log_file"
      [[ -n "$manifest_size" ]] || manifest_size="$pv"
    fi
  fi

  # ---- Final verdict -------------------------------------------------------
  if [[ -n "$manifest_size" ]]; then
    if [[ "$manifest_size" == "$raw_size" ]]; then
      log "✓ super.img size VERIFIED: $raw_size bytes matches manifest ($manifest_size)"
      printf 'verdict\tOK\t%s\n' "$raw_size" >> "$log_file"
    else
      # Hard fail — one bad byte = bricked device
      die "CRITICAL: super.img size MISMATCH. " \
          "Extracted raw size=$raw_size bytes, " \
          "manifest/script says=$manifest_size bytes. " \
          "Aborting — flashing this would brick the device. " \
          "Check the ZIP or re-download the ROM."
    fi
  else
    warn "No manifest size reference found for super.img. Trusting raw size: $raw_size bytes."
    warn "Manually verify with: fastboot getvar partition-size:super"
    printf 'verdict\tUNCHECKED\t%s\n' "$raw_size" >> "$log_file"
  fi

  export FASTBOOT_VERIFIED_RAW_SIZE="$raw_size"
}

# ---------------------------------------------------------------------------
# STEP 4 – Read exact super metadata using lpdump
# Sets: SUPER_SIZE, SUPER_METADATA_SIZE, SUPER_METADATA_SLOTS, SUPER_NAME,
#       SUPER_SLOT_MODE, DYNAMIC_PARTITION_GROUP_NAME,
#       DYNAMIC_PARTITION_GROUP_SIZE, SUPER_GROUP_BASENAME
# ---------------------------------------------------------------------------
_fastboot_read_super_metadata() {
  require_tool lpdump

  log "Reading super.img metadata with lpdump..."
  lpdump "$FASTBOOT_RAW_IMG" > "$LOGS/lpdump_fastboot.log" 2>&1 \
    || die "lpdump failed on super.img — image may be corrupt or unsupported format"

  log "lpdump output:"
  cat "$LOGS/lpdump_fastboot.log"

  # ---- SUPER_SIZE from Block device table (ground truth) ------------------
  # "  Size: 9126805504"  under "Block device table"
  local lpdump_size
  lpdump_size="$(awk '
    /Block device table/{in_bd=1}
    in_bd && /Size:/{
      for(i=1;i<=NF;i++) if($i~/^[0-9]{6,}$/){print $i; exit}
    }
  ' "$LOGS/lpdump_fastboot.log")"
  [[ -n "$lpdump_size" ]] || die "lpdump did not report super partition Size"

  # Cross-check with our raw file size — must match exactly
  if [[ "$lpdump_size" != "$FASTBOOT_VERIFIED_RAW_SIZE" ]]; then
    die "CRITICAL: lpdump reports super size=$lpdump_size but raw file is $FASTBOOT_VERIFIED_RAW_SIZE bytes. " \
        "Extraction or simg2img conversion failed."
  fi
  log "✓ lpdump size confirms raw file size: $lpdump_size bytes"

  # ---- Metadata fields ----------------------------------------------------
  local meta_size meta_slots super_name
  meta_size="$(awk '/Metadata max size:/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}}' \
    "$LOGS/lpdump_fastboot.log")"
  meta_slots="$(awk '/Metadata slot count:/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}}' \
    "$LOGS/lpdump_fastboot.log")"
  super_name="$(awk '/Block device table/{in_bd=1} in_bd && /Partition name:/{print $NF; exit}' \
    "$LOGS/lpdump_fastboot.log")"
  super_name="${super_name:-super}"

  [[ -n "$meta_size" ]]  || die "lpdump: could not parse 'Metadata max size'"
  [[ -n "$meta_slots" ]] || die "lpdump: could not parse 'Metadata slot count'"

  # ---- Virtual-AB flag ----------------------------------------------------
  local is_vab=false
  if grep -qiE 'Header flags.*virtual_ab|virtual_ab' "$LOGS/lpdump_fastboot.log"; then
    is_vab=true
    log "Detected virtual_ab flag in super metadata"
  fi

  # ---- Partition group table ----------------------------------------------
  # Collect group names to determine slot mode
  # lpdump group table section:
  #   Name: qti_dynamic_partitions_a
  #   Maximum size: 9122611200
  local -a group_names=()
  local gname
  while IFS= read -r gname; do
    [[ -n "$gname" ]] || continue
    group_names+=("$gname")
  done < <(awk '
    /^Partition group table:/{in_grp=1; next}
    /^[A-Z]/ && in_grp && !/^  /{in_grp=0}
    in_grp && /^  Name:/{print $2}
  ' "$LOGS/lpdump_fastboot.log")

  local slot_mode="A"
  local group_basename="" group_a_name="" group_a_size="" group_b_size=""

  if printf '%s\n' "${group_names[@]}" | grep -qE '_a$'; then
    # AB or VAB device
    $is_vab && slot_mode="VAB" || slot_mode="AB"
    group_a_name="$(printf '%s\n' "${group_names[@]}" | grep -E '_a$' | head -1)"
    group_basename="${group_a_name%_a}"

    group_a_size="$(awk -v gn="$group_a_name" '
      /^Partition group table:/{in_grp=1; cur=""; next}
      in_grp && /^  Name:/{cur=$2}
      in_grp && /Maximum size:/ && cur==gn {
        for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}
      }
    ' "$LOGS/lpdump_fastboot.log")"

    local group_b_name="${group_basename}_b"
    group_b_size="$(awk -v gn="$group_b_name" '
      /^Partition group table:/{in_grp=1; cur=""; next}
      in_grp && /^  Name:/{cur=$2}
      in_grp && /Maximum size:/ && cur==gn {
        for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}
      }
    ' "$LOGS/lpdump_fastboot.log")"
    group_b_size="${group_b_size:-1048576}"
  else
    slot_mode="A"
    group_a_name="$(printf '%s\n' "${group_names[@]}" | grep -v '^$' | head -1)"
    group_basename="$group_a_name"
    group_a_size="$(awk -v gn="$group_a_name" '
      /^Partition group table:/{in_grp=1; cur=""; next}
      in_grp && /^  Name:/{cur=$2}
      in_grp && /Maximum size:/ && cur==gn {
        for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i; exit}
      }
    ' "$LOGS/lpdump_fastboot.log")"
    group_b_size=0
  fi

  [[ -n "$group_basename" ]] || die "lpdump: could not determine partition group name"
  [[ -n "$group_a_size" ]]   || die "lpdump: could not determine group maximum size"

  # ---- Export all metadata vars -------------------------------------------
  export SUPER_SIZE="$lpdump_size"
  export SUPER_METADATA_SIZE="$meta_size"
  export SUPER_METADATA_SLOTS="$meta_slots"
  export SUPER_NAME="$super_name"
  export SUPER_SLOT_MODE="$slot_mode"
  export SUPER_ACTIVE_SLOT="${SUPER_ACTIVE_SLOT:-a}"
  export SUPER_OUTPUT_FORMAT="${SUPER_OUTPUT_FORMAT:-sparse}"
  export SUPER_GROUP_BASENAME="$group_basename"
  export DYNAMIC_PARTITION_GROUP_NAME="$group_basename"
  export DYNAMIC_PARTITION_GROUP_SIZE="$group_a_size"
  export DYNAMIC_PARTITION_GROUP_SIZE_A="$group_a_size"
  export DYNAMIC_PARTITION_GROUP_SIZE_B="$group_b_size"
  export METADATA_SLOTS="$meta_slots"

  log "=== Auto-detected super metadata ==="
  log "  SUPER_SIZE              = $SUPER_SIZE"
  log "  SUPER_SLOT_MODE         = $SUPER_SLOT_MODE"
  log "  SUPER_METADATA_SIZE     = $SUPER_METADATA_SIZE"
  log "  SUPER_METADATA_SLOTS    = $SUPER_METADATA_SLOTS"
  log "  SUPER_NAME              = $SUPER_NAME"
  log "  DYNAMIC_PARTITION_GROUP = $DYNAMIC_PARTITION_GROUP_NAME"
  log "  GROUP_A_SIZE            = $DYNAMIC_PARTITION_GROUP_SIZE_A"
  log "  GROUP_B_SIZE            = $DYNAMIC_PARTITION_GROUP_SIZE_B"
}

# ---------------------------------------------------------------------------
# STEP 5 – Unpack super.img partitions with lpunpack
# ---------------------------------------------------------------------------
_fastboot_unpack_super() {
  require_tool lpunpack
  mkdir -p "$EXTRACTED"

  log "Unpacking super.img partitions with lpunpack..."
  lpunpack "$FASTBOOT_RAW_IMG" "$EXTRACTED" 2>&1 | tee "$LOGS/lpunpack.log" \
    || die "lpunpack failed — super.img may be corrupt"

  local img_count
  img_count="$(find "$EXTRACTED" -maxdepth 1 -name '*.img' -type f | wc -l)"
  [[ "$img_count" -gt 0 ]] || die "lpunpack produced no .img files"

  log "lpunpack extracted $img_count image(s):"
  find "$EXTRACTED" -maxdepth 1 -name '*.img' -type f \
    | sort | while read -r f; do
      printf '  %-40s %s\n' "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
    done | tee -a "$LOGS/lpunpack.log"
}

# ---------------------------------------------------------------------------
# STEP 6 – Detect partition naming scheme from lpdump + extracted files
# Sets: FASTBOOT_PART_NAMING ("none" | "a_only" | "ab")
#       DYNAMIC_PARTITIONS   (space-separated BASE names, no _a/_b suffix)
# ---------------------------------------------------------------------------
_fastboot_detect_partition_naming() {
  log "Detecting partition naming scheme from lpdump partition table..."

  # Parse partition names strictly from the "Partition table:" section
  local part_names
  part_names="$(awk '
    /^Partition table:/{in_pt=1; next}
    /^[A-Za-z]/ && in_pt && !/^  /{in_pt=0}
    in_pt && /^  Name:/{print $2}
  ' "$LOGS/lpdump_fastboot.log")"

  [[ -n "$part_names" ]] || die "lpdump: could not find any partitions in Partition table"

  log "lpdump partition names: $(printf '%s ' $part_names)"

  local -a base_names=()
  local has_a=false has_b=false has_plain=false
  local pname base

  while IFS= read -r pname; do
    [[ -n "$pname" ]] || continue
    if [[ "$pname" == *_b ]]; then
      has_b=true
      # base was already recorded via the _a entry
    elif [[ "$pname" == *_a ]]; then
      has_a=true
      base="${pname%_a}"
      # avoid duplicates
      local already=false
      local existing
      for existing in "${base_names[@]+"${base_names[@]}"}"; do
        [[ "$existing" == "$base" ]] && already=true && break
      done
      $already || base_names+=("$base")
    else
      has_plain=true
      local already=false
      local existing
      for existing in "${base_names[@]+"${base_names[@]}"}"; do
        [[ "$existing" == "$pname" ]] && already=true && break
      done
      $already || base_names+=("$pname")
    fi
  done <<< "$part_names"

  # Determine naming scheme
  if $has_b && $has_a; then
    FASTBOOT_PART_NAMING="ab"
  elif $has_a; then
    FASTBOOT_PART_NAMING="a_only"
  else
    FASTBOOT_PART_NAMING="none"
  fi

  [[ ${#base_names[@]} -gt 0 ]] || die "No base partition names derived from lpdump"

  # Cross-verify with actually extracted files
  local -a verified_bases=()
  local b
  for b in "${base_names[@]}"; do
    local found_file=""
    case "$FASTBOOT_PART_NAMING" in
      none)   found_file="$EXTRACTED/$b.img" ;;
      a_only|ab) found_file="$EXTRACTED/${b}_a.img" ;;
    esac
    if [[ -f "$found_file" ]]; then
      verified_bases+=("$b")
    else
      # Fallback: try alternative naming
      if [[ -f "$EXTRACTED/$b.img" ]]; then
        log "  Note: $b found as plain $b.img (no slot suffix)"
        verified_bases+=("$b")
      elif [[ -f "$EXTRACTED/${b}_a.img" ]]; then
        log "  Note: $b found as ${b}_a.img"
        verified_bases+=("$b")
      else
        warn "  Partition '$b' listed in lpdump but no .img file found after lpunpack — skipping"
      fi
    fi
  done

  [[ ${#verified_bases[@]} -gt 0 ]] || die "None of the lpdump partitions have .img files after lpunpack"

  export FASTBOOT_PART_NAMING
  export DYNAMIC_PARTITIONS="${verified_bases[*]}"

  log "=== Partition detection result ==="
  log "  Naming scheme    : $FASTBOOT_PART_NAMING"
  log "  DYNAMIC_PARTITIONS: $DYNAMIC_PARTITIONS"
  case "$FASTBOOT_PART_NAMING" in
    none)   log "  Explanation: partitions have no slot suffix (e.g. product.img)" ;;
    a_only) log "  Explanation: partitions have _a suffix only (e.g. product_a.img, no product_b.img)" ;;
    ab)     log "  Explanation: both _a and _b slot files present (e.g. product_a.img + product_b.img)" ;;
  esac
}

# ---------------------------------------------------------------------------
# STEP 7 – Build partitions.tsv  (same format as OTA pipeline)
# Columns: part  img  size  container  fs
# "img" points to the actual extracted file with its original name.
# ---------------------------------------------------------------------------
_fastboot_build_partitions_tsv() {
  require_tool file

  : > "$WORKSPACE/partitions.tsv"
  : > "$LOGS/partitions.log"
  log "Building partitions.tsv from fastboot super extracted images"

  local part actual_img size format fs raw_img

  for part in $DYNAMIC_PARTITIONS; do
    # Resolve actual file path (preserve original name from lpunpack)
    actual_img=""
    case "$FASTBOOT_PART_NAMING" in
      none)
        [[ -f "$EXTRACTED/$part.img" ]] && actual_img="$EXTRACTED/$part.img"
        ;;
      a_only)
        if [[ -f "$EXTRACTED/${part}_a.img" ]]; then
          actual_img="$EXTRACTED/${part}_a.img"
        elif [[ -f "$EXTRACTED/$part.img" ]]; then
          actual_img="$EXTRACTED/$part.img"
        fi
        ;;
      ab)
        if [[ -f "$EXTRACTED/${part}_a.img" ]]; then
          actual_img="$EXTRACTED/${part}_a.img"
        elif [[ -f "$EXTRACTED/$part.img" ]]; then
          actual_img="$EXTRACTED/$part.img"
        fi
        ;;
    esac

    if [[ -z "$actual_img" || ! -s "$actual_img" ]]; then
      warn "No image file for partition '$part' — skipping"
      continue
    fi

    size="$(stat -c%s "$actual_img")"
    format="$(_detect_image_container "$actual_img")"
    fs="$(_detect_image_filesystem "$actual_img" "$format")"

    # Flatten sparse to raw (lpmake needs raw)
    if [[ "$format" == "sparse" ]]; then
      raw_img="$EXTRACTED/${part}.raw.img"
      log "Converting sparse $part to raw for lpmake..."
      require_tool simg2img
      simg2img "$actual_img" "$raw_img" || die "simg2img failed for $part"
      actual_img="$raw_img"
      size="$(stat -c%s "$actual_img")"
      format="raw"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$part" "$actual_img" "$size" "$format" "$fs" \
      >> "$WORKSPACE/partitions.tsv"
    printf '%-20s size=%-14s container=%-6s fs=%s\n' "$part" "$size" "$format" "$fs" \
      | tee -a "$LOGS/partitions.log"

    # For AB: also record and verify B-slot file exists (for repacker)
    if [[ "$FASTBOOT_PART_NAMING" == "ab" ]]; then
      local b_img="$EXTRACTED/${part}_b.img"
      if [[ -f "$b_img" && -s "$b_img" ]]; then
        local b_size
        b_size="$(stat -c%s "$b_img")"
        log "  B-slot: ${part}_b.img  size=$b_size bytes"
      fi
    fi
  done

  [[ -s "$WORKSPACE/partitions.tsv" ]] || die "partitions.tsv is empty — no partition images found"
  log "partitions.tsv complete with $(wc -l < "$WORKSPACE/partitions.tsv") entries"
}

# ---------------------------------------------------------------------------
# STEP 8 – Extract all other images from fastboot ZIP (boot, vbmeta, etc.)
# ---------------------------------------------------------------------------
_fastboot_extract_other_images() {
  log "Extracting non-super images from fastboot ZIP..."
  local zip="$ROM_FILE"
  local extracted_count=0

  # List all .img files except super.img
  local img_paths=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    local bn
    bn="$(basename "$path")"
    [[ "$bn" == "super.img" ]] && continue
    img_paths+=("$path")
  done < <(unzip -l "$zip" | awk '$NF ~ /\.img$/ {print $NF}')

  local img_path img_name
  for img_path in "${img_paths[@]+"${img_paths[@]}"}"; do
    img_name="$(basename "$img_path")"
    # Skip if already present from lpunpack
    [[ -f "$EXTRACTED/$img_name" ]] && continue

    if unzip -q -o "$zip" "$img_path" -d "$EXTRACTED/" 2>/dev/null; then
      # If extracted into subdirectory, flatten
      local found
      found="$(find "$EXTRACTED" -name "$img_name" -not -path "*/fastboot/*" -type f | head -1)"
      if [[ -n "$found" && "$found" != "$EXTRACTED/$img_name" ]]; then
        mv "$found" "$EXTRACTED/$img_name"
      fi
      [[ -f "$EXTRACTED/$img_name" ]] && {
        extracted_count=$((extracted_count + 1))
        log "  Extracted: $img_name  ($(du -h "$EXTRACTED/$img_name" | awk '{print $1}'))"
      }
    fi
  done

  log "Extracted $extracted_count additional image(s) from fastboot ZIP"
  log "All images in $EXTRACTED:"
  ls -lh "$EXTRACTED"/*.img 2>/dev/null | awk '{print "  "$NF, $5}' || true
}

# ---------------------------------------------------------------------------
# CONFIG GENERATOR – called after the full pipeline completes
# Produces a ready-to-download .conf usable for future runs
# ---------------------------------------------------------------------------
generate_fastboot_device_config() {
  local codename="$DEVICE_CODENAME"
  mkdir -p "$OUTPUT_FINAL"
  local conf_out="$OUTPUT_FINAL/detected_${codename}.conf"

  # Determine PARTITION_SUFFIX for this device
  local part_suffix=""
  case "${FASTBOOT_PART_NAMING:-none}" in
    a_only|ab) part_suffix="_a" ;;
    none)      part_suffix="" ;;
  esac

  # Determine FASTBOOT_SLOT_MODE (for flash scripts)
  local fb_slot_mode="single"
  case "${SUPER_SLOT_MODE:-A}" in
    AB|VAB) fb_slot_mode="ab_suffix" ;;
    A)      fb_slot_mode="single"    ;;
  esac

  # Collect required/optional images that were actually found
  local req_found=() opt_found=()
  local -a all_required=( boot.img init_boot.img vendor_boot.img vbmeta.img )
  local -a all_optional=( dtbo.img vbmeta_system.img vbmeta_vendor.img \
    vendor_kernel_boot.img recovery.img logo.img lk.img tee.img scp.img \
    spmfw.img audio_dsp.img dpm.img mcupm.img pi_img.img gz.img md1img.img )
  local img
  for img in "${all_required[@]}"; do
    [[ -f "$EXTRACTED/$img" ]] && req_found+=("$img")
  done
  for img in "${all_optional[@]}"; do
    [[ -f "$EXTRACTED/$img" ]] && opt_found+=("$img")
  done

  cat > "$conf_out" <<EOF
# LF normalized for GitHub raw
# ===================================================================
# Auto-generated device config by DeadZone ROM Kitchen
# ROM type   : fastboot
# Source ROM : ${ROM_FILE:-(unknown)}
# Generated  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ===================================================================
#
# All values below were extracted directly from super.img via lpdump.
# SUPER_SIZE is the raw partition byte size — DO NOT change unless you
# have verified it with:  fastboot getvar partition-size:super
# One wrong byte will cause a failed flash or a bricked device.
#
# Copy this file to:  devices/${codename}.conf
# ===================================================================

DEVICE_CODENAME=${codename}
DEVICE_BRAND=
DEVICE_SOC=

# ---- super partition metadata (auto-detected from super.img via lpdump) ----
SUPER_SIZE=${SUPER_SIZE}
SUPER_SLOT_MODE=${SUPER_SLOT_MODE}
SUPER_OUTPUT_FORMAT=${SUPER_OUTPUT_FORMAT:-sparse}
SUPER_ACTIVE_SLOT=${SUPER_ACTIVE_SLOT:-a}
SUPER_GROUP_BASENAME=${SUPER_GROUP_BASENAME}
DYNAMIC_PARTITION_GROUP_NAME=${DYNAMIC_PARTITION_GROUP_NAME}
DYNAMIC_PARTITION_GROUP_SIZE=${DYNAMIC_PARTITION_GROUP_SIZE}
SUPER_METADATA_SIZE=${SUPER_METADATA_SIZE}
SUPER_METADATA_SLOTS=${SUPER_METADATA_SLOTS}
SUPER_NAME=${SUPER_NAME:-super}
PARTITION_SUFFIX=${part_suffix}

# ---- Partition naming scheme detected: ${FASTBOOT_PART_NAMING:-none} --------
# none   → product.img       (A-only device, no slot suffix in super)
# a_only → product_a.img     (AB device, only A slot images in super)
# ab     → product_a.img + product_b.img  (full AB/VAB, both slots in super)

# ---- Dynamic partitions (base names, no slot suffix) -----------------------
DYNAMIC_PARTITIONS="${DYNAMIC_PARTITIONS}"

# ---- Fastboot image policy (from images found in this ROM) -----------------
REQUIRED_FASTBOOT_IMAGES="${req_found[*]:-boot.img vendor_boot.img vbmeta.img}"
OPTIONAL_FASTBOOT_IMAGES="${opt_found[*]:-dtbo.img vbmeta_system.img vbmeta_vendor.img logo.img}"
VBMETA_IMAGES="vbmeta.img vbmeta_system.img vbmeta_vendor.img"
FASTBOOT_SLOT_MODE=${fb_slot_mode}
VBMETA_PATCH_STRATEGY=binary
EOF

  log "==================================================="
  log "Generated device config: output_final/detected_${codename}.conf"
  log "→ Save as devices/${codename}.conf for future OTA builds"
  log "==================================================="
  cat "$conf_out"
}
