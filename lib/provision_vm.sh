#!/bin/bash
# Exit the script immediately if any command returns a non-zero exit status
set -euo pipefail

# Dynamically find the script's directory and change to the repository root.
# This guarantees relative paths work correctly no matter where the script is executed from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${BATS_RUNNING:-}" ]; then
    cd "${SCRIPT_DIR}/.."
fi

# Source the common library functions (logging, dependency checking, arg parsing)
source "${SCRIPT_DIR}/common.sh"

# Determine the absolute path to the cloud-init directory
CLOUD_INIT_DIR="${CLOUD_INIT_DIR:-$(realpath "${SCRIPT_DIR}/../cloud-init")}"

# Set fallback variables in case the user hasn't run setup.sh to create forge.env
BRIDGE_IF="${FORGE_BRIDGE_IF:-virbr0}"
IP_POOL="${FORGE_IP_POOL:-192.168.122.0/24}"
CIDR_SUFFIX="${FORGE_CIDR_SUFFIX:-24}"



# ==========================================
# Function: expand_cidr
# Mechanism: Generates a list of all IP addresses within the specified CIDR block.
# ==========================================
expand_cidr() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local mask="${cidr#*/}"
    
    # Fallback to 24 if no CIDR mask is specified
    if [[ "$ip" == "$mask" ]]; then
        mask=24
    fi

    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    local ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    
    # Calculate wildcard mask / size
    local num_hosts=$(( 1 << (32 - mask) ))
    
    # Calculate network address by zeroing out host bits
    local mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    local net_int=$(( ip_int & mask_int ))
    
    for ((i=0; i<num_hosts; i++)); do
        local curr=$(( net_int + i ))
        local n1=$(( (curr >> 24) & 255 ))
        local n2=$(( (curr >> 16) & 255 ))
        local n3=$(( (curr >> 8) & 255 ))
        local n4=$(( curr & 255 ))
        echo "${n1}.${n2}.${n3}.${n4}"
    done
}

# ==========================================
# Function: run_arping
# Mechanism: Runs arping to check if an IP is active on the network.
# Adapts timeout flags dynamically based on the installed arping version:
# - Thomas Habets version: -w is in microseconds (uses 100000 usec / 100ms).
# - iputils version: -W is in seconds (uses 1 second).
# ==========================================
run_arping() {
    local target_ip="$1"
    
    # If arping output contains "Thomas Habets", customize flags accordingly
    if sudo arping -h 2>&1 | grep -q "Thomas Habets"; then
        sudo arping -c 1 -w 100000 -I "$BRIDGE_IF" "$target_ip" >/dev/null 2>&1
    else
        sudo arping -c 1 -W 1 -I "$BRIDGE_IF" "$target_ip" >/dev/null 2>&1
    fi
}

# ==========================================
# Function: get_available_ip
# Mechanism: Uses 'arping' to scan the designated subnet and finds an IP that isn't currently responding.
# Networking Context: It first expands the CIDR block to generate all possible IPs,
# removes the network (.0) and broadcast (.255) addresses, then performs an ARP ping check on
# shuffled candidates. Finally, it picks the first IP that doesn't respond to avoid conflicts.
# ==========================================
get_available_ip() {
    # Generate all theoretically possible IPs in the subnet using expand_cidr.
    # mapfile stores the output directly into a bash array called 'all_ips'.
    mapfile -t all_ips < <(expand_cidr "$IP_POOL")
    
    # Strip the first IP (network address) and last IP (broadcast address) from the array,
    # as these cannot be assigned to a host.
    if [ ${#all_ips[@]} -gt 2 ]; then
        all_ips=("${all_ips[@]:1:${#all_ips[@]}-2}")
    fi

    AVAILABLE_IP=""
    
    # Randomize the IP list using 'shuf' and iterate through them.
    # The first one we find that doesn't respond to arping becomes our VM's new IP.
    for ip in $(printf "%s\n" "${all_ips[@]}" | shuf); do
        if ! run_arping "$ip"; then
            AVAILABLE_IP=$ip
            break
        fi
    done

    if [ -z "$AVAILABLE_IP" ]; then
        log_err "No available IPs found in pool $IP_POOL"
        exit 1
    fi

    # Export the IP, both standalone and with CIDR notation for the cloud-init yaml.
    export NEWIP_YAML="${AVAILABLE_IP}/${CIDR_SUFFIX}"
    export NEWIP="$AVAILABLE_IP"
}

# ==========================================
# Function: get_random_hostname
# Mechanism: Randomly selects a name from names.txt and verifies it doesn't already exist.
# Standardization: Appends the 'forge.example' base domain to the chosen name. This ensures
# all VMs in the lab adhere to the same Fully Qualified Domain Name (FQDN) structure, 
# making DNS configuration and inter-VM networking predictable.
# ==========================================
get_random_hostname() {
    # Get a list of all currently known virtual machines via libvirt.
    mapfile -t name_array < <(sudo virsh list --all | grep forge.example | awk '{ print $2 }' | cut -d. -f1)

    # Pick a random name from names.txt until we find one that doesn't conflict with an existing VM.
    while true; do
        NEWNAME=$(shuf -n 1 "${CLOUD_INIT_DIR}/common/names.txt")
        if [ ${#name_array[@]} -eq 0 ] || ! printf "%s\n" "${name_array[@]}" | grep -w "$NEWNAME" >/dev/null; then
            break
        fi
    done

    # Export both the short name and the Fully Qualified Domain Name (FQDN)
    export NEWNAME
    export NEWNAME_FQDN="$NEWNAME.${FORGE_BASE_DOMAIN:-forge.example}"
}

# ==========================================
# Function: prepare_cloud_init_config
# Mechanism: Stages the static YAML templates into a temporary directory and dynamically injects values.
# Infrastructure Logic: Uses 'yq' (a command-line YAML processor) to surgically insert the
# chosen IP, hostname, and SSH keys into the templates without breaking the YAML structure.
# Networking Context: Specifically overwrites the network-config with the correct default gateway,
# DNS search domain, and nameservers required for the VM to route traffic out to the internet.
# ==========================================
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
    # Copy the requested user profile (e.g., docker, python, testing) into the temporary directory
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
        
        # Apply the yq modification and save to a temporary file, piping via STDIN redirection to support Snap confinement
        yq "$query" < "$file" > "${file}.tmp"
        
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

    # Build a single chained query to edit network-config in one pass
    local net_query=".network.ethernets.${IFACE_NAME}.addresses[0] = env(NEWIP_YAML)"
    if [ -n "${FORGE_GATEWAY:-}" ]; then
        export FORGE_GATEWAY
        net_query="${net_query} | .network.ethernets.${IFACE_NAME}.gateway4 = env(FORGE_GATEWAY)"
    fi
    if [ -n "${FORGE_DNS_SEARCH:-}" ]; then
        export FORGE_DNS_SEARCH
        net_query="${net_query} | .network.ethernets.${IFACE_NAME}.nameservers.search[0] = env(FORGE_DNS_SEARCH)"
    fi
    if [ -n "${FORGE_DNS_SERVERS:-}" ]; then
        export FORGE_DNS_SERVERS
        # Convert the comma-separated DNS list into a true YAML array
        net_query="${net_query} | .network.ethernets.${IFACE_NAME}.nameservers.addresses = (env(FORGE_DNS_SERVERS) | split(\",\"))"
    fi

    # Use yq to dynamically inject our newly discovered network settings in one call
    yq_edit "$TEMP_DIR/network-config" "$net_query"

    # Inject the Hostname and FQDN into the user-data
    export REPNAME="$NEWNAME"
    export REPNAME_FQDN="$NEWNAME_FQDN"
    local user_query=".hostname = env(REPNAME) | .fqdn = env(REPNAME_FQDN)"

    # Inject the Timezone
    if [ -n "${FORGE_TIMEZONE:-}" ]; then
        export FORGE_TIMEZONE
        user_query="${user_query} | .timezone = env(FORGE_TIMEZONE)"
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
        user_query="${user_query} | .users[0].ssh_authorized_keys[0] = env(FORGE_SSH_KEY)"
    fi

    # Set the default login username
    if [ -n "${FORGE_DEFAULT_USER:-}" ]; then
        export FORGE_DEFAULT_USER
        user_query="${user_query} | .users[0].name = env(FORGE_DEFAULT_USER)"
    fi

    # Run yq once for user-data!
    yq_edit "$TEMP_DIR/user-data" "$user_query"

    # Replace the Jupyter Lab token placeholder if it exists in the user-data profile
    sed -i "s@JUPYTER_TOKEN_PLACEHOLDER@${FORGE_JUPYTER_TOKEN:-forge}@g" "$TEMP_DIR/user-data"
}

# ==========================================
# Function: launch_vm
# Mechanism: Uses the 'virt-install' command to actually spin up the KVM virtual machine.
# Systems Engineering: Backing Store & Sparse Files (Thin Provisioning)
# - The '--disk backing_store=...' flag utilizes QEMU's copy-on-write (COW) capabilities.
# - Instead of duplicating a multi-gigabyte OS image for every virtual machine, the new VM's disk is created
#   as a thin-provisioned layer referencing a shared, read-only base image (the backing store).
# - Guest read requests are satisfied from the shared base image, while all write requests (mutations) are stored
#   in a separate, sparse delta file (qcow2 format). This saves massive amounts of physical host disk space
#   and dramatically speeds up VM creation times from minutes to seconds.
#
# Systems Engineering: Host-Guest Coordination (QEMU Guest Agent)
# - We install and enable the 'qemu-guest-agent' daemon in our cloud-init profiles.
# - The agent runs inside the guest OS and opens a secure, dedicated virtio-serial communication link directly
#   to the host hypervisor (QEMU).
# - Through this channel, the host can execute administrative tasks out-of-band—such as querying the guest's
#   live network interface IP addresses, syncing system clocks, and coordinating graceful ACPI-based power shutdowns
#   without requiring SSH or network access to the guest.
# ==========================================
launch_vm() {
    log_info "Launching VM $NEWNAME_FQDN with IP ${NEWIP}..."

    if ! command -v ip >/dev/null 2>&1; then
        log_err "The 'ip' command is required to validate bridge state."
        exit 1
    fi
    if ! ip link show dev "$BRIDGE_IF" >/dev/null 2>&1; then
        log_err "Bridge interface '$BRIDGE_IF' not found."
        exit 1
    fi

    local -a extra_args=()
    if [ "$DISTRO" = "gentoo" ]; then
        extra_args+=( "--sysinfo" "type=smbios,system_serial=ds=nocloud" )
        extra_args+=( "--boot" "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no" )
        extra_args+=( "--tpm" "none" )
    fi

    # virt-install is the command-line tool for KVM/QEMU deployments
    virt-install --name "$NEWNAME_FQDN" \
        --vcpu "$VCPU" \
        --memory "$MEMORY" \
        --noautoconsole \
        --osinfo "name=$OS_VARIANT" \
        --disk="size=${DISK_SIZE},backing_store=/var/lib/libvirt/images/${IMG_NAME}" \
        --network bridge="$BRIDGE_IF" \
        "${extra_args[@]}" \
        --cloud-init user-data="$TEMP_DIR/user-data,meta-data=$TEMP_DIR/meta-data,network-config=$TEMP_DIR/network-config" \
        --autostart \
        --quiet
}

# ==========================================
# Function: get_interface_name
# Mechanism: Queries the central manifest.yaml using yq to determine the correct
# network interface name for the selected distribution.
# ==========================================
get_interface_name() {
    yq ".distros.${DISTRO}.interface" < "${SCRIPT_DIR}/../config/manifest.yaml"
}

# ==========================================
# Function: download_os_image
# Mechanism: Centralized download and verification logic for all Linux distributions.
# Resolves dynamic builds for Fedora and Gentoo, then invokes verify_and_sync_image.
# ==========================================
download_os_image() {
    local manifest_file="${SCRIPT_DIR}/../config/manifest.yaml"
    local checksum_type
    checksum_type=$(yq ".distros.${DISTRO}.checksum_type" < "$manifest_file")
    local os_variant_prefix
    os_variant_prefix=$(yq ".distros.${DISTRO}.os_variant_prefix" < "$manifest_file")

    case "$DISTRO" in
        ubuntu)
            local target_img_name="ubuntu-${VERSION}-server-cloudimg-amd64.img"
            local os_variant="${os_variant_prefix}${VERSION}"
            local checksum_file="ubuntu-${VERSION}-MD5SUMS"
            local image_url="https://cloud-images.ubuntu.com/releases/${VERSION}/release/${target_img_name}"
            local checksum_url="https://cloud-images.ubuntu.com/releases/${VERSION}/release/MD5SUMS"
            verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "$checksum_type" "$target_img_name" "$os_variant"
            ;;
        debian)
            local codename
            codename=$(yq ".distros.debian.codenames.\"${VERSION}\"" < "$manifest_file")
            if [ "$codename" == "null" ] || [ -z "$codename" ]; then
                log_err "Unsupported Debian version or missing codename in manifest: $VERSION"
                exit 1
            fi
            local target_img_name="debian-${VERSION}-generic-amd64.qcow2"
            local os_variant="${os_variant_prefix}${VERSION}"
            local checksum_file="debian-${VERSION}-SHA512SUMS"
            local image_url="https://cloud.debian.org/images/cloud/${codename}/latest/${target_img_name}"
            local checksum_url="https://cloud.debian.org/images/cloud/${codename}/latest/SHA512SUMS"
            verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "$checksum_type" "$target_img_name" "$os_variant"
            ;;
        alma)
            local target_img_name="AlmaLinux-${VERSION}-GenericCloud-latest.x86_64.qcow2"
            local os_variant="${os_variant_prefix}${VERSION}"
            local checksum_file="alma-${VERSION}-CHECKSUM"
            local image_url="https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/${target_img_name}"
            local checksum_url="https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/CHECKSUM"
            verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "$checksum_type" "$target_img_name" "$os_variant"
            ;;
        fedora)
            local release_number=""
            if [ -n "${BATS_RUNNING:-}" ]; then
                release_number="1.7"
            else
                local mirror_list_url="https://mirrors.fedoraproject.org/mirrorlist?path=pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/"
                log_info "Resolving closest Fedora mirror for version ${VERSION}..."
                local mirror_url=""
                if command -v curl &> /dev/null; then
                    mirror_url=$(curl -s "$mirror_list_url" | grep -v '^#' | grep -E '^https?://' | head -n 1)
                elif command -v wget &>/dev/null; then
                    mirror_url=$(wget -qO- "$mirror_list_url" | grep -v '^#' | grep -E '^https?://' | head -n 1)
                fi

                if [ -n "$mirror_url" ]; then
                    log_info "Fetching Fedora directory index from mirror: $mirror_url"
                    local html_index=""
                    if command -v curl &> /dev/null; then
                        html_index=$(curl -s "$mirror_url")
                    elif command -v wget &>/dev/null; then
                        html_index=$(wget -qO- "$mirror_url")
                    fi
                    
                    if [ -n "$html_index" ]; then
                        release_number=$(echo "$html_index" | grep -oE "Fedora-Cloud-Base-Generic-${VERSION}-[0-9.]+\.x86_64\.qcow2" | head -n 1 | sed -E "s/Fedora-Cloud-Base-Generic-${VERSION}-([0-9.]+)\.x86_64\.qcow2/\1/")
                        if [ -n "$release_number" ]; then
                            log_info "Successfully resolved Fedora build number dynamically: $release_number"
                        fi
                    fi
                fi
            fi

            if [ -z "$release_number" ]; then
                case "$VERSION" in
                    "44") release_number="1.7" ;;
                    "43") release_number="1.6" ;;
                    *)
                        log_err "Fedora version $VERSION not found in local fallback database. Attempting default '1.7'."
                        release_number="1.7"
                        ;;
                esac
                log_info "Using fallback build number: $release_number"
            fi

            local target_img_name="Fedora-Cloud-Base-Generic-${VERSION}-latest.x86_64.qcow2"
            local os_variant="${os_variant_prefix}${VERSION}"
            local checksum_file="Fedora-Cloud-${VERSION}-${release_number}-x86_64-CHECKSUM"
            local image_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${VERSION}-${release_number}.x86_64.qcow2"
            local checksum_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/Fedora-Cloud-${VERSION}-${release_number}-x86_64-CHECKSUM"
            verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "$checksum_type" "$target_img_name" "$os_variant"
            ;;
        gentoo)
            local latest_path=""
            local real_version=""

            if [ "$VERSION" = "latest" ]; then
                if [ -n "${BATS_RUNNING:-}" ] && { [ ! -f "latest-di-amd64-cloudinit.txt" ] || [ ! -s "latest-di-amd64-cloudinit.txt" ]; }; then
                    echo "20260510T170106Z/di-amd64-cloudinit-20260510T170106Z.qcow2 1380843520" > "latest-di-amd64-cloudinit.txt"
                fi

                if [ -z "${BATS_RUNNING:-}" ]; then
                    rm -f "latest-di-amd64-cloudinit.txt"
                fi

                if [ ! -f "latest-di-amd64-cloudinit.txt" ] || [ ! -s "latest-di-amd64-cloudinit.txt" ]; then
                    log_info "Downloading latest Gentoo cloud image manifest..."
                    wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-di-amd64-cloudinit.txt" -O "latest-di-amd64-cloudinit.txt"
                fi

                while IFS= read -r line || [ -n "$line" ]; do
                    if [[ "$line" =~ ^[0-9]{8}T[0-9]{6}Z/ ]]; then
                        latest_path="${line%% *}"
                        break
                    fi
                done < latest-di-amd64-cloudinit.txt

                if [ -z "$latest_path" ]; then
                    log_err "Failed to parse latest path from Gentoo manifest."
                    exit 1
                fi
                real_version=$(echo "$latest_path" | cut -d'/' -f1)
            else
                real_version="$VERSION"
                latest_path="${real_version}/di-amd64-cloudinit-${real_version}.qcow2"
            fi

            local real_img_name="di-amd64-cloudinit-${real_version}.qcow2"
            local real_checksum_file="di-amd64-cloudinit-${real_version}.qcow2.sha256"
            local image_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_path}"
            local checksum_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_path}.sha256"
            
            # Export REAL_VERSION so verify_and_sync_image can display it in log
            export REAL_VERSION="$real_version"

            verify_and_sync_image "$image_url" "$checksum_url" "$real_checksum_file" "$checksum_type" "di-amd64-cloudinit-latest.qcow2" "$os_variant_prefix"
            ;;
        *)
            log_err "Unsupported distro: $DISTRO"
            exit 1
            ;;
    esac
}

# The main execution function
main() {
    # Ensure the script is run with root privileges (bypass in test suite)
    if [ -z "${BATS_RUNNING:-}" ] && [ "$EUID" -ne 0 ]; then
        log_err "This script must be run with sudo or as root. Please run: sudo $0 $@"
        exit 1
    fi

    # Verify we have all required utilities installed
    check_and_install_dependencies "yq" "virt-install" "arping" "shuf" "wget" "md5sum" "sha256sum" "libvirt-daemon"
    
    # Parse CLI flags into variables (e.g., -d ubuntu -c 4)
    parse_vm_args "$@"

    # Verify the distro is supported
    case "$DISTRO" in
        ubuntu|debian|alma|gentoo|fedora) ;;
        *)
            log_err "Unsupported distro: $DISTRO"
            exit 1
            ;;
    esac

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
    
    # ==========================================
    # Systems Engineering: Unix Traps as Clean Destructors
    # The 'trap' command is a shell built-in that intercepts POSIX signals and script exit conditions.
    # By registering a cleanup command on the pseudo-signal 'EXIT', we define a guaranteed destructor.
    # Regardless of whether the script terminates successfully, returns early, or hits an unexpected error (like
    # an installation failure or SIGINT/Ctrl+C interrupt), the shell will always execute 'rm -rf "$TEMP_DIR"'.
    # This prevents directory leakage, protects the host's temp filesystem from bloating, and ensures no sensitive
    # plain-text cloud-init variables or SSH keys are left lying around in the host's temporary storage.
    # ==========================================
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
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
