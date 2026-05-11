#!/bin/bash

# Default version settings for Debian
DISTRO_DEFAULT_VERSION="12"
DISTRO_VERSION_HINT="e.g. 11, 12, 13"

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
# Mechanism: Uses a case statement to map the integer version to the string codename.
# Infrastructure Logic: Debian repositories organize releases by codenames (e.g., bullseye, bookworm)
# rather than numbers. This translation is required to build the correct download URL.
# ==========================================
get_debian_codename() {
    case "$1" in
        11) echo "bullseye" ;;
        12) echo "bookworm" ;;
        13) echo "trixie" ;;
        *)
            log_err "Unsupported Debian version: $1"
            exit 1
            ;;
    esac
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
            log_err "Something is fishy with the mirror, SHA512 still mismatches after redownload."
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
