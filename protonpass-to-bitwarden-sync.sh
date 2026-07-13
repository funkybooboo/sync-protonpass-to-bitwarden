#!/bin/bash
#
# protonpass-to-bitwarden-sync.sh
# One-way sync/migration of items from Proton Pass to Bitwarden.
#
# Reads every vault in your Proton Pass account and recreates supported
# items (logins, notes, credit cards) as equivalent items in your
# Bitwarden vault via the Bitwarden CLI (`bw`).
#
# This is a CREATE-ONLY tool. It never modifies or deletes existing
# Bitwarden items. Use --skip-existing to avoid duplicating items that
# already share a name in Bitwarden.
#

# We use -uo pipefail (not -e): the counting logic relies on per-item
# return codes from functions, and errexit would make that fragile.
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROTON_PASS_BIN="${PROTON_PASS_BIN:-pass-cli}"
BITWARDEN_BIN="${BITWARDEN_BIN:-bw}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_EXISTING="${SKIP_EXISTING:-false}"

# Bitwarden server URL. When set, the script ensures `bw` is pointed at
# this server before authenticating (skipping the call if `bw` is already
# configured for it). Leave UNSET to use whatever server `bw` is already
# configured against -- the script will not touch bw's persisted settings.
# The .env.example ships a cloud default; set this to a Vaultwarden URL
# for a self-hosted instance.
BW_SERVER="${BW_SERVER:-}"

# Return codes used to tally per-item results.
RC_CREATED=0
RC_ERROR=1
RC_SKIPPED=2
RC_UNSUPPORTED=3

# ---------------------------------------------------------------------------
# Logging
#
# All output goes to stdout/stderr only -- never to a file. Info goes to
# stdout so a log of created/skipped items can be piped; warnings and
# errors go to stderr so they do not pollute that stream.
# ---------------------------------------------------------------------------
log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# jq filters
#
# `pass-cli item list --output json --show-secrets` returns an object:
#
#   { "items": [ <Item>, ... ] }
#
# where each <Item> has the shape (key fields only):
#
#   {
#     "id": "...",
#     "share_id": "...",
#     "content": {
#       "title": "...",
#       "note": "...",
#       "content": { "<Variant>": { ...type-specific fields... } },
#       "extra_fields": [ ... ]
#     },
#     "state": "Active",
#     ...
#   }
#
# <Variant> is exactly one of: Note, Login, Alias, CreditCard, Identity,
# SshKey, Wifi, Custom. The filters below read that structure and emit a
# Bitwarden item object suitable for `bw encode | bw create item`.
# Secrets flow straight from jq into bw and never pass through shell
# variables, so passwords containing newlines/quotes are preserved.
# ---------------------------------------------------------------------------
LOGIN_FILTER='{
  type: 1,
  name: .content.title,
  notes: .content.note,
  folderId: null,
  login: {
    username: ((.content.content.Login.username | select(. != "")) // .content.content.Login.email // ""),
    password: .content.content.Login.password,
    totp: (.content.content.Login.totp_uri // ""),
    uris: ((.content.content.Login.urls // []) | map({match: null, uri: .}))
  }
}'

NOTE_FILTER='{
  type: 2,
  name: .content.title,
  notes: .content.note,
  folderId: null,
  secureNote: { type: 0 }
}'

CARD_FILTER='.content.content.CreditCard as $c | {
  type: 3,
  name: .content.title,
  notes: .content.note,
  folderId: null,
  card: {
    cardholderName: $c.cardholder_name,
    number: $c.number,
    code: $c.verification_number,
    expMonth: (($c.expiration_date // "") | split("/") | .[0] // ""),
    expYear: (($c.expiration_date // "") | split("/") | .[1] // "")
  }
}'

# ---------------------------------------------------------------------------
# Dependency / auth checks
# ---------------------------------------------------------------------------
check_deps() {
    local missing=0
    if ! command -v "$PROTON_PASS_BIN" >/dev/null 2>&1; then
        log_error "Proton Pass CLI ($PROTON_PASS_BIN) not found in PATH."
        log_error "Install: curl -fsSL https://proton.me/download/pass-cli/install.sh | bash"
        missing=1
    fi
    if ! command -v "$BITWARDEN_BIN" >/dev/null 2>&1; then
        log_error "Bitwarden CLI ($BITWARDEN_BIN) not found in PATH."
        log_error "Install: npm install -g @bitwarden/cli"
        missing=1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not installed."
        missing=1
    fi
    [ "$missing" -eq 0 ] || exit 1
}

configure_bitwarden_server() {
    # If BW_SERVER is unset, leave bw's existing config alone (don't
    # rewrite data.json). When set, only call `bw config server` if the
    # current server differs -- makes the run idempotent and avoids
    # clobbering a self-hosted setup for users who didn't set BW_SERVER.
    local current
    current=$("$BITWARDEN_BIN" status 2>/dev/null | jq -r '.serverUrl // empty' 2>/dev/null)
    if [ -z "$BW_SERVER" ]; then
        log_info "Bitwarden server: ${current:-<bw default>} (BW_SERVER unset; using bw's existing config)"
        return 0
    fi
    if [ "$current" = "$BW_SERVER" ]; then
        log_info "Bitwarden server: $BW_SERVER"
        return 0
    fi
    if ! "$BITWARDEN_BIN" config server "$BW_SERVER" --quiet >/dev/null 2>&1; then
        log_error "Could not set Bitwarden server to: $BW_SERVER"
        log_error "Run manually: $BITWARDEN_BIN config server '$BW_SERVER'"
        exit 1
    fi
    log_info "Bitwarden server: $BW_SERVER"
}

check_proton_pass_auth() {
    if ! "$PROTON_PASS_BIN" test >/dev/null 2>&1; then
        log_error "Not logged into Proton Pass (or connection failed)."
        log_error "Run: $PROTON_PASS_BIN login"
        exit 1
    fi
    log_info "Proton Pass: authenticated"
}

check_bitwarden_auth() {
    local status
    status=$("$BITWARDEN_BIN" status 2>/dev/null | jq -r '.status // empty' 2>/dev/null)
    if [ -z "$status" ]; then
        log_error "Could not read Bitwarden status. Is '$BITWARDEN_BIN' working?"
        exit 1
    fi
    case "$status" in
        unauthenticated)
            log_error "Not logged into Bitwarden. Run: $BITWARDEN_BIN login"
            exit 1 ;;
        locked)
            log_error "Bitwarden vault is locked. Run: $BITWARDEN_BIN unlock"
            log_error "then export BW_SESSION as printed and re-run this script."
            exit 1 ;;
        unlocked)
            log_info "Bitwarden: vault unlocked" ;;
        *)
            log_error "Unknown Bitwarden status: $status"
            exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Proton Pass accessors
# ---------------------------------------------------------------------------
get_proton_vaults() {
    # Emits one compact vault object per line: {name, vault_id, share_id}
    "$PROTON_PASS_BIN" vault list --output json 2>/dev/null | jq -c '.vaults[]?'
}

get_proton_items() {
    # $1 = share id. Emits one compact <Item> per line (with secrets).
    "$PROTON_PASS_BIN" item list --share-id "$1" --output json --show-secrets 2>/dev/null \
        | jq -c '.items[]?'
}

# ---------------------------------------------------------------------------
# Bitwarden helpers
# ---------------------------------------------------------------------------
bitwarden_item_exists() {
    # Returns rc 0 if a Bitwarden item with an exact-name match exists.
    local name=$1
    "$BITWARDEN_BIN" list items --search "$name" 2>/dev/null \
        | jq -e --arg name "$name" 'any((. // [])[]; .name == $name)' >/dev/null 2>&1
}

filter_for_type() {
    case "$1" in
        Login)      printf '%s' "$LOGIN_FILTER" ;;
        Note)       printf '%s' "$NOTE_FILTER" ;;
        CreditCard) printf '%s' "$CARD_FILTER" ;;
        *)          return 1 ;;
    esac
}

create_bitwarden_item() {
    # $1 = variant key, $2 = title, $3 = Proton item JSON
    local variant=$1 title=$2 item=$3
    local filter
    filter=$(filter_for_type "$variant") || { log_error "No filter for $variant"; return "$RC_ERROR"; }

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create $variant: $title"
        printf '%s' "$item" | jq -c "$filter" | jq .
        return "$RC_CREATED"
    fi

    if printf '%s' "$item" | jq -c "$filter" \
        | "$BITWARDEN_BIN" encode \
        | "$BITWARDEN_BIN" create item >/dev/null 2>&1; then
        log_info "Created $variant: $title"
        return "$RC_CREATED"
    fi
    log_error "Failed to create: $title"
    return "$RC_ERROR"
}

# ---------------------------------------------------------------------------
# Per-item processing
# ---------------------------------------------------------------------------
process_item() {
    # $1 = vault name (for logging), $2 = Proton item JSON
    # Echoes nothing. Returns one of the RC_* codes.
    local vault=$1 item=$2
    local variant title

    variant=$(printf '%s' "$item" | jq -r '.content.content | keys[0] // empty' 2>/dev/null)
    title=$(printf '%s' "$item"   | jq -r '.content.title // empty' 2>/dev/null)

    if [ -z "$title" ]; then
        log_warn "Skipping item with no title (vault: $vault)"
        return "$RC_SKIPPED"
    fi
    if [ -z "$variant" ]; then
        log_warn "Skipping item with unrecognised content (vault: $vault): $title"
        return "$RC_SKIPPED"
    fi

    # Only logins, notes and credit cards are supported.
    case "$variant" in
        Login|Note|CreditCard) ;;
        *)
            log_warn "Skipping unsupported type '$variant': $title"
            return "$RC_UNSUPPORTED"
            ;;
    esac

    if [ "$SKIP_EXISTING" = true ] && bitwarden_item_exists "$title"; then
        log_info "Skipping existing: $title"
        return "$RC_SKIPPED"
    fi

    create_bitwarden_item "$variant" "$title" "$item"
}

# ---------------------------------------------------------------------------
# Main sync
# ---------------------------------------------------------------------------
sync_vaults() {
    log_info "Starting sync from Proton Pass to Bitwarden..."

    local total=0 created=0 skipped=0 unsupported=0 errors=0
    local vault share_id share_name items

    while IFS= read -r vault; do
        [ -n "$vault" ] || continue
        share_id=$(printf '%s' "$vault" | jq -r '.share_id // empty' 2>/dev/null)
        share_name=$(printf '%s' "$vault" | jq -r '.name // "Unknown"' 2>/dev/null)
        if [ -z "$share_id" ]; then
            log_warn "Vault without share_id, skipping: $share_name"
            continue
        fi

        log_info "Processing vault: $share_name"
        items=$(get_proton_items "$share_id")
        if [ -z "$items" ]; then
            log_info "  No items in vault: $share_name"
            continue
        fi

        local rc
        while IFS= read -r item; do
            [ -n "$item" ] || continue
            total=$((total + 1))
            process_item "$share_name" "$item"; rc=$?
            case "$rc" in
                "$RC_CREATED")     created=$((created + 1)) ;;
                "$RC_SKIPPED")     skipped=$((skipped + 1)) ;;
                "$RC_UNSUPPORTED") unsupported=$((unsupported + 1)) ;;
                "$RC_ERROR")       errors=$((errors + 1)) ;;
            esac
        done <<<"$items"
    done < <(get_proton_vaults)

    log_info "========================================"
    log_info "Sync complete"
    log_info "  Total items:  $total"
    log_info "  Created:      $created"
    log_info "  Skipped:      $skipped"
    log_info "  Unsupported:  $unsupported"
    log_info "  Errors:       $errors"
    log_info "========================================"
    [ "$errors" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Usage / arg parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Sync (create-only) items from Proton Pass to Bitwarden.

Options:
  -d, --dry-run         Show what would be created, including the generated
                         Bitwarden item JSON, without writing anything.
  -s, --skip-existing   Skip items whose name already matches a Bitwarden item.
  -h, --help            Show this help message.

Environment variables:
  PROTON_PASS_BIN       pass-cli binary (default: pass-cli)
  BITWARDEN_BIN         bw binary (default: bw)
  BW_SERVER             Bitwarden server URL. Set to a self-hosted/Vaultwarden URL
                        to target it (the script runs `bw config server` then).
                        Unset to leave bw's existing server config untouched.
                        .env.example ships the cloud default
                        (https://vault.bitwarden.com).
  DRY_RUN               Set to "true" for dry-run mode (same as --dry-run)
  SKIP_EXISTING         Set to "true" to skip existing (same as --skip-existing)

Prerequisites (see README for full setup):
  pass-cli (Proton Pass CLI) installed, logged in.
  bw (Bitwarden CLI) installed, logged in, and unlocked (BW_SESSION exported).
  jq installed.

Supported Proton Pass item types:
  login, note, credit-card -> recreated as Bitwarden items.
  alias, identity, ssh-key, wifi, custom -> skipped (no BW equivalent mapped).

Notes:
  - CREATE-ONLY: never modifies or deletes existing Bitwarden items.
  - Name matching for --skip-existing is exact and case-sensitive.

Examples:
  $0 --dry-run            # preview what would be created
  $0 --skip-existing      # create only items not already present in BW
  $0                      # full sync (may create duplicates)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dry-run)       DRY_RUN=true; shift ;;
        -s|--skip-existing) SKIP_EXISTING=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
log_info "Proton Pass -> Bitwarden sync"
log_info "Dry run: $DRY_RUN | Skip existing: $SKIP_EXISTING | Server: ${BW_SERVER:-<existing bw config>}"
echo ""

check_deps
configure_bitwarden_server
check_proton_pass_auth
check_bitwarden_auth

sync_vaults