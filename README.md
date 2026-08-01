# sync-protonpass-to-bitwarden

One-way **upsert sync** from **Proton Pass** to **Bitwarden** -- Proton Pass
is the source of truth.

The script reads every vault in your Proton Pass account via the
[Proton Pass CLI](https://github.com/ProtonPass/pass-cli) (`pass-cli`) and
syncs every item to its closest equivalent in your Bitwarden vault via the
[Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`):

- **Existing** Bitwarden items with the same name **in the same folder** are
  **updated in place** to match Proton (id / org / collections / favorites /
  passkeys already in Bitwarden are preserved).
- **New** items are **created**.
- Nothing is ever **deleted**.

This makes re-runs idempotent -- no duplicates. Re-running after editing a
synced field *in Bitwarden directly* will overwrite your edit with the
Proton value; use `--skip-existing` for items you curate in Bitwarden.

Proton Pass vaults are mirrored as Bitwarden folders, and Proton Pass
`extra_fields` / Custom `sections` are carried over as Bitwarden custom
fields. By default only **Active** (non-trashed) Proton items are synced;
pass `--include-trashed` to also copy trashed items.

## Item type mapping

| Proton Pass type | Bitwarden item | Notes |
| --- | --- | --- |
| login | Login (type 1) | username (falls back to email), password, URLs, TOTP URI. **Passkeys are not migrated** (see Limitations). |
| note | Secure Note (type 2) | note body -> `notes` |
| credit-card | Card (type 3) | cardholder, number, CVC, expiry (split `MM/YY` -> month/year) |
| identity | Identity (type 4) | known fields -> BW slots; the rest -> custom fields (nothing is lost) |
| alias | Secure Note (type 2) | Proton does not expose the alias email; the title (site used) and note are preserved |
| ssh-key | SSH Key (type 8) | private + public key |
| wifi | Secure Note (type 2) | SSID / Security / Password as custom fields |
| custom | Secure Note (type 2) | Custom `sections` are folded into custom fields (prefixed `section / field`) |

All Proton Pass **vaults become Bitwarden folders** (created on demand), and all
**`extra_fields`** become Bitwarden custom fields (`Hidden` -> hidden, `Text` -> text).

## Prerequisites

- **Proton Pass CLI** -- installed and logged in:

  ```sh
  curl -fsSL https://proton.me/download/pass-cli/install.sh | bash
  pass-cli login
  ```

- **Bitwarden CLI** -- installed:

  ```sh
  npm install -g @bitwarden/cli
  ```

  Logging in and unlocking are handled automatically by the script: if
  `bw status` reports `unauthenticated` the script runs `bw login`
  (interactive), and if it reports `locked` it runs `bw unlock --raw` and
  keeps the session for that run only. You can also pre-set `BW_SESSION`
  yourself if you prefer.

  The Bitwarden CLI defaults to the official cloud server
  (`https://vault.bitwarden.com`). To target a self-hosted instance
  such as **Vaultwarden**, set `BW_SERVER` in your `.env` (see
  Configuration) -- the script runs `bw config server` to point `bw`
  at it before authenticating, but only when the current server differs,
  so it is safe to leave set. Leave `BW_SERVER` unset to use whatever
  server `bw` is already configured against; the script will not touch
  `bw`'s persisted config.

  For a one-time manual setup instead:

  ```sh
  bw config server https://vaultwarden.example.com
  bw login you@example.com
  bw sync
  ```

  This persists `serverUrl` in `~/.config/Bitwarden CLI/data.json`, so
  subsequent `bw login` / `bw unlock` / sync calls hit your instance.
  Use the same email and master password that exist on that server.
  Vaultwarden requires HTTPS (the CLI refuses plain HTTP) -- use a
  reverse proxy with a valid certificate. If your instance enforces
  2FA, the CLI will prompt for the code the same as the web vault.
  To switch back to the cloud later: `bw config server` (no url).

- **jq** -- <https://jqlang.github.io/jq/>.

  ```sh
  # macOS
  brew install jq
  # Debian / Ubuntu
  sudo apt install jq
  # Arch
  sudo pacman -S jq
  ```

## Configuration

Options can be set via command-line flags, environment variables, or a `.env`
file. The script **auto-loads `./.env` on startup**, so you never source it
yourself -- it works the same from bash, fish, or zsh. Copy the example,
edit it, then run the script:

```sh
cp .env.example .env
# edit .env
./protonpass-to-bitwarden-sync.sh --dry-run
```

A variable that is already exported in your environment will be overwritten by
the `.env` value, so **comment a value out in `.env`** if you want an
exported environment value to take precedence.

| Variable | Default | Description |
| --- | --- | --- |
| `PROTON_PASS_BIN` | `pass-cli` | Path to the Proton Pass CLI binary. |
| `BITWARDEN_BIN` | `bw` | Path to the Bitwarden CLI binary. |
| `BW_SERVER` | *(unset)* | Bitwarden server URL. When set, the script runs `bw config server` to point `bw` at it (skipped if already matched). Set to a Vaultwarden URL for self-hosted; unset to leave `bw`'s existing config untouched. `.env.example` ships the cloud default (`https://vault.bitwarden.com`). |
| `BW_SESSION` | *(unset)* | Bitwarden unlock session key. **Optional** -- if unset and the vault is locked, the script runs `bw unlock --raw` interactively and keeps the session for the run only. |
| `DRY_RUN` | `false` | `true` previews without writing (same as `--dry-run`). Dry-run skips the Bitwarden server/auth/sync steps, so `bw` need not be logged in. |
| `SKIP_EXISTING` | `false` | `true` leaves existing items untouched, creating only new ones (same as `--skip-existing`). |
| `INCLUDE_TRASHED` | `false` | `true` also syncs trashed Proton items (same as `--include-trashed`). |

`.env` is gitignored -- only `.env.example` is tracked.

## Usage

```sh
# Preview what would be created (recommended first run; bw need not be logged in)
./protonpass-to-bitwarden-sync.sh --dry-run

# Default: upsert -- update existing items, create new ones (Proton is source of truth)
./protonpass-to-bitwarden-sync.sh

# Create new items only; leave existing items untouched
./protonpass-to-bitwarden-sync.sh --skip-existing

# Also include items Proton has moved to Trash
./protonpass-to-bitwarden-sync.sh --include-trashed
```

```
Usage: protonpass-to-bitwarden-sync.sh [OPTIONS]

Options:
  -d, --dry-run           Show what would be created without writing.
  -s, --skip-existing     Leave existing items untouched (no updates, no
                          duplicates; create new items only).
  -t, --include-trashed   Also sync trashed Proton items (default: active only).
  -h, --help              Show this help message.
```

### How matching works

Syncing matches a Bitwarden item to a Proton item by **exact, case-sensitive
name within the same folder**. The script queries Bitwarden with
`bw list items --search <title>` and then filters for an exact `name` match
AND a matching `folderId` (Proton vault -> folder). The same title in two
different folders does not collide. If multiple items match in one folder,
the first is updated and others are left alone (a warning is logged).

`--skip-existing` uses the same match and skips the item entirely instead of
updating it.

## How it works

1. `.env` is auto-loaded (no manual sourcing).
2. `bw sync` refreshes the Bitwarden local cache (so folders and item
   lookups are current).
3. `pass-cli vault list --output json` enumerates vaults
   (`{name, vault_id, share_id}`). Each vault name maps to a Bitwarden
   folder, created on demand via `bw create folder` if it does not already
   exist (`bw list folders` caches the folder id for the run).
4. For each vault, `pass-cli item list --share-id <id> --filter-state active
   --output json --show-secrets` returns every active item including secret
   material (`--include-trashed` drops the state filter).
5. The item's type is detected from the `content.content` variant key
   (`Login`, `Note`, `CreditCard`, `Alias`, `Identity`, `SshKey`, `Wifi`,
   `Custom`).
6. A `jq` filter transforms the Proton Pass item into a Bitwarden item object
   (with `folderId` and `fields`). Secrets flow straight from `jq` into
   `bw encode` and **never pass through shell variables**, so passwords
   containing newlines or quotes are preserved.
7. For an **existing** match, the Proton-derived object is deep-merged onto
   the existing Bitwarden item (`bw get item` -> `jq '. * $new'`) and written
   back with `bw edit item`, preserving `id` / `organizationId` /
   `collectionIds` / `favorite` / `revisionDate` and any BW-side keys Proton
   does not provide. For a **new** item, `bw create item` is used.
8. Summary counters (created / updated / skipped / unsupported / errors) are
   printed at the end.

## Limitations

- **Passkeys are not migrated.** Proton Pass stores passkeys as CBOR
  credential blobs that `bw create item` cannot ingest; the login syncs
  (user/password/TOTP/URLs), but its passkey attachment does not. No data is
  lost -- it remains in Proton Pass; re-add the passkey from a browser if
  needed. An existing passkey already in a Bitwarden login item is
  **preserved** across updates (the deep merge keeps it).
- **Upsert overwrites Bitwarden-side edits.** If you edit a synced field
  directly in Bitwarden, the next run overwrites it with the Proton value.
  Proton Pass is the source of truth. Use `--skip-existing` for items you
  curate in Bitwarden.
- **SSH keys require a server that supports item type 8** (Bitwarden cloud
  and current Vaultwarden do). Servers that predate SSH-key support will fail
  that item with a counted error.
- **`platform_specific` / allowed-apps** have no Bitwarden equivalent and
  are dropped.
- **Identity / Credit-card / Wifi** field names are mapped from Proton Pass's
  documented schemas (verified via `pass-cli item create <type>
  --get-template`). If Proton renames a field, the affected value lands in
  `notes`/custom fields rather than its native slot -- it is never lost.
- **Folder, not collection.** Proton vaults map to Bitwarden *folders*
  (personal organization), not to organization *collections*.
- **No deletes.** The script never deletes Bitwarden items, so items removed
  from Proton remain in Bitwarden after a sync.

## License

GPL-3.0 -- see [LICENSE](LICENSE) (the Proton Pass CLI is GPL-3.0; this
script follows suit).