#!/bin/bash
#
# protonpass-to-bitwarden-sync.sh
# Syncs login items from Proton Pass to Bitwarden
#

set -euo pipefail

# Configuration
PROTON_PASS_BIN="${PROTON_PASS_BIN:-pass-cli}"
BITWARDEN_BIN="${BITWARDEN_BIN:-bw}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_EXISTING="${SKIP_EXISTING:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_deps() {
    if ! command -v "$PROTON_PASS_BIN" &>/dev/null; then
        log_error "Proton Pass CLI ($PROTON_PASS_BIN) not found. Install from: https://protonpass.github.io/pass-cli/"
        exit 1
    fi

    if ! command -v "$BITWARDEN_BIN" &>/dev/null; then
        log_error "Bitwarden CLI ($BITWARDEN_BIN) not found. Install from: https://bitwarden.com/help/cli/"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Please install jq."
        exit 1
    fi
}

# Verify Proton Pass is logged in
check_proton_pass_auth() {
    if ! $PROTON_PASS_BIN vault list &>/dev/null; then
        log_error "Not logged into Proton Pass. Run: $PROTON_PASS_BIN login"
        exit 1
    fi
    log_info "Proton Pass: Authenticated"
}

# Verify Bitwarden is unlocked
check_bitwarden_auth() {
    local status
    status=$($BITWARDEN_BIN status | jq -r '.status')

    if [ "$status" = "unauthenticated" ]; then
        log_error "Not logged into Bitwarden. Run: $BITWARDEN_BIN login"
        exit 1
    fi

    if [ "$status" = "locked" ]; then
        log_error "Bitwarden vault is locked. Run: $BITWARDEN_BIN unlock"
        exit 1
    fi

    if [ "$status" = "unlocked" ]; then
        log_info "Bitwarden: Vault unlocked"
    else
        log_error "Unknown Bitwarden status: $status"
        exit 1
    fi
}

# Get all vaults from Proton Pass
get_proton_vaults() {
    $PROTON_PASS_BIN vault list --output json | jq -c '.[]'
}

# Get items from a specific Proton Pass vault
get_proton_items() {
    local share_id=$1
    $PROTON_PASS_BIN item list --share-id "$share_id" --output json 2>/dev/null | jq -c '.[]' || echo ""
}

# Get full item details from Proton Pass
get_proton_item_details() {
    local share_id=$1
    local item_id=$2
    $PROTON_PASS_BIN item view --share-id "$share_id" --item-id "$item_id" --output json 2>/dev/null
}

# Check if item exists in Bitwarden (by name)
bitwarden_item_exists() {
    local name=$1
    local count
    count=$($BITWARDEN_BIN list items --search "$name" | jq 'length')
    [ "$count" -gt 0 ]
}

# Create login item in Bitwarden
create_bitwarden_login() {
    local title=$1
    local username=$2
    local password=$3
    local url=$4
    local notes=$5

    # Build the item JSON
    local item_json
    item_json=$($BITWARDEN_BIN get template item | jq \
        --arg title "$title" \
        --arg username "$username" \
        --arg password "$password" \
        --arg url "$url" \
        --arg notes "$notes" \
        '{
            type: 1,
            name: $title,
            notes: $notes,
            login: {
                username: $username,
                password: $password,
                uris: (if $url == "" then [] else [{match: null, uri: $url}] end)
            }
        }')

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would create: $title"
        echo "$item_json" | jq .
        return 0
    fi

    # Encode and create
    if echo "$item_json" | $BITWARDEN_BIN encode | $BITWARDEN_BIN create item >/dev/null; then
        log_info "Created: $title"
        return 0
    else
        log_error "Failed to create: $title"
        return 1
    fi
}

# Create secure note in Bitwarden
create_bitwarden_note() {
    local title=$1
    local content=$2

    local item_json
    item_json=$($BITWARDEN_BIN get template item | jq \
        --arg title "$title" \
        --arg content "$content" \
        '{
            type: 2,
            name: $title,
            notes: $content,
            secureNote: { type: 0 }
        }')

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would create note: $title"
        return 0
    fi

    if echo "$item_json" | $BITWARDEN_BIN encode | $BITWARDEN_BIN create item >/dev/null; then
        log_info "Created note: $title"
        return 0
    else
        log_error "Failed to create note: $title"
        return 1
    fi
}

# Create credit card in Bitwarden
create_bitwarden_card() {
    local title=$1
    local cardholder=$2
    local number=$3
    local expiry=$4
    local cvv=$5
    local notes=$6

    local item_json
    item_json=$($BITWARDEN_BIN get template item | jq \
        --arg title "$title" \
        --arg cardholder "$cardholder" \
        --arg number "$number" \
        --arg expiry "$expiry" \
        --arg cvv "$cvv" \
        --arg notes "$notes" \
        '{
            type: 3,
            name: $title,
            notes: $notes,
            card: {
                cardholderName: $cardholder,
                number: $number,
                expMonth: ($expiry | split("/")[0] // ""),
                expYear: ($expiry | split("/")[1] // ""),
                code: $cvv
            }
        }')

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would create card: $title"
        return 0
    fi

    if echo "$item_json" | $BITWARDEN_BIN encode | $BITWARDEN_BIN create item >/dev/null; then
        log_info "Created card: $title"
        return 0
    else
        log_error "Failed to create card: $title"
        return 1
    fi
}

# Process a single Proton Pass item
process_item() {
    local share_id=$1
    local share_name=$2
    local item_summary=$3

    local item_id item_type item_title
    item_id=$(echo "$item_summary" | jq -r '.itemId // .id // empty')
    item_type=$(echo "$item_summary" | jq -r '.type // empty')
    item_title=$(echo "$item_summary" | jq -r '.title // empty')

    if [ -z "$item_id" ] || [ -z "$item_title" ]; then
        log_warn "Skipping item with missing ID or title in vault: $share_name"
        return
    fi

    # Check if already exists in Bitwarden
    if [ "$SKIP_EXISTING" = "true" ] && bitwarden_item_exists "$item_title"; then
        log_info "Skipping existing: $item_title"
        return
    fi

    # Get full item details
    local item_details
    item_details=$(get_proton_item_details "$share_id" "$item_id")

    if [ -z "$item_details" ]; then
        log_warn "Could not get details for: $item_title"
        return
    fi

    # Extract common fields
    local title username password email url notes
    title=$(echo "$item_details" | jq -r '.title // empty')
    notes=$(echo "$item_details" | jq -r '.note // .notes // empty')

    case "$item_type" in
    "login" | "1")
        username=$(echo "$item_details" | jq -r '.username // .content.username // empty')
        email=$(echo "$item_details" | jq -r '.email // .content.email // empty')
        password=$(echo "$item_details" | jq -r '.password // .content.password // empty')
        url=$(echo "$item_details" | jq -r '.urls[0] // .content.urls[0] // empty')

        # Use email as username if username is empty
        if [ -z "$username" ] && [ -n "$email" ]; then
            username="$email"
        fi

        create_bitwarden_login "$title" "$username" "$password" "$url" "$notes"
        ;;

    "note" | "secure-note" | "2")
        local content
        content=$(echo "$item_details" | jq -r '.content // .note // empty')
        create_bitwarden_note "$title" "$content"
        ;;

    "credit-card" | "card" | "3")
        local cardholder number expiry cvv
        cardholder=$(echo "$item_details" | jq -r '.content.cardholder // .cardholder // empty')
        number=$(echo "$item_details" | jq -r '.content.number // .number // empty')
        expiry=$(echo "$item_details" | jq -r '.content.expirationDate // .expiration // empty')
        cvv=$(echo "$item_details" | jq -r '.content.cvv // .cvv // empty')
        create_bitwarden_card "$title" "$cardholder" "$number" "$expiry" "$cvv" "$notes"
        ;;

    "alias" | "identity" | "ssh-key" | "wifi" | "custom")
        log_warn "Skipping unsupported type '$item_type': $title"
        ;;

    *)
        log_warn "Skipping unknown type '$item_type': $title"
        ;;
    esac
}

# Main sync function
sync_vaults() {
    log_info "Starting sync from Proton Pass to Bitwarden..."

    local total_items=0
    local processed_items=0
    local skipped_items=0
    local error_items=0

    # Get all Proton Pass vaults
    log_info "Fetching vaults from Proton Pass..."

    while IFS= read -r vault; do
        local share_id share_name
        share_id=$(echo "$vault" | jq -r '.shareId // .id // empty')
        share_name=$(echo "$vault" | jq -r '.name // "Unknown"')

        if [ -z "$share_id" ]; then
            continue
        fi

        log_info "Processing vault: $share_name"

        # Get items in this vault
        local items
        items=$(get_proton_items "$share_id")

        if [ -z "$items" ]; then
            log_info "  No items in vault: $share_name"
            continue
        fi

        while IFS= read -r item; do
            if [ -z "$item" ]; then
                continue
            fi

            total_items=$((total_items + 1))

            if process_item "$share_id" "$share_name" "$item"; then
                processed_items=$((processed_items + 1))
            else
                error_items=$((error_items + 1))
            fi

        done <<<"$items"

    done <<<"$(get_proton_vaults)"

    log_info "========================================"
    log_info "Sync complete!"
    log_info "Total items: $total_items"
    log_info "Processed: $processed_items"
    log_info "Errors: $error_items"
    log_info "========================================"
}

# Print usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Sync passwords from Proton Pass to Bitwarden

Options:
    -d, --dry-run        Show what would be done without making changes
    -s, --skip-existing  Skip items that already exist in Bitwarden
    -h, --help           Show this help message

Environment Variables:
    PROTON_PASS_BIN      Path to pass-cli binary (default: pass-cli)
    BITWARDEN_BIN        Path to bw binary (default: bw)
    DRY_RUN              Set to "true" for dry run mode
    SKIP_EXISTING        Set to "true" to skip existing items

Prerequisites:
    - Proton Pass CLI installed and logged in
    - Bitwarden CLI installed and unlocked
    - jq installed

Examples:
    # Dry run to preview changes
    $0 --dry-run

    # Sync only new items
    $0 --skip-existing

    # Full sync
    $0
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --dry-run)
        DRY_RUN=true
        shift
        ;;
    -s | --skip-existing)
        SKIP_EXISTING=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

# Main execution
main() {
    log_info "Proton Pass → Bitwarden Sync Tool"
    log_info "Dry run: $DRY_RUN"
    log_info "Skip existing: $SKIP_EXISTING"
    echo ""

    check_deps
    check_proton_pass_auth
    check_bitwarden_auth

    sync_vaults
}

main "$@"
