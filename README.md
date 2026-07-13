# sync-protonpass-to-bitwarden

One-way sync / migration of items from **Proton Pass** to **Bitwarden**.

The script reads every vault in your Proton Pass account via the
[Proton Pass CLI](https://github.com/ProtonPass/pass-cli) (`pass-cli`) and
recreates every item as its closest equivalent in your Bitwarden vault via the
[Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`). Proton Pass vaults
are mirrored as Bitwarden folders, and Proton Pass `extra_fields` / Custom
`sections` are carried over as Bitwarden custom fields.

This is a **create-only** tool: it never modifies or deletes existing
Bitwarden items. Use `--skip-existing` to avoid duplicating items that
already share a name in Bitwarden. By default only **Active** (non-trashed)
Proton items are synced; pass `--include-trashed` to also copy trashed items.

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

- **Bitwarden CLI** -- installed, logged in, and unlocked:

  ```sh
  npm install -g @bitwarden/cli
  bw login
  bw unlock        # prints: export BW_SESSION="..."
  export BW_SESSION="..."   # then re-run the sync script
  ```

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
file. Copy the example and edit it:

```sh
cp .env.example .env
set -a; source .env; set +a
```

| Variable | Default | Description |
| --- | --- | --- |
| `PROTON_PASS_BIN` | `pass-cli` | Path to the Proton Pass CLI binary. |
| `BITWARDEN_BIN` | `bw` | Path to the Bitwarden CLI binary. |
| `BW_SERVER` | *(unset)* | Bitwarden server URL. When set, the script runs `bw config server` to point `bw` at it (skipped if already matched). Set to a Vaultwarden URL for self-hosted; unset to leave `bw`'s existing config untouched. `.env.example` ships the cloud default (`https://vault.bitwarden.com`). |
| `DRY_RUN` | `false` | `true` previews without writing (same as `--dry-run`). Dry-run skips the Bitwarden server/auth/sync steps, so `bw` need not be logged in. |
| `SKIP_EXISTING` | `false` | `true` skips name-matched items (same as `--skip-existing`). |
| `INCLUDE_TRASHED` | `false` | `true` also syncs trashed Proton items (same as `--include-trashed`). |
| `BW_SESSION` | *(unset)* | Bitwarden unlock session key from `bw unlock`. |

`.env` is gitignored -- only `.env.example` is tracked.

## Usage

```sh
# Preview what would be created (recommended first run; bw need not be logged in)
./protonpass-to-bitwarden-sync.sh --dry-run

# Create only items not already present in Bitwarden
./protonpass-to-bitwarden-sync.sh --skip-existing

# Full sync (may create duplicates of existing items)
./protonpass-to-bitwarden-sync.sh

# Also include items Proton has moved to Trash
./protonpass-to-bitwarden-sync.sh --include-trashed
```

```
Usage: protonpass-to-bitwarden-sync.sh [OPTIONS]

Options:
  -d, --dry-run           Show what would be created without writing.
  -s, --skip-existing     Skip items whose name already matches a Bitwarden item.
  -t, --include-trashed   Also sync trashed Proton items (default: active only).
  -h, --help              Show this help message.
```

### How name matching works

`--skip-existing` queries Bitwarden with `bw list items --search <title>` and
then checks for an **exact, case-sensitive** match on `name`. Items whose names
merely *contain* the search term (Bitwarden's default substring behaviour) are
not treated as matches.

## How it works

1. `bw sync` refreshes the Bitwarden local cache (so pre-existing folders and
   `--skip-existing` lookups are current).
2. `pass-cli vault list --output json` enumerates vaults
   (`{name, vault_id, share_id}`). Each vault name maps to a Bitwarden
   folder, created on demand via `bw create folder` if it does not already
   exist (`bw list folders` caches the folder id for the run).
3. For each vault, `pass-cli item list --share-id <id> --filter-state active
   --output json --show-secrets` returns every active item including secret
   material (`--include-trashed` drops the state filter).
4. The item's type is detected from the `content.content` variant key
   (`Login`, `Note`, `CreditCard`, `Alias`, `Identity`, `SshKey`, `Wifi`,
   `Custom`).
5. A `jq` filter transforms the Proton Pass item into a Bitwarden item object
   (with `folderId` and `fields`). Secrets flow straight from `jq` into
   `bw encode | bw create item` and **never pass through shell variables**,
   so passwords containing newlines or quotes are preserved.
6. Summary counters (created / skipped / unsupported / errors) are printed at
   the end.

## Limitations

- **Passkeys are not migrated.** Proton Pass stores passkeys as CBOR
  credential blobs that `bw create item` cannot ingest; the login migrates
  (user/password/TOTP/URLs), but its passkey attachment does not. No data is
  lost -- it remains in Proton Pass; re-add the passkey from a browser if
  needed.
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
- **Create-only.** No updates, no deletes. Re-running without
  `--skip-existing` will create duplicates.

## License

GPL-3.0 -- see [LICENSE](LICENSE) (the Proton Pass CLI is GPL-3.0; this
script follows suit).