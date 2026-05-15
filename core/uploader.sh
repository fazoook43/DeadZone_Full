#!/bin/bash
# ════════════════════════════════════════════════
#  Neom VIP - Smart Uploader
#  يرفع super.img.zst لوحده + الـ ZIP لوحده
# ════════════════════════════════════════════════

log()   { echo -e "\033[0;34m[$(date +%T)]\033[0m \033[0;32m$1\033[0m"; }
warn()  { echo -e "\033[0;33m[WARN] $1\033[0m"; }
error() { echo -e "\033[0;31m[ERROR] $1\033[0m"; exit 1; }

SERVICE="${1:-gofile}"
WORKSPACE=$(pwd)
FINAL="$WORKSPACE/output_final"

_upload_file() {
    local file="$1"
    local label="$2"
    [[ ! -f "$file" ]] && warn "$label not found: $file" && return

    log "Uploading $label → $SERVICE"
    log "File: $(basename $file) ($(du -sh $file | cut -f1))"

    case "$SERVICE" in
        gofile)
            local SERVER
            SERVER=$(curl -s https://api.gofile.io/getServer \
                | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['server'])")
            local RESP
            RESP=$(curl -s -F "file=@$file" "https://$SERVER.gofile.io/uploadFile")
            local LINK
            LINK=$(echo "$RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['data']['downloadPage'])" 2>/dev/null)
            if [[ -n "$LINK" ]]; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ $label"
                echo "  🔗 $LINK"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            else
                warn "GoFile upload failed for $label"
            fi
            ;;

        pixeldrain)
            [[ -z "$PIXELDRAIN_KEY" ]] && error "PIXELDRAIN_KEY not set!"
            local FILENAME=$(basename "$file")
            local RESP
            RESP=$(curl -s -T "$file" \
                -u ":$PIXELDRAIN_KEY" \
                "https://pixeldrain.com/api/file/$FILENAME")
            local ID
            ID=$(echo "$RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
            if [[ -n "$ID" ]]; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ $label"
                echo "  🔗 https://pixeldrain.com/u/$ID"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            else
                warn "PixelDrain upload failed for $label"
            fi
            ;;

        sourceforge)
            [[ -z "$SF_USER" || -z "$SF_PASS" || -z "$SF_PROJECT" ]] && \
                error "SF_USER/SF_PASS/SF_PROJECT not set!"
            local FILENAME=$(basename "$file")
            sshpass -p "$SF_PASS" scp -o StrictHostKeyChecking=no \
                "$file" \
                "$SF_USER@frs.sourceforge.net:/home/frs/project/$SF_PROJECT/$FILENAME"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ $label"
            echo "  🔗 https://sourceforge.net/projects/$SF_PROJECT/files/$FILENAME"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            ;;

        none|*)
            log "Upload skipped for $label"
            ;;
    esac
}

main() {
    log "Starting upload — service=$SERVICE"
    ls -lh "$FINAL/" 2>/dev/null || error "output_final/ is empty!"

    # 1. رفع super.img.zst لوحده
    _upload_file "$FINAL/super.img.zst" "super.img.zst"

    # 2. رفع الـ flashable ZIP لوحده
    local ZIP_FILE
    ZIP_FILE=$(find "$FINAL" -name "Neom_VIP_*.zip" | head -1)
    _upload_file "$ZIP_FILE" "Flashable ZIP"

    log "All uploads done ✅"
}

main
