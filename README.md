# sync-protonpass-to-bitwarden

One-way sync / migration of items from **Proton Pass** to **Bitwarden**.

The script reads every vault in your Proton Pass account via the
[Proton Pass CLI](https://github.com/ProtonPass/pass-cli) (`pass-cli`) and
recreates supported items as equivalent items in your Bitwarden vault via the
[Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw`).

This is a **create-only** tool: it never modifies or deletes existing
Bitwarden items. Use `--skip-existing` to avoid duplicating items that
already share a name in Bitwarden.

## Supported item types

| Proton Pass type | Bitwarden item | Notes |
| --- | --- | --- |
| login | Login (type 1) | username (falls back to email), password, URLs, TOTP URI |
| note | Secure Note (type 2) | note body -> `notes` |
| credit-card | Card (type 3) | cardholder, number, CVC, expiry (split `MM/YY` -> month/year) |
| alias | -- | skipped (no BW mapping) |
| identity | -- | skipped (no BW mapping) |
| ssh-key | -- | skipped (no BW mapping) |
| wifi | -- | skipped (no BW mapping) |
| custom | -- | skipped (no BW mapping) |

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
  Configuration) -- the script runs `bw config server "$BW_SERVER"`
  before authenticating, so a change there takes effect on the next
  run.

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
| `BW_SERVER` | `https://vault.bitwarden.com` | Bitwarden server URL. Set to a self-hosted/Vaultwarden URL to target it instead. |
| `DRY_RUN` | `false` | `true` previews without writing (same as `--dry-run`). |
| `SKIP_EXISTING` | `false` | `true` skips name-matched items (same as `--skip-existing`). |
| `BW_SESSION` | *(unset)* | Bitwarden unlock session key from `bw unlock`. |

`.env` is gitignored -- only `.env.example` is tracked.

## Usage

```sh
# Preview what would be created (recommended first run)
./protonpass-to-bitwarden-sync.sh --dry-run

# Create only items not already present in Bitwarden
./protonpass-to-bitwarden-sync.sh --skip-existing

# Full sync (may create duplicates of existing items)
./protonpass-to-bitwarden-sync.sh
```

```
Usage: protonpass-to-bitwarden-sync.sh [OPTIONS]

Options:
  -d, --dry-run         Show what would be created without writing anything.
  -s, --skip-existing   Skip items whose name already matches a Bitwarden item.
  -h, --help            Show this help message.
```

### How name matching works

`--skip-existing` queries Bitwarden with `bw list items --search <title>` and
then checks for an **exact, case-sensitive** match on `name`. Items whose names
merely *contain* the search term (Bitwarden's default substring behaviour) are
not treated as matches.

## How it works

1. `pass-cli vault list --output json` enumerates vaults (`{name, vault_id,
   share_id}`).
2. For each vault, `pass-cli item list --share-id <id> --output json
   --show-secrets` returns every item including secret material.
3. The item's type is detected from the `content.content` variant key
   (`Login`, `Note`, `CreditCard`, ...).
4. A `jq` filter transforms the Proton Pass item into a Bitwarden item object.
   Secrets flow straight from `jq` into `bw encode | bw create item` and
   **never pass through shell variables**, so passwords containing newlines or
   quotes are preserved.
5. Summary counters (created / skipped / unsupported / errors) are printed at
   the end.

## Caveats

- **Create-only.** No updates, no deletes. Re-running without
  `--skip-existing` will create duplicates.
- **No folder / collection mapping.** All items land in the default
  Bitwarden collection (`folderId: null`).
- **No custom-field migration.** Proton Pass `extra_fields` and identity
  fields are not carried over.
- **Skipped types** (alias, identity, ssh-key, wifi, custom) are logged but
  not transferred -- there is no clean Bitwarden equivalent for these.
- **Self-hosted servers** (Vaultwarden) are fully supported -- just run
  `bw config server <url>` before `bw login` (see Prerequisites). This
  script makes no assumption about which server `bw` is pointed at.

## License

GPL-3.0 -- see [LICENSE](LICENSE) (the Proton Pass CLI is GPL-3.0; this
script follows suit).