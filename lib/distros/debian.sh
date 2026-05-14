#!/bin/bash


# ==========================================
# Function: get_interface_name
# Mechanism: Returns the standard string "enp1s0".
# Networking Context: Like Ubuntu, Debian uses Predictable Network Interface Names
# ensuring that the virtual NIC mapping remains stable across reboots.
# ==========================================
get_interface_name() {
    echo "enp1s0"
}

# ==========================================
# Function: get_debian_codename
# Mechanism: Uses yq to fetch the codename from the central manifest.yaml.
# Infrastructure Logic: Debian repositories organize releases by codenames (e.g., bullseye, bookworm)
# rather than numbers. This translation is required to build the correct download URL.
# ==========================================
get_debian_codename() {
    local version="$1"
    local manifest_file="${FORGE_ROOT}/config/manifest.yaml"
    
    if [ ! -f "$manifest_file" ]; then
        log_err "Manifest file not found at $manifest_file"
        exit 1
    fi
    
    local codename
    codename=$(cat "$manifest_file" | yq ".distros.debian.codenames.\"${version}\"")
    
    if [ "$codename" == "null" ] || [ -z "$codename" ]; then
        log_err "Unsupported Debian version or missing codename in manifest: $version"
        exit 1
    fi
    
    echo "$codename"
}

# ==========================================
# Function: download_os_image
# Mechanism: Downloads the Debian qcow2 cloud image and its SHA512 checksum.
# Infrastructure Logic: Uses 'sha512sum' to cryptographically verify the image's integrity.
# SHA512 is stronger than MD5, making it practically impossible for an attacker to spoof
# the image. Once verified, the image is staged in the libvirt directory for VM cloning.
# ==========================================
download_os_image() {
    CODENAME=$(get_debian_codename "$VERSION")
    
    # Configure variables specific to Debian cloud images
    IMG_NAME="debian-${VERSION}-generic-amd64.qcow2"
    OS_VARIANT="debian${VERSION}"
    CHECKSUM_FILE="SHA512SUMS"
    
    log_info "Checking Debian ${VERSION} (${CODENAME}) image..."
    wget -q "https://cloud.debian.org/images/cloud/${CODENAME}/latest/SHA512SUMS" -O $CHECKSUM_FILE
    
    if [ ! -f "$IMG_NAME" ]; then
        wget -q "https://cloud.debian.org/images/cloud/${CODENAME}/latest/$IMG_NAME"
    fi

    if ! grep "$IMG_NAME" $CHECKSUM_FILE | sha512sum --status -c -; then
        log_err "SHA512 mismatch or file corrupt. Redownloading..."
        rm -f "$IMG_NAME"
        wget -q "https://cloud.debian.org/images/cloud/${CODENAME}/latest/$IMG_NAME"
        if ! grep "$IMG_NAME" $CHECKSUM_FILE | sha512sum --status -c -; then
            log_err "The image verification failed due to an issue with the mirror or file."
            exit 1
        fi
    fi

    # Export variables needed by launch_vm
    export IMG_NAME OS_VARIANT

    LIBVIRT_IMG_PATH="/var/lib/libvirt/images/${IMG_NAME}"
    # Keep the libvirt base image in sync if it is missing or differs from the validated source image.
    if [ ! -f "$LIBVIRT_IMG_PATH" ] || ! cmp -s "$IMG_NAME" "$LIBVIRT_IMG_PATH"; then
        log_info "Syncing base image to libvirt images directory..."
        sudo install -m 640 "$IMG_NAME" "$LIBVIRT_IMG_PATH"
    fi
}
