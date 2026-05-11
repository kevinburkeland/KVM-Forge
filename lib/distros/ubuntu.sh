#!/bin/bash


# ==========================================
# Function: get_interface_name
# Mechanism: Returns the hardcoded string "enp1s0" for the calling script to use.
# Networking Context: Modern Ubuntu versions use Predictable Network Interface Names
# (like enp1s0) based on hardware topology, rather than the legacy eth0 which could
# randomly swap between physical ports on reboot.
# ==========================================
get_interface_name() {
    echo "enp1s0"
}

# ==========================================
# Function: download_os_image
# Mechanism: Downloads the Ubuntu cloud image and its cryptographic checksum.
# Infrastructure Logic: Validates the image using 'md5sum' against the official hashes.
# If the hash doesn't match, it deletes the corrupt file and redownloads it. This
# protects the lab against both corrupted downloads and supply-chain attacks. Once verified,
# it copies the image to the secure KVM image directory (/var/lib/libvirt/images).
# ==========================================
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
