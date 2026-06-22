#!/bin/bash

# ==========================================
# Systems Engineering: Script Robustness and Error Handling
# Robust scripts in modern environments use shell configuration flags at the top of executable entrypoints:
# - 'set -e' (errexit): Forces the script to terminate immediately if any command returns a non-zero exit status,
#   preventing cascading failures where a failed prerequisite leads to undefined system states.
# - 'set -u' (nounset): Treats references to unset/unassigned variables as errors, immediately halting execution
#   to prevent bugs like silent typographical errors or unexpected execution branches.
# - 'set -o pipefail': Ensures that if any command within a pipeline fails, the entire pipeline returns that non-zero
#   exit code, rather than masking failures behind the status of the final command in the pipe.
# ==========================================

# ==========================================
# Systems Engineering: Command Injection Prevention
# Security validation: When reading external configuration or environment files, it is vital to perform
# active input sanitization before sourcing the file into the running shell.
# The regular expression ^FORGE_[A-Z0-9_]+=\"[^\`\$\"\\]*\"$ actively validates variables by:
# 1. Requiring the variable to start with the 'FORGE_' namespace and contain only alphanumeric characters and underscores.
# 2. Enforcing that the value is strictly wrapped in double quotes.
# 3. Utilizing negative character matching ([^\`\$\"\\]*) to reject backticks (`), dollar signs ($),
#    double quotes ("), and backslashes (\). By blocking these characters, we prevent quote breakouts,
#    escapes, command substitutions, and variable expansions, neutralizing injection vulnerabilities
#    where malicious shell payloads could execute upon sourcing the config file.
# ==========================================
validate_forge_env_file() {
    local file="$1"
    local line=""

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ ^FORGE_[A-Z0-9_]+=\"[^\`\$\"\\]*\"$ ]]; then
            return 1
        fi
    done < "$file"
}

# Find the directory of this common script and use it to locate the project root
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_ROOT="$(dirname "$COMMON_DIR")"

# If the user has completed the setup process and we are not running unit tests, load their environment variables
if [ -z "${BATS_RUNNING:-}" ] && [ -f "$FORGE_ROOT/config/forge.env" ]; then
    if ! validate_forge_env_file "$FORGE_ROOT/config/forge.env"; then
        echo "[ERROR] Invalid content in $FORGE_ROOT/config/forge.env. Refusing to source it." >&2
        exit 1
    fi
    source "$FORGE_ROOT/config/forge.env"
fi

# ==========================================
# Logging Utilities
# ==========================================

# Prints a formatted informational message in blue text
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

# Prints a formatted error message in red text, sending output to standard error (>&2)
log_err() {
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
}

# ==========================================
# Dependency Management
# ==========================================

# ==========================================
# Function: check_and_install_dependencies
# Mechanism: Iterate through an array of required commands and check if they exist in the PATH.
# Infrastructure Logic: If any are missing, it attempts to dynamically resolve whether the host
# uses APT (Debian/Ubuntu) or DNF (RHEL/Alma) and automatically installs them. This makes the
# script portable across different Linux host environments without manual setup.
# ==========================================
check_and_install_dependencies() {
    local cmds=("$@")
    local MISSING_CMDS=""

    # Returns success when a dependency label is satisfied on this host.
    # For package labels like libvirt-daemon, this checks real runtime indicators
    # rather than assuming the label is an executable on PATH.
    is_dependency_satisfied() {
        local dep="$1"

        if [ "$dep" = "libvirt-daemon" ]; then
            if command -v libvirtd &> /dev/null || command -v virtqemud &> /dev/null || [ -f /usr/sbin/libvirtd ] || [ -f /usr/sbin/virtqemud ] || systemctl status libvirtd &> /dev/null || systemctl status virtqemud.service &> /dev/null || command -v kvm-ok &> /dev/null; then
                return 0
            fi
            return 1
        fi

        command -v "$dep" &> /dev/null
    }
    
    # Loop through each provided command and check if it's available in the system PATH
    for cmd in "${cmds[@]}"; do
        if ! is_dependency_satisfied "$cmd"; then
            MISSING_CMDS="$MISSING_CMDS $cmd"
        fi
    done

    # If we found missing dependencies, prompt the user for permission to install them
    if [ -n "$MISSING_CMDS" ]; then
        log_err "The following required commands are missing:$MISSING_CMDS"
        
        local auto_install=false
        if [ "${FORGE_ASSUME_YES:-}" = "true" ] || [ "${FORGE_NON_INTERACTIVE:-}" = "true" ]; then
            auto_install=true
        fi
        
        if [ "$auto_install" = "true" ]; then
            REPLY="y"
        elif ! [ -t 0 ] && [ -z "${BATS_RUNNING:-}" ]; then
            log_err "Non-interactive environment detected. Cannot prompt for installation. Please install missing commands manually."
            exit 1
        else
            read -p "Would you like to attempt to install them now? (y/n) " -n 1 -r
            echo
        fi
        
        if [[ "${REPLY:-n}" =~ ^[Yy]$ ]]; then
            
            # Check if the system uses APT (Debian/Ubuntu)
            if command -v apt-get &> /dev/null; then
                sudo apt-get update
                for cmd in $MISSING_CMDS; do
                    case $cmd in
                        gum)
                            # 'gum' install with apt
                            sudo apt-get update && sudo apt-get install -y gum
                            ;;
                        yq) sudo snap install yq || sudo apt-get install -y yq ;;
                        virt-install) sudo apt-get install -y virtinst ;;
                        arping) sudo apt-get install -y arping ;;
                        wget) sudo apt-get install -y wget ;;
			            libvirt-daemon) sudo apt-get install -y libvirt-daemon ;;
                        # Coreutils provides multiple basic binaries like shuf and md5sum
                        shuf|md5sum|sha256sum) sudo apt-get install -y coreutils ;;
                        *) log_err "Don't know how to install $cmd via apt."; exit 1 ;;
                    esac
                done
            
            # Check if the system uses DNF (AlmaLinux/Fedora/CentOS)
            elif command -v dnf &> /dev/null; then
                for cmd in $MISSING_CMDS; do
                    case $cmd in
                        gum)
                            echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
                            sudo dnf install -y gum
                            ;;
                        yq) sudo dnf install -y yq ;;
                        virt-install) sudo dnf install -y virt-install ;;
                        arping) sudo dnf install -y arping ;;
                        wget) sudo dnf install -y wget ;;
			            libvirt-daemon) sudo dnf install -y libvirt-daemon ;;
                        shuf|md5sum|sha256sum) sudo dnf install -y coreutils ;;
                        *) log_err "Don't know how to install $cmd via dnf."; exit 1 ;;
                    esac
                done
            else
                log_err "Unsupported package manager. Please install the missing dependencies manually."
                exit 1
            fi
            
            # Double check that the installation succeeded
            for cmd in $MISSING_CMDS; do
                if ! is_dependency_satisfied "$cmd"; then
                    log_err "Failed to install $cmd. Please install it manually."
                    exit 1
                fi
            done
            log_info "Dependencies installed successfully!"
        else
            log_err "Please install the missing dependencies and run the script again."
            exit 1
        fi
    fi
}

# ==========================================
# VM Argument Parsing
# ==========================================

# ==========================================
# Function: parse_vm_args
# Mechanism: Use a 'while' loop and 'case' statements to parse command-line flags (-d, -p, etc.).
# Systems Engineering: Positional Parameters & Unix Shift Built-in
# In Unix shell scripting, arguments passed to the script are stored in the positional parameter array
# ($1, $2, ..., $N), with $# representing the size of the array. The 'shift' shell built-in pops the first
# parameter ($1) out of the list and shifts all remaining elements to the left (so the original $2 becomes the new $1).
# In our parse loop:
# - When a flag requires a value (e.g., -d "gentoo"), we do a double shift: first, we shift within the case option ('shift')
#   to consume the flag's argument value, and second, we shift at the end of the loop to clear the flag identifier itself.
# This pattern provides a memory-efficient, standard, and portable traversal of command-line arguments without
# requiring external parsers or complex indexing arithmetic.
# ==========================================
parse_vm_args() {
    # Set default variables for the Virtual Machine if no flags are provided
    DISTRO="ubuntu"
    VERSION=""
    PROFILE="base"
    VCPU=4
    MEMORY=8192
    DISK_SIZE=30

    # Loop through all provided arguments. 
    # "$#" represents the number of arguments left to process.
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -d|--distro) DISTRO="$2"; shift ;;
            -v|--version) VERSION="$2"; shift ;;
            -p|--profile) PROFILE="$2"; shift ;;
            -c|--cpus)
                # Use a regular expression to validate that the CPU input is a positive integer
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "CPUs (-c) must be a positive integer."
                    exit 1
                fi
                VCPU="$2"
                shift ;; # 'shift' moves the argument list forward by one, consuming the value
            -m|--memory)
                # Validate that memory is a positive integer
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "Memory (-m) must be a positive integer."
                    exit 1
                fi
                MEMORY="$2"
                shift ;;
            -s|--disk-size)
                # Validate that disk size is a positive integer
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    log_err "Disk size (-s) must be a positive integer."
                    exit 1
                fi
                DISK_SIZE="$2"
                shift ;;
            -h|--help)
                # Display usage instructions
                local manifest_file="${FORGE_ROOT}/config/manifest.yaml"
                local available_distros="ubuntu, alma, debian"
                if [ -f "$manifest_file" ] && command -v yq >/dev/null; then
                    available_distros=$(cat "$manifest_file" | yq '.distros | keys | join(", ")')
                fi
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  -d, --distro      Distro to use ($available_distros, default: ubuntu)"
                echo "  -v, --version     Distro version (e.g. 24.04, 10, 12)"
                echo "  -p, --profile     Profile to use (default: base)"
                echo "  -c, --cpus        Number of vCPUs (default: 4)"
                echo "  -m, --memory      Memory in MB (default: 8192)"
                echo "  -s, --disk-size   Disk size in GB (default: 30)"
                exit 0
                ;;
            *) log_err "Unknown parameter passed: $1"; exit 1 ;;
        esac
        # Shift past the flag itself (e.g. past '-d')
        shift
    done

    MANIFEST_FILE="${FORGE_ROOT}/config/manifest.yaml"
    if [ ! -f "$MANIFEST_FILE" ]; then
        log_err "Manifest file not found at $MANIFEST_FILE"
        exit 1
    fi

    # Validate that the selected distro exists in the manifest
    if ! cat "$MANIFEST_FILE" | yq ".distros | has(\"$DISTRO\")" | grep -q "true"; then
        log_err "Unknown distro: $DISTRO"
        exit 1
    fi

    # Validate that the selected profile exists for this distro
    if ! cat "$MANIFEST_FILE" | yq ".distros.${DISTRO}.profiles | contains([\"$PROFILE\"])" | grep -q "true"; then
        log_err "Profile '$PROFILE' is not supported for distro '$DISTRO'. Supported: $(cat "$MANIFEST_FILE" | yq ".distros.${DISTRO}.profiles | join(\", \")")"
        exit 1
    fi

    # If the user didn't specify an OS version, use the predefined default from the manifest
    if [ -z "$VERSION" ]; then
        VERSION=$(cat "$MANIFEST_FILE" | yq ".distros.${DISTRO}.default_version")
    else
        # Optional: Validate the provided version
        if ! cat "$MANIFEST_FILE" | yq ".distros.${DISTRO}.supported_versions | contains([\"$VERSION\"])" | grep -q "true"; then
            log_info "Warning: Version $VERSION is not explicitly supported in the manifest for $DISTRO."
        fi
    fi

    # Export these variables so they are accessible to any script that calls this function
    export DISTRO VERSION PROFILE VCPU MEMORY DISK_SIZE
}

# ==========================================
# Function: resolve_supported_os_variant
# Mechanism: Queries the host's virt-install supported OS variants list and
# matches the requested OS_VARIANT. If the requested variant is not supported,
# it automatically falls back to the nearest lower version of the same distro,
# or a generic fallback, ensuring that the virt-install command doesn't crash on
# hosts with older libosinfo/virtinst packages.
# ==========================================
resolve_supported_os_variant() {
    local requested="$1"
    
    # If running inside unit tests, bypass physical check to preserve mock expectations
    if [ -n "${BATS_RUNNING:-}" ]; then
        echo "$requested"
        return 0
    fi
    
    # 1. If it's supported as-is, return it immediately
    if virt-install --osinfo "name=$requested" --print-xml &>/dev/null; then
        echo "$requested"
        return 0
    fi
    
    # 2. Try to parse into non-digit prefix and version number
    local prefix=""
    local requested_version=""
    if [[ "$requested" =~ ^([a-zA-Z_-]+)([0-9.]+)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        requested_version="${BASH_REMATCH[2]}"
    else
        prefix="$requested"
        requested_version=""
    fi
    
    # 3. If we don't have a version number, try to query matching prefixes or return a fallback
    if [ -z "$requested_version" ]; then
        # Try returning just the prefix if virt-install supports it
        if virt-install --osinfo "name=$prefix" --print-xml &>/dev/null; then
            echo "$prefix"
            return 0
        fi
        # Check if there is an '<prefix>-unknown' (e.g., fedora-unknown)
        if virt-install --osinfo "name=${prefix}-unknown" --print-xml &>/dev/null; then
            echo "${prefix}-unknown"
            return 0
        fi
        # Return generic default
        echo "generic"
        return 0
    fi
    
    # 4. Get all supported variants starting with prefix followed by a number
    local candidates
    mapfile -t candidates < <(virt-install --osinfo list | tr -d ' ' | tr ',' '\n' | grep -E "^${prefix}[0-9.]+$" | sort -V -r)
    
    # 5. Iterate through candidate versions (which are sorted descending)
    # and find the highest version <= requested_version
    local cand_version=""
    for cand in "${candidates[@]}"; do
        if [[ "$cand" =~ ^([a-zA-Z_-]+)([0-9.]+)$ ]]; then
            cand_version="${BASH_REMATCH[2]}"
            if printf '%s\n%s\n' "$cand_version" "$requested_version" | sort -V -C; then
                # cand_version <= requested_version!
                echo "$cand"
                return 0
            fi
        fi
    done
    
    # 6. Fallbacks if no candidate was <= requested_version
    # Try the lowest candidate version we found
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[-1]}"
        return 0
    fi
    
    # Try <prefix>-unknown
    if virt-install --osinfo "name=${prefix}-unknown" --print-xml &>/dev/null; then
        echo "${prefix}-unknown"
        return 0
    fi
    
    # Return generic default
    echo "generic"
}

# ==========================================================
# Function: verify_and_sync_image
# Mechanism: Downloads, cryptographically verifies, and synchronizes a cloud image.
# Arguments:
#   1. IMAGE_URL: The direct HTTP download URL for the cloud image.
#   2. CHECKSUM_URL: The direct HTTP download URL for the checksum list.
#   3. CHECKSUM_FILE: The local name of the checksum file (e.g. MD5SUMS, SHA256SUMS).
#   4. CHECKSUM_TYPE: The hashing algorithm to use (md5, sha256, or sha512).
#   5. TARGET_IMG_NAME: The final filename of the image in the local workspace.
#   6. OS_VARIANT: The OS type passed to virt-install.
# ==========================================
verify_and_sync_image() {
    local IMAGE_URL="$1"
    local CHECKSUM_URL="$2"
    local CHECKSUM_FILE="$3"
    local CHECKSUM_TYPE="$4"
    local TARGET_IMG_NAME="$5"
    local OS_VARIANT_ARG="$6"

    local local_file
    local_file=$(basename "$IMAGE_URL")

    local display_distro="$DISTRO"
    case "$DISTRO" in
        ubuntu) display_distro="Ubuntu" ;;
        debian) display_distro="Debian" ;;
        alma) display_distro="AlmaLinux" ;;
        gentoo) display_distro="Gentoo" ;;
    esac

    if [ "$DISTRO" = "debian" ] && [ -n "${CODENAME:-}" ]; then
        log_info "Checking ${display_distro} ${VERSION} (${CODENAME}) image..."
    elif [ "$DISTRO" = "gentoo" ] && [ -n "${REAL_VERSION:-}" ]; then
        log_info "Checking ${display_distro} ${VERSION} (Build: ${REAL_VERSION}) image..."
    else
        log_info "Checking ${display_distro} ${VERSION} image..."
    fi

    # Download the checksum file if missing
    if [ ! -f "$CHECKSUM_FILE" ]; then
        wget -q "$CHECKSUM_URL" -O "$CHECKSUM_FILE"
    fi

    # Download the cloud image if missing
    if [ ! -f "$local_file" ]; then
        wget -q "$IMAGE_URL"
    fi

    local checksum_cmd=""
    case "$CHECKSUM_TYPE" in
        md5) checksum_cmd="md5sum" ;;
        sha256) checksum_cmd="sha256sum" ;;
        sha512) checksum_cmd="sha512sum" ;;
        *) log_err "Unsupported checksum type: $CHECKSUM_TYPE"; exit 1 ;;
    esac

    local upper_type
    upper_type=$(echo "$CHECKSUM_TYPE" | tr '[:lower:]' '[:upper:]')

    # Hash verification helper
    check_hash() {
        if grep -q "$local_file" "$CHECKSUM_FILE" 2>/dev/null; then
            grep "$local_file" "$CHECKSUM_FILE" | "$checksum_cmd" --status -c -
        else
            "$checksum_cmd" --status -c "$CHECKSUM_FILE"
        fi
    }

    # Perform the hash validation
    if ! check_hash; then
        log_err "${upper_type} mismatch or file corrupt. Redownloading..."
        rm -f -- "$local_file"
        wget -q "$IMAGE_URL"
        
        # If it fails a second time, abort
        if ! check_hash; then
            log_err "The image verification failed due to an issue with the mirror or file."
            exit 1
        fi
    fi

    # Export variables needed by launch_vm
    export IMG_NAME="$TARGET_IMG_NAME"
    export OS_VARIANT="$(resolve_supported_os_variant "$OS_VARIANT_ARG")"

    local LIBVIRT_IMG_PATH="/var/lib/libvirt/images/${IMG_NAME}"
    # Keep the libvirt base image in sync if it is missing or differs from the validated source image
    if [ ! -f "$LIBVIRT_IMG_PATH" ] || ! cmp -s "$local_file" "$LIBVIRT_IMG_PATH"; then
        log_info "Syncing base image to libvirt images directory..."
        sudo install -m 640 -- "$local_file" "$LIBVIRT_IMG_PATH"
    fi
}

# ==========================================
# Function: calculate_subnet_base
# Mechanism: Computes the base network IP and mask prefix dynamically using pure Bash bitwise arithmetic.
# Arguments:
#   1. gateway: The gateway IP address (e.g. 192.168.122.129)
#   2. cidr: The CIDR mask suffix (e.g. 25)
# ==========================================
calculate_subnet_base() {
    local gateway="$1"
    local cidr="$2"
    local ip_int=0
    local mask_int=0
    local net_int=0
    local o1 o2 o3 o4
    
    IFS=. read -r o1 o2 o3 o4 <<< "$gateway"
    ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    mask_int=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    net_int=$(( ip_int & mask_int ))
    
    local n1=$(( (net_int >> 24) & 255 ))
    local n2=$(( (net_int >> 16) & 255 ))
    local n3=$(( (net_int >> 8) & 255 ))
    local n4=$(( net_int & 255 ))
    
    echo "${n1}.${n2}.${n3}.${n4}/${cidr}"
}

