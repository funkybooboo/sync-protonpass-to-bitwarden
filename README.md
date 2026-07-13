# Install Proton Pass CLI
curl -fsSL https://proton.me/download/pass-cli/install.sh | bash

# Install Bitwarden CLI
npm install -g @bitwarden/cli

# Install jq
# macOS: brew install jq
# Ubuntu/Debian: sudo apt install jq



# Login to Proton Pass
pass-cli login

# Login and unlock Bitwarden
bw login
# Then follow the unlock instructions
export BW_SESSION="your-session-key"


# Preview what will be synced (recommended first)
./protonpass-to-bitwarden-sync.sh --dry-run

# Sync only new items
./protonpass-to-bitwarden-sync.sh --skip-existing

# Full sync
./protonpass-to-bitwarden-sync.sh
