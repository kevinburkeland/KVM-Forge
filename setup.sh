#!/bin/bash
# Stop script execution immediately if any command fails
set -euo pipefail

# Dynamically determine the directory where this script is located
# This allows the script to be run from anywhere without breaking relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared functions (like logging and dependency checks)
source "${SCRIPT_DIR}/lib/common.sh"

# Ensure the 'gum' tool is installed, which we use for the interactive UI
check_and_install_dependencies "gum"

# Create the config directory if it doesn't already exist
mkdir -p "${SCRIPT_DIR}/config"
# Define the path where we will save the environment variables
ENV_FILE="${SCRIPT_DIR}/config/forge.env"


# Display a stylized header using gum
gum style --foreground 212 --border-foreground 212 --border double --align center --width 50 --margin "1 2" --padding "1 4" 'KVM-Forge Setup'

echo "We need to set up some global variables for your environment."
echo ""

# Gather network configuration from the user using interactive prompts.
# If the user just presses Enter, keep existing config values when present.
echo -e "\n--- Network Topology ---"
echo "KVM uses a virtual network switch (a bridge) to connect your VMs together and out to the internet."
echo "The Bridge Interface Name (usually virbr0) is the name of this virtual switch on your host machine."
echo "The Subnet Scan Range defines the pool of IP addresses KVM-Forge is allowed to assign."
echo "The CIDR Suffix defines the subnet mask length (e.g., 24 means 255.255.255.0)."
echo "By setting the subnet scan range, you can ensure that KVM-Forge does not assign IP addresses that are already in use by other devices on your network."
echo "You can even set it to a small range, such as .64/26, to limit the number of IP addresses that KVM-Forge can assign."
FORGE_BRIDGE_IF=$(gum input --prompt "Bridge Interface Name: " --placeholder "virbr0" --value "${FORGE_BRIDGE_IF:-virbr0}")
FORGE_SUBNET_SCAN=$(gum input --prompt "Subnet Scan Range: " --placeholder "192.168.122.64/26" --value "${FORGE_SUBNET_SCAN:-192.168.122.64/26}")
FORGE_CIDR_SUFFIX=$(gum input --prompt "CIDR Suffix: " --placeholder "24" --value "${FORGE_CIDR_SUFFIX:-24}")

echo -e "\n--- Routing & DNS ---"
echo "These settings are injected into the VM so it knows how to route traffic and resolve names."
echo "Gateway IP: The router address on the virtual network (usually the host machine's virtual IP: 192.168.122.1)."
echo "DNS Search Domain: Appended to short hostnames (e.g., 'ping server' becomes 'ping server.forge.example')."
echo "DNS Servers: The upstream resolvers used to reach the public internet (e.g., Google DNS)."
FORGE_GATEWAY=$(gum input --prompt "Gateway IP: " --placeholder "192.168.122.1" --value "${FORGE_GATEWAY:-192.168.122.1}")
FORGE_DNS_SEARCH=$(gum input --prompt "DNS Search Domain: " --placeholder "forge.example" --value "${FORGE_DNS_SEARCH:-forge.example}")
FORGE_DNS_SERVERS=$(gum input --prompt "DNS Servers (comma separated): " --placeholder "8.8.8.8,8.8.4.4" --value "${FORGE_DNS_SERVERS:-8.8.8.8,8.8.4.4}")

# Gather base domain, default username, and timezone preferences
echo -e "\n--- System Preferences ---"
echo "Base Domain: The root domain name applied to all your VMs for local DNS consistency."
echo "Default VM Username: The unprivileged user created automatically via cloud-init."
echo "Timezone: Ensures log timestamps and system clocks are synchronized across your lab."
FORGE_BASE_DOMAIN=$(gum input --prompt "Base Domain: " --placeholder "forge.example" --value "${FORGE_BASE_DOMAIN:-forge.example}")
FORGE_DEFAULT_USER=$(gum input --prompt "Default VM Username: " --placeholder "forge" --value "${FORGE_DEFAULT_USER:-forge}")
FORGE_TIMEZONE=$(gum input --prompt "Timezone (e.g., America/Los_Angeles): " --placeholder "America/Los_Angeles" --value "${FORGE_TIMEZONE:-America/Los_Angeles}")

# ==========================================
# Networking Context: SSH Key Generation
# Mechanism: Generates an ED25519 SSH keypair if the user doesn't use an existing one.
# Networking Context: ED25519 is an elliptical curve cryptography standard. It is highly
# preferred over older RSA keys because it offers stronger security with significantly 
# shorter keys, resulting in faster cryptographic operations during SSH handshakes.
# ==========================================
echo -e "\n--- SSH Authentication ---"
echo "To enable secure, passwordless automation, KVM-Forge injects an SSH public key into every new VM."
echo "You can provide an existing key, or generate a fresh, KVM-specific ED25519 cryptographic keypair."
echo "Select how you want to handle SSH keys for the VMs:"
SSH_CHOICE=$(gum choose "Use existing public key" "Generate a new ED25519 keypair")

if [ "$SSH_CHOICE" == "Use existing public key" ]; then
    # Try to find a common existing public key
    DEFAULT_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    if [ ! -f "$DEFAULT_KEY_PATH" ]; then
        DEFAULT_KEY_PATH="$HOME/.ssh/id_rsa.pub"
    fi
    
    # Prompt user to confirm or change the path to their public key
    FORGE_SSH_KEY_PATH=$(gum input --prompt "Path to public key: " --value "$DEFAULT_KEY_PATH")
    
    # Verify the provided key actually exists
    if [ ! -f "$FORGE_SSH_KEY_PATH" ]; then
        log_err "Key file not found at $FORGE_SSH_KEY_PATH"
        exit 1
    fi
else
    # The user chose to generate a new key specifically for KVM-Forge
    KEY_PATH="$HOME/.ssh/id_ed25519_kvmforge"
    
    # Check if a key with this name already exists to avoid accidental overwrites
    if [ -f "$KEY_PATH" ]; then
        echo "A key already exists at $KEY_PATH."
        # Ask for confirmation before destroying the old key
        if gum confirm "Do you want to overwrite it?"; then
            rm -f "$KEY_PATH" "${KEY_PATH}.pub"
            # Generate a new ED25519 keypair with no password (-N "") so automation works seamlessly
            ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
            log_info "Generated new key pair at $KEY_PATH"
        else
            log_info "Keeping existing key pair at $KEY_PATH"
        fi
    else
        # Generate the new keypair quietly
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
        log_info "Generated new key pair at $KEY_PATH"
    fi
    # Store the path to the public key
    FORGE_SSH_KEY_PATH="${KEY_PATH}.pub"
fi

# ==========================================
# Infrastructure Logic: Atomic Environment Writes
# Mechanism: Explains how 'mktemp' and 'trap' ensure atomic file writes, preventing
# corrupted environment configurations if the script exits unexpectedly.
# ==========================================
TMP_ENV_FILE=$(mktemp)
trap 'rm -f "${TMP_ENV_FILE:-}"' EXIT
cat > "$TMP_ENV_FILE" <<EOF
FORGE_BRIDGE_IF="$FORGE_BRIDGE_IF"
FORGE_SUBNET_SCAN="$FORGE_SUBNET_SCAN"
FORGE_CIDR_SUFFIX="$FORGE_CIDR_SUFFIX"
FORGE_GATEWAY="$FORGE_GATEWAY"
FORGE_DNS_SEARCH="$FORGE_DNS_SEARCH"
FORGE_DNS_SERVERS="$FORGE_DNS_SERVERS"
FORGE_BASE_DOMAIN="$FORGE_BASE_DOMAIN"
FORGE_DEFAULT_USER="$FORGE_DEFAULT_USER"
FORGE_TIMEZONE="$FORGE_TIMEZONE"
FORGE_SSH_KEY_PATH="$FORGE_SSH_KEY_PATH"
EOF

# Restrict permissions so only the file owner can read or write to it.
# This protects sensitive information like the local network layout.
install -m 600 "$TMP_ENV_FILE" "$ENV_FILE"
rm -f "$TMP_ENV_FILE"

log_info "Setup complete! Configuration saved to $ENV_FILE"
