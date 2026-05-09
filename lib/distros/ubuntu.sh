#!/bin/bash

# Default version settings for Ubuntu
DISTRO_DEFAULT_VERSION="24.04"
DISTRO_VERSION_HINT="e.g. 22.04, 24.04"

# Returns the primary network interface name for Ubuntu
get_interface_name() {
    echo "enp1s0"
}

# Downloads and verifies the Ubuntu cloud image
download_os_image() {
    # Configure variables specific to Ubuntu cloud images
    IMG_NAME="ubuntu-${VERSION}-server-cloudimg-amd64.img"
    OS_VARIANT="ubuntu${VERSION}"
    CHECKSUM_FILE="MD5SUMS"
    
    log_info "Checking Ubuntu ${VERSION} image..."
    # Download the official MD5SUMS file for validation
    wget -q "https://cloud-images.ubuntu.com/releases/${VERSION}/release/MD5SUMS" -O $CHECKSUM_FILE
    
    # If we don't have the image file locally, download it
    if [ ! -f "$IMG_NAME" ]; then
        wget -q "https://cloud-images.ubuntu.com/releases/${VERSION}/release/$IMG_NAME"
    fi

    # Validate the downloaded image against the MD5SUMS file.
    if ! grep "$IMG_NAME" $CHECKSUM_FILE | md5sum --status -c -; then
        log_err "MD5 mismatch or file corrupt. Redownloading..."
        rm -f "$IMG_NAME"
        wget -q "https://cloud-images.ubuntu.com/releases/${VERSION}/release/$IMG_NAME"
        
        # If it fails a second time, abort to prevent bad deployments.
        if ! grep "$IMG_NAME" $CHECKSUM_FILE | md5sum --status -c -; then
            log_err "Something is fishy with the mirror, MD5 still mismatches after redownload."
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
