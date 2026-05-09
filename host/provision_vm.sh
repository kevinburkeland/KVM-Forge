#!/bin/bash
# Exit the script immediately if any command returns a non-zero exit status
set -euo pipefail

# Dynamically find the script's directory and change into it.
# This guarantees relative paths work correctly no matter where the script is executed from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common library functions (logging, dependency checking, arg parsing)
source "${SCRIPT_DIR}/../lib/common.sh"

# Determine the absolute path to the cloud-init directory
CLOUD_INIT_DIR="${CLOUD_INIT_DIR:-$(realpath "${SCRIPT_DIR}/../cloud-init")}"

# Set fallback variables in case the user hasn't run setup.sh to create forge.env
BRIDGE_IF="${FORGE_BRIDGE_IF:-bridge0}"
SUBNET_SCAN="${FORGE_SUBNET_SCAN:-172.26.70.0/24}"
CIDR_SUFFIX="${FORGE_CIDR_SUFFIX:-16}"



# Finds an unused IP address on the local network for the new VM
get_available_ip() {
    # Perform a fast List Scan (-sL) with nmap to list all theoretically possible IPs in the subnet.
    # mapfile stores the output directly into a bash array called 'all_ips'.
    mapfile -t all_ips < <(nmap -sL -n "$SUBNET_SCAN" | awk '/Nmap scan report for/{print $5}')
    
    # Strip the first IP (network address) and last IP (broadcast address) from the array,
    # as these cannot be assigned to a host.
    if [ ${#all_ips[@]} -gt 2 ]; then
        all_ips=("${all_ips[@]:1:${#all_ips[@]}-2}")
    fi

    # Perform a ping sweep (-sn) to find all IPs that are currently active (Up).
    mapfile -t up_ips < <(sudo nmap -n -sn "$SUBNET_SCAN" -oG - | awk '/Up$/{ print $2 }')

    AVAILABLE_IP=""
    
    # Randomize the IP list using 'shuf' and iterate through them.
    # The first one we find that isn't in the 'up_ips' array becomes our VM's new IP.
    for ip in $(printf "%s\n" "${all_ips[@]}" | shuf); do
        if [[ ! " ${up_ips[*]} " =~ " ${ip} " ]]; then
            AVAILABLE_IP=$ip
            break
        fi
    done

    if [ -z "$AVAILABLE_IP" ]; then
        log_err "No available IPs found in subnet $SUBNET_SCAN"
        exit 1
    fi

    # Export the IP, both standalone and with CIDR notation for the cloud-init yaml.
    export NEWIP_YAML="${AVAILABLE_IP}/${CIDR_SUFFIX}"
    export NEWIP="$AVAILABLE_IP"
}

# Generates a unique, random hostname for the VM
get_random_hostname() {
    # Get a list of all currently known virtual machines via libvirt.
    mapfile -t name_array < <(sudo virsh list --all | grep beltec | awk '{ print $2 }' | cut -d. -f1)

    # Pick a random name from names.txt until we find one that doesn't conflict with an existing VM.
    while true; do
        NEWNAME=$(shuf -n 1 "${CLOUD_INIT_DIR}/common/names.txt")
        if [ ${#name_array[@]} -eq 0 ] || ! printf "%s\n" "${name_array[@]}" | grep -qw "$NEWNAME"; then
            break
        fi
    done

    # Export both the short name and the Fully Qualified Domain Name (FQDN)
    export NEWNAME
    export NEWNAME_FQDN="$NEWNAME.${FORGE_BASE_DOMAIN:-beltec.us}"
}

# Injects our dynamic IP, hostname, and SSH variables into the static cloud-init YAML templates
prepare_cloud_init_config() {
    local user_data_file="$1"
    
    # Create a secure temporary directory that is automatically deleted when the script exits
    TEMP_DIR=$(mktemp -d -t vm_provision_XXXXXX)
    export TEMP_DIR
    
    # Copy the base network configuration into the temporary directory
    cp "${CLOUD_INIT_DIR}/common/network-config" "$TEMP_DIR/"
    
    # Create the meta-data file. Cloud-init looks for this to know it's a "NoCloud" deployment.
    cat > "$TEMP_DIR/meta-data" <<EOF
instance-id: ${NEWNAME_FQDN}
local-hostname: ${NEWNAME_FQDN}
EOF
    # Copy the requested user profile (e.g., docker, python) into the temporary directory
    cp "$user_data_file" "$TEMP_DIR/user-data"

    # A helper function that runs 'yq' to update YAML keys in place without destroying structure.
    yq_edit() {
        local file="$1"
        local query="$2"
        local has_cloud_config=false
        
        # yq sometimes strips the "#cloud-config" header, so we remember if it was there
        if head -n 1 "$file" | grep -q "^#cloud-config"; then
            has_cloud_config=true
        fi
        
        # Apply the yq modification and save to a temporary file
        cat "$file" | yq "$query" > "${file}.tmp"
        
        # Restore the header if it was accidentally removed
        if [ "$has_cloud_config" = true ] && ! head -n 1 "${file}.tmp" | grep -q "^#cloud-config"; then
            sed -i '1i #cloud-config' "${file}.tmp"
        fi
        
        mv "${file}.tmp" "$file"
    }

    # Get the primary network interface name from the distribution module
    export IFACE_NAME="$(get_interface_name)"
    
    # Replace the INTERFACE_NAME placeholder in the network-config with the actual interface
    sed -i "s/INTERFACE_NAME/$IFACE_NAME/g" "$TEMP_DIR/network-config"

    # Use yq to dynamically inject our newly discovered IP address into the YAML structure
    yq_edit "$TEMP_DIR/network-config" ".network.ethernets.${IFACE_NAME}.addresses[0] = env(NEWIP_YAML)"

    # Inject DNS and Gateway settings if they were defined during setup.sh
    if [ -n "${FORGE_GATEWAY:-}" ]; then
        export FORGE_GATEWAY
        yq_edit "$TEMP_DIR/network-config" ".network.ethernets.${IFACE_NAME}.gateway4 = env(FORGE_GATEWAY)"
    fi
    if [ -n "${FORGE_DNS_SEARCH:-}" ]; then
        export FORGE_DNS_SEARCH
        yq_edit "$TEMP_DIR/network-config" ".network.ethernets.${IFACE_NAME}.nameservers.search[0] = env(FORGE_DNS_SEARCH)"
    fi
    if [ -n "${FORGE_DNS_SERVERS:-}" ]; then
        export FORGE_DNS_SERVERS
        # Convert the comma-separated DNS list into a true YAML array
        yq_edit "$TEMP_DIR/network-config" ".network.ethernets.${IFACE_NAME}.nameservers.addresses = (env(FORGE_DNS_SERVERS) | split(\",\"))"
    fi

    # Inject the Hostname and FQDN into the user-data
    export REPNAME="$NEWNAME"
    yq_edit "$TEMP_DIR/user-data" '.hostname = env(REPNAME)'

    export REPNAME_FQDN="$NEWNAME_FQDN"
    yq_edit "$TEMP_DIR/user-data" '.fqdn = env(REPNAME_FQDN)'

    # Inject the Timezone
    if [ -n "${FORGE_TIMEZONE:-}" ]; then
        export FORGE_TIMEZONE
        yq_edit "$TEMP_DIR/user-data" '.timezone = env(FORGE_TIMEZONE)'
    fi

    # Expand the tilde (~) in the SSH path into a true absolute path (e.g., /home/kevin)
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        USER_HOME=$HOME
    fi
    EXPANDED_KEY_PATH="${FORGE_SSH_KEY_PATH:-}"
    EXPANDED_KEY_PATH="${EXPANDED_KEY_PATH/#\~/$USER_HOME}"

    # Read the SSH public key and inject it into the authorized_keys list of the user-data
    if [ -n "$EXPANDED_KEY_PATH" ] && [ -f "$EXPANDED_KEY_PATH" ]; then
        export FORGE_SSH_KEY="$(cat "$EXPANDED_KEY_PATH")"
        yq_edit "$TEMP_DIR/user-data" '.users[0].ssh_authorized_keys[0] = env(FORGE_SSH_KEY)'
    fi

    # Set the default login username
    if [ -n "${FORGE_DEFAULT_USER:-}" ]; then
        export FORGE_DEFAULT_USER
        yq_edit "$TEMP_DIR/user-data" '.users[0].name = env(FORGE_DEFAULT_USER)'
    fi
}

# Actually creates and starts the virtual machine using libvirt
launch_vm() {
    log_info "Launching VM $NEWNAME_FQDN with IP ${NEWIP}..."

    if ! command -v ip >/dev/null 2>&1; then
        log_err "The 'ip' command is required to validate bridge state."
        exit 1
    fi
    if ! ip link show "$BRIDGE_IF" >/dev/null 2>&1; then
        log_err "Bridge interface '$BRIDGE_IF' not found."
        exit 1
    fi

    # virt-install is the command-line tool for KVM/QEMU deployments
    virt-install --name "$NEWNAME_FQDN" \
        --vcpu "$VCPU" \
        --memory "$MEMORY" \
        --noautoconsole \
        --osinfo "name=$OS_VARIANT" \
        --disk="size=${DISK_SIZE},backing_store=/var/lib/libvirt/images/${IMG_NAME}" \
        --network bridge="$BRIDGE_IF" \
        --cloud-init user-data="$TEMP_DIR/user-data,meta-data=$TEMP_DIR/meta-data,network-config=$TEMP_DIR/network-config" \
        --autostart \
        --quiet
}

# The main execution function
main() {
    # Verify we have all required utilities installed
    check_and_install_dependencies "yq" "virt-install" "nmap" "shuf" "wget" "md5sum" "sha256sum"
    
    # Parse CLI flags into variables (e.g., -d ubuntu -c 4)
    parse_vm_args "$@"

    # Source the appropriate distribution module
    DISTRO_MODULE="${SCRIPT_DIR}/../lib/distros/${DISTRO}.sh"
    if [ ! -f "$DISTRO_MODULE" ]; then
        log_err "Distribution module '$DISTRO' not found at $DISTRO_MODULE."
        exit 1
    fi
    source "$DISTRO_MODULE"

    # Verify that the requested configuration profile actually exists
    USER_DATA_FILE="${CLOUD_INIT_DIR}/profiles/${DISTRO}/${PROFILE}.yaml"
    if [ ! -f "$USER_DATA_FILE" ]; then
        log_err "user-data file '$USER_DATA_FILE' does not exist for profile '$PROFILE'."
        exit 1
    fi

    # Determine what the final VM username will be (useful for returning back to the CLI wrapper)
    VM_USER="${FORGE_DEFAULT_USER:-}"
    if [ -z "$VM_USER" ]; then
        VM_USER=$(cat "$USER_DATA_FILE" | yq '.users[0].name')
    fi
    if [ "$VM_USER" == "null" ] || [ -z "$VM_USER" ]; then
        VM_USER="root"
    fi

    # Execute the core logical blocks
    download_os_image
    get_available_ip
    get_random_hostname
    
    # Create a trap that automatically deletes the secure TEMP_DIR when the script finishes or errors out.
    trap 'rm -rf "$TEMP_DIR"' EXIT
    prepare_cloud_init_config "$USER_DATA_FILE"
    
    launch_vm
    
    # Print the core VM details so the kvm-forge-cli wrapper script can capture them
    echo "$NEWNAME_FQDN"
    echo "${NEWIP}"
    echo "$VM_USER"
}

# Only run 'main' if this script is executed directly (not sourced by a test suite)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
