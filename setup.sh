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

echo "We need to configure some global variables for your environment."
echo ""

# Gather network configuration from the user using interactive prompts.
# If the user just presses Enter, keep existing config values when present.
echo -e "\n--- Network Topology ---"
echo "KVM uses a virtual network switch (a bridge) to connect your VMs together and out to the internet."
echo "The Bridge Interface Name (usually virbr0) is the name of this virtual switch on your host machine."
echo "The Subnet Scan Range defines the pool of IP addresses KVM-Forge is allowed to assign."
echo "The CIDR Suffix defines the subnet mask length (e.g., leave as 24 for standard home networks)."
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
# Auto-detect local timezone to suggest on initial run
DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || readlink /etc/localtime | awk -F'/zoneinfo/' '{print $2}' || echo "GMT")
[ -z "$DETECTED_TZ" ] && DETECTED_TZ="GMT"

FORGE_TIMEZONE=$(gum input --prompt "Timezone (e.g., $DETECTED_TZ): " --placeholder "$DETECTED_TZ" --value "${FORGE_TIMEZONE:-$DETECTED_TZ}")

echo "Jupyter Lab Token: The access token for Jupyter Lab datascience profile VMs."
FORGE_JUPYTER_TOKEN=$(gum input --prompt "Jupyter Lab Token: " --placeholder "forge" --value "${FORGE_JUPYTER_TOKEN:-forge}")

# ==========================================
# Systems Engineering: Cryptographic Standards & Key Generation (ED25519 vs RSA)
# In securing non-interactive orchestration infrastructures, selecting the correct key format is vital:
# - RSA (Rivest-Shamir-Adleman) relies on the prime factorization problem. Securing RSA requires extremely long
#   keys (e.g., 4096 bits) to meet modern compliance standards. This incurs larger memory footings, slower key
#   generation, and increased CPU overhead during the modular exponentiation phases of SSH handshakes.
# - ED25519 uses Elliptic Curve Cryptography (specifically Curve25519) to address the discrete logarithm problem.
#   It offers several critical operational advantages:
#   1. Highly compact keys: A 256-bit ED25519 key delivers cryptographic protection equivalent to a 3072-bit RSA key.
#   2. Faster cryptographic handshakes: Shorter keys translate to fewer CPU operations during key exchange cycles,
#      minimizing SSH login latency and server CPU loads under heavy automation loops.
#   3. Resistance to side-channel attacks and random-number generator failure points.
# ==========================================
echo -e "\n--- SSH Authentication ---"
echo "To enable secure, passwordless automation, KVM-Forge injects an SSH public key into every new VM."
echo "You can provide an existing key, or generate a fresh, secure key specifically for KVM."
echo "Select how you want to handle SSH keys for the VMs:"
SSH_CHOICE=$(gum choose "Use existing public key" "Generate a new ED25519 keypair" "Pull public key from GitHub")

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
elif [ "$SSH_CHOICE" == "Generate a new ED25519 keypair" ]; then
    # The user chose to generate a new key specifically for KVM-Forge
    KEY_PATH="$HOME/.ssh/id_ed25519_kvmforge"
    
    # Check if a key with this name already exists to avoid accidental overwrites
    if [ -f "$KEY_PATH" ]; then
        echo "A key already exists at $KEY_PATH."
        # Ask for confirmation before destroying the old key
        if gum confirm "Do you want to overwrite it?"; then
            rm -f "$KEY_PATH" "${KEY_PATH}.pub"
            # Generate a new ED25519 keypair with no password (-N "") so automation works efficiently
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
elif [ "$SSH_CHOICE" == "Pull public key from GitHub" ]; then
    GH_USER=$(gum input --prompt "GitHub Username: " --placeholder "torvalds")
    
    KEY_PATH="$HOME/.ssh/id_github_${GH_USER}.pub"
    
    log_info "Fetching public keys from https://github.com/${GH_USER}.keys..."
    if curl -sSLf "https://github.com/${GH_USER}.keys" -o "$KEY_PATH"; then
        if [ ! -s "$KEY_PATH" ] || ! grep -q '[^[:space:]]' "$KEY_PATH"; then
            log_err "No keys found for GitHub user ${GH_USER}."
            rm -f "$KEY_PATH"
            exit 1
        fi
        if ! ssh-keygen -l -f "$KEY_PATH" &>/dev/null; then
            log_err "Downloaded file does not contain valid SSH public keys."
            rm -f "$KEY_PATH"
            exit 1
        fi
        log_info "Successfully downloaded keys to $KEY_PATH"
        FORGE_SSH_KEY_PATH="$KEY_PATH"
    else
        log_err "Failed to fetch keys for user ${GH_USER}. Please check the username and your internet connection."
        exit 1
    fi
fi

# ==========================================
# Systems Engineering: Atomic File Write Pattern & Secure Configuration Sourcing
# Writing environment configurations directly to target destination files (e.g., config/forge.env) is risky:
# - An unexpected script termination or disk-full event midway through the operation can leave the configuration
#   in a corrupt, partially written state, leading to subsequent parser or sourcing crashes.
# - To avoid this, we use the "Atomic File Write" pattern:
#   1. We spawn a temporary workspace using 'mktemp', creating a unique, empty file in the host system's temp space.
#   2. We set a POSIX 'trap' destructor that guarantees cleanup of the temp file on any script exit or abort.
#   3. We populate the secure variables within the temp file first.
#   4. We atomic-move/install the completed file to its final destination using the 'install' utility.
#   5. The 'install -m 600' command enforces strict POSIX access control lists (owner read-write only). This restricts
#      visibility of private networking architectures and server layouts exclusively to the deploying user, protecting
#      the virtualization environment against local privilege escalation or intelligence leaks.
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
FORGE_JUPYTER_TOKEN="$FORGE_JUPYTER_TOKEN"
EOF

# Restrict permissions so only the file owner can read or write to it.
# This protects sensitive information like the local network layout.
install -m 600 "$TMP_ENV_FILE" "$ENV_FILE"
rm -f "$TMP_ENV_FILE"

# Check if the bridge network switch already exists on the host
if ! ip link show "$FORGE_BRIDGE_IF" >/dev/null 2>&1; then
    echo ""
    log_info "Required network bridge interface '$FORGE_BRIDGE_IF' is missing on your host."
    if gum confirm "Would you like KVM-Furnace to configure and tune this bridge network now?"; then
        # Deduce the full network block from the gateway and CIDR suffix,
        # keeping the nmap scan range subset strictly isolated for KVM-Forge VM allocation.
        local gateway_base
        gateway_base=$(echo "$FORGE_GATEWAY" | cut -d'.' -f1-3)
        local full_subnet="${gateway_base}.0/${FORGE_CIDR_SUFFIX}"
        
        # Execute furnace-tune to prepare host capabilities, bridges, and NAT rules
        sudo "${SCRIPT_DIR}/furnace/bin/furnace-tune" --bridge "$FORGE_BRIDGE_IF" --subnet "$full_subnet" --gateway "$FORGE_GATEWAY"
    else
        log_info "Bridge configuration skipped. Ensure it is configured manually before deploying VMs."
    fi
fi

log_info "Setup complete! Configuration saved to $ENV_FILE"

