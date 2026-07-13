#!/bin/bash
#
# protonpass-to-bitwarden-sync.sh
# One-way sync/migration of items from Proton Pass to Bitwarden.
#
# Reads every vault in your Proton Pass account and recreates every item
# type (logins, notes, credit cards, aliases, identities, ssh keys, wifi,
# custom) as the closest equivalent item in your Bitwarden vault via the
# Bitwarden CLI (`bw`). Proton Pass vaults are mirrored as Bitwarden
# folders, and Proton "extra fields" / custom "sections" are carried over
# as Bitwarden custom fields.
#
# This is a CREATE-ONLY tool. It never modifies or deletes existing
# Bitwarden items. Use --skip-existing to avoid duplicating items that
# already share a name in Bitwarden. By default only Active (non-trashed)
# Proton items are synced; pass --include-trashed to also copy trashed
# items.
#
# Known limitations (data is never lost -- it stays in Proton Pass):
#   - Passkeys: Proton stores them as CBOR credential blobs that `bw
#     create item` cannot ingest; the login migrates but its passkey
#     attachment does not. Re-add the passkey from a browser if needed.
#   - platform_specific / allowed_apps: no Bitwarden equivalent; dropped.
#   - SSH keys target Bitwarden item type 8 (sshKey); servers that predate
#     SSH-key support will fail that item with a counted error.
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
INCLUDE_TRASHED="${INCLUDE_TRASHED:-false}"

# Bitwarden server URL. When set, the script ensures `bw` is pointed at
# this server before authenticating (skips the call if `bw` is already
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

# folder name -> folder id cache (populated lazily by ensure_folder).
declare -A FOLDER_IDS=()

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
#       "extra_fields": [ { "name": "...", "content": { "Text"|"Hidden": "..." } } ]
#     },
#     "state": "Active" | "Trashed",
#     ...
#   }
#
# <Variant> is exactly one of: Note, Login, Alias, CreditCard, Identity,
# SshKey, Wifi, Custom. Each filter below emits a Bitwarden item object
# suitable for `bw encode | bw create item`. $folderId is passed via
# --arg (empty string -> null so the item lands in "No Folder"). Secrets
# flow straight from jq into bw and never pass through shell variables,
# so passwords containing newlines/quotes are preserved.
# ---------------------------------------------------------------------------

# Proton "extra_fields" -> Bitwarden custom fields (Text -> type 0,
# Hidden -> type 1). Spliced into every filter below.
EF='((.content.extra_fields // []) | map({name: .name, value: (.content.Text // .content.Hidden // ""), type: (if (.content | has("Hidden")) then 1 else 0 end)}))'

# Proton Custom "sections[].section_fields[]" flattened to custom fields
# (prefixed with the section name), plus item-level extra_fields (EF).
CF='([.content.content.Custom.sections[]? | . as $s | .section_fields[]? | {name: ($s.section_name + " / " + .name), value: (.content.Text // .content.Hidden // ""), type: (if (.content | has("Hidden")) then 1 else 0 end)}] + ('"$EF"'))'

# folderId: empty string -> null (Bitwarden "No Folder"); else the id.
FID='folderId: (if $folderId == "" then null else $folderId end),'

LOGIN_FILTER='{
  type: 1,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: ('"$EF"'),
  login: {
    username: ((.content.content.Login.username | select(. != "")) // .content.content.Login.email // ""),
    password: (.content.content.Login.password // ""),
    totp: (.content.content.Login.totp_uri // ""),
    uris: ((.content.content.Login.urls // []) | map({match: null, uri: .}))
  }
}'

# Passkeys (.content.content.Login.passkeys) are intentionally not mapped;
# see the header comment.

NOTE_FILTER='{
  type: 2,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: ('"$EF"'),
  secureNote: { type: 0 }
}'

CARD_FILTER='.content.content.CreditCard as $c | {
  type: 3,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: ('"$EF"'),
  card: {
    cardholderName: $c.cardholder_name,
    number: $c.number,
    code: $c.verification_number,
    expMonth: (($c.expiration_date // "") | split("/") | .[0] // ""),
    expYear:  (($c.expiration_date // "") | split("/") | .[1] // "")
  }
}'

# Alias content is `null` in Proton's export -- the alias email itself is
# not exposed, only the title (site used) and note. It maps to the same
# shape as a Note, so filter_for_type reuses NOTE_FILTER for Alias.

# Identity: map Proton fields onto the Bitwarden identity slots, and put
# every Proton field with no BW slot into custom fields so nothing is
# lost. Field names below are Proton's (verified via `pass-cli item
# create identity --get-template`).
IDENTITY_FILTER='.content.content.Identity as $i | {
  type: 4,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: (
    [ {name:"full_name",          value:($i.full_name // ""),          type:0},
      {name:"birthdate",          value:($i.birthdate // ""),          type:0},
      {name:"gender",             value:($i.gender // ""),             type:0},
      {name:"organization",       value:($i.organization // ""),       type:0},
      {name:"floor",              value:($i.floor // ""),              type:0},
      {name:"county",             value:($i.county // ""),             type:0},
      {name:"website",            value:($i.website // ""),            type:0},
      {name:"personal_website",   value:($i.personal_website // ""),   type:0},
      {name:"x_handle",           value:($i.x_handle // ""),            type:0},
      {name:"linkedin",           value:($i.linkedin // ""),           type:0},
      {name:"reddit",             value:($i.reddit // ""),             type:0},
      {name:"facebook",           value:($i.facebook // ""),           type:0},
      {name:"yahoo",              value:($i.yahoo // ""),              type:0},
      {name:"instagram",          value:($i.instagram // ""),          type:0},
      {name:"job_title",          value:($i.job_title // ""),           type:0},
      {name:"work_email",         value:($i.work_email // ""),          type:0},
      {name:"work_phone_number",  value:($i.work_phone_number // ""),   type:0},
      {name:"second_phone_number",value:($i.second_phone_number // ""),type:0} ]
    | map(select(.value != "")) ) + ('"$EF"'),
  identity: {
    firstName:   ($i.first_name // ""),
    middleName:  ($i.middle_name // ""),
    lastName:    ($i.last_name // ""),
    email:       ($i.email // ""),
    phone:       ($i.phone_number // ""),
    ssn:         ($i.social_security_number // ""),
    passportNumber: ($i.passport_number // ""),
    licenseNumber:  ($i.license_number // ""),
    address1:    ($i.street_address // ""),
    city:        ($i.city // ""),
    state:       ($i.state_or_province // ""),
    postalCode:  ($i.zip_or_postal_code // ""),
    country:     ($i.country_or_region // ""),
    company:     ($i.company // "")
  }
}'

WIFI_FILTER='.content.content.Wifi as $w | {
  type: 2,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: (
    [ {name:"SSID",     value:($w.ssid // ""),     type:0},
      {name:"Security", value:($w.security // ""), type:0},
      {name:"Password", value:($w.password // ""),type:1} ]
    | map(select(.value != "")) ) + ('"$EF"'),
  secureNote: { type: 0 }
}'

SSHKEY_FILTER='.content.content.SshKey as $k | {
  type: 8,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: ('"$EF"'),
  sshKey: {
    privateKey: ($k.private_key // ""),
    publicKey:  ($k.public_key // "")
  }
}'

CUSTOM_FILTER='{
  type: 2,
  name: .content.title,
  notes: .content.note,
  '"$FID"'
  fields: ('"$CF"'),
  secureNote: { type: 0 }
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

sync_bitwarden() {
    # Refresh the local cache so pre-existing folders/items are visible
    # to ensure_folder() and bitwarden_item_exists() in this run.
    if "$BITWARDEN_BIN" sync --quiet >/dev/null 2>&1; then
        log_info "Bitwarden: synced latest vault data"
    else
        log_warn "bw sync failed (server offline?); continuing with local cache"
    fi
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
    # Skip trashed items unless --include-trashed was given.
    if [ "$INCLUDE_TRASHED" = true ]; then
        "$PROTON_PASS_BIN" item list --share-id "$1" --output json --show-secrets 2>/dev/null \
            | jq -c '.items[]?'
    else
        "$PROTON_PASS_BIN" item list --share-id "$1" --filter-state active --output json --show-secrets 2>/dev/null \
            | jq -c '.items[]?'
    fi
}

# ---------------------------------------------------------------------------
# Bitwarden helpers
# ---------------------------------------------------------------------------
ensure_folder() {
    # Resolve (creating if needed) a Bitwarden folder matching the Proton
    # vault name. Result is cached in FOLDER_IDS[name]. Returns 0 on
    # success (id may be empty if creation failed -- item gets no folder).
    local name=$1
    [ -n "${FOLDER_IDS[$name]+set}" ] && return 0
    # In dry-run we don't touch bw (it may not be logged in); preview as
    # "would create" with an empty id so items land in No Folder.
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create folder: $name"
        FOLDER_IDS[$name]=""
        return 0
    fi
    local id
    id=$("$BITWARDEN_BIN" list folders 2>/dev/null \
        | jq -r --arg n "$name" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    if [ -z "$id" ] || [ "$id" = "null" ]; then
        id=$(jq -rn --arg n "$name" '{name:$n}' | "$BITWARDEN_BIN" encode 2>/dev/null \
            | "$BITWARDEN_BIN" create folder 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
    fi
    FOLDER_IDS[$name]=${id:-}
    if [ -z "${id:-}" ]; then
        log_warn "Could not resolve/create BW folder '$name'; its items get no folder."
        return 1
    fi
    log_info "Folder -> $name"
    return 0
}

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
        Alias)      printf '%s' "$NOTE_FILTER" ;;   # same shape as Note
        Identity)   printf '%s' "$IDENTITY_FILTER" ;;
        SshKey)     printf '%s' "$SSHKEY_FILTER" ;;
        Wifi)       printf '%s' "$WIFI_FILTER" ;;
        Custom)     printf '%s' "$CUSTOM_FILTER" ;;
        *)          return 1 ;;
    esac
}

create_bitwarden_item() {
    # $1 = variant key, $2 = title, $3 = folder id, $4 = Proton item JSON
    local variant=$1 title=$2 folder_id=$3 item=$4
    local filter
    filter=$(filter_for_type "$variant") || { log_error "No filter for $variant"; return "$RC_ERROR"; }

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create $variant: $title"
        printf '%s' "$item" | jq -c --arg folderId "$folder_id" "$filter" | jq .
        return "$RC_CREATED"
    fi

    if printf '%s' "$item" | jq -c --arg folderId "$folder_id" "$filter" \
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
    # $1 = vault name (folder + logging), $2 = Proton item JSON
    # Echoes nothing. Returns one of the RC_* codes.
    local vault=$1 item=$2
    local variant title folder_id

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

    # All known Proton variants have a mapping. The fallback counts any
    # future type as unsupported (logged) rather than silently dropping it.
    case "$variant" in
        Login|Note|CreditCard|Alias|Identity|SshKey|Wifi|Custom) ;;
        *)
            log_warn "Skipping unknown type '$variant': $title"
            return "$RC_UNSUPPORTED"
            ;;
    esac

    # Map the Proton vault to a Bitwarden folder (created on demand).
    ensure_folder "$vault" || true
    folder_id="${FOLDER_IDS[$vault]:-}"

    if [ "$SKIP_EXISTING" = true ] && bitwarden_item_exists "$title"; then
        log_info "Skipping existing: $title"
        return "$RC_SKIPPED"
    fi

    create_bitwarden_item "$variant" "$title" "$folder_id" "$item"
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

Sync (create-only) items from Proton Pass to Bitwarden. Every Proton item
type is mapped to its closest Bitwarden equivalent, Proton vaults become
Bitwarden folders, and Proton extra_fields / Custom sections become
Bitwarden custom fields.

Options:
  -d, --dry-run           Show what would be created, including the
                            generated Bitwarden item JSON, without writing.
  -s, --skip-existing     Skip items whose name already matches a BW item.
  -t, --include-trashed   Also sync trashed Proton items (default: active
                            items only).
  -h, --help              Show this help message.

Environment variables:
  PROTON_PASS_BIN     pass-cli binary (default: pass-cli)
  BITWARDEN_BIN       bw binary (default: bw)
  BW_SERVER           Bitwarden server URL. Set to a self-hosted/
                        Vaultwarden URL to target it (the script runs
                        \`bw config server\` then). Unset = leave bw's
                        existing server config untouched. .env.example
                        ships the cloud default (https://vault.bitwarden.com).
  DRY_RUN             "true" = dry-run mode (same as --dry-run).
  SKIP_EXISTING       "true" = skip existing (same as --skip-existing).
  INCLUDE_TRASHED     "true" = include trashed (same as --include-trashed).

Prerequisites (see README for full setup):
  pass-cli (Proton Pass CLI) installed and logged in.
  bw (Bitwarden CLI) installed, logged in, and unlocked (BW_SESSION exported).
  jq installed.

Type mapping:
  Login      -> Bitwarden Login     (user/pw/totp/urls; passkeys are NOT
                                      migrated -- see README limitations)
  Note       -> Bitwarden Secure Note
  CreditCard -> Bitwarden Card
  Identity   -> Bitwarden Identity  (no-slot fields -> custom fields)
  SshKey     -> Bitwarden SSH Key (type 8)
  Wifi       -> Bitwarden Secure Note (SSID/Security/Password custom fields)
  Alias      -> Bitwarden Secure Note (Proton does not expose the alias email)
  Custom     -> Bitwarden Secure Note (sections folded into custom fields)

Notes:
  - CREATE-ONLY: never modifies or deletes existing Bitwarden items.
  - Name matching for --skip-existing is exact and case-sensitive.
  - Trashed Proton items are skipped unless --include-trashed is set.

Examples:
  $0 --dry-run            # preview what would be created
  $0 --skip-existing      # create only items not already in BW
  $0                      # full sync (may create duplicates)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dry-run)         DRY_RUN=true; shift ;;
        -s|--skip-existing)   SKIP_EXISTING=true; shift ;;
        -t|--include-trashed) INCLUDE_TRASHED=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
log_info "Proton Pass -> Bitwarden sync"
log_info "Dry run: $DRY_RUN | Skip existing: $SKIP_EXISTING | Include trashed: $INCLUDE_TRASHED | Server: ${BW_SERVER:-<existing bw config>}"
echo ""

check_deps
check_proton_pass_auth
if [ "$DRY_RUN" = true ]; then
    log_info "Dry-run: skipping Bitwarden server/auth/sync (preview only; bw need not be logged in)."
else
    configure_bitwarden_server
    check_bitwarden_auth
    sync_bitwarden
fi

sync_vaults