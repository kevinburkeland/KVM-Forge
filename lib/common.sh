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
# The regular expression ^FORGE_[A-Z0-9_]+=\"[^\`\$]*\"$ actively validates variables by:
# 1. Requiring the variable to start with the 'FORGE_' namespace and contain only alphanumeric characters and underscores.
# 2. Enforcing that the value is strictly wrapped in double quotes.
# 3. Utilizing negative character matching ([^\`\$]*) to reject backticks (`) and dollar signs ($).
#    By blocking these characters, we prevent shell command substitution and variable expansion, neutralizing
#    injection vulnerabilities where malicious shell payloads could execute upon sourcing the config file.
# ==========================================
validate_forge_env_file() {
    local file="$1"
    local line=""

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ ^FORGE_[A-Z0-9_]+=\"[^\`\$]*\"$ ]]; then
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
    
    # Loop through each provided command and check if it's available in the system PATH
    for cmd in "${cmds[@]}"; do
        if [ "$cmd" = "libvirt-daemon" ]; then
            if systemctl status libvirtd &> /dev/null || command -v kvm-ok &> /dev/null; then
                continue
            else
                MISSING_CMDS="$MISSING_CMDS $cmd"
                continue
            fi
        fi
        
        local check_cmd="$cmd"
        if ! command -v "$check_cmd" &> /dev/null; then
            MISSING_CMDS="$MISSING_CMDS $cmd"
        fi
    done

    # If we found missing dependencies, prompt the user for permission to install them
    if [ -n "$MISSING_CMDS" ]; then
        log_err "The following required commands are missing:$MISSING_CMDS"
        read -p "Would you like to attempt to install them now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            
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
                        nmap) sudo apt-get install -y nmap ;;
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
                        nmap) sudo dnf install -y nmap ;;
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
                if ! command -v "$cmd" &> /dev/null; then
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
