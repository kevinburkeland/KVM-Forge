#!/bin/bash

# Default version settings for Debian
DISTRO_DEFAULT_VERSION="12"
DISTRO_VERSION_HINT="e.g. 11, 12, 13"

# Returns the primary network interface name for Debian
get_interface_name() {
    echo "enp1s0"
}

# Maps version number to Debian codename
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

# Downloads and verifies the Debian cloud image
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
    if [ ! -f "$LIBVIRT_IMG_PATH" ]; then
        log_info "Copying base image to libvirt images directory..."
        sudo cp "$IMG_NAME" "$LIBVIRT_IMG_PATH"
        sudo chmod 640 "$LIBVIRT_IMG_PATH"
    fi
}
