#!/bin/bash


# ==========================================
# Function: get_interface_name
# Mechanism: Returns the standard string "eth0".
# Networking Context: AlmaLinux cloud images default to the legacy 'eth0' naming convention.
# Because these VMs typically only have a single virtual NIC, the legacy naming is safe
# and simplifies cloud-init network configuration.
# ==========================================
get_interface_name() {
    echo "eth0"
}

# ==========================================
# Function: download_os_image
# Mechanism: Downloads the AlmaLinux GenericCloud image and its SHA256 checksum.
# Infrastructure Logic: Verifies the integrity of the download using 'sha256sum'.
# This prevents failed VM deployments caused by partially downloaded files. After verification,
# it synchronizes the image to the local KVM storage pool (/var/lib/libvirt/images).
# ==========================================
download_os_image() {
    # Configure variables specific to AlmaLinux cloud images
    IMG_NAME="AlmaLinux-${VERSION}-GenericCloud-latest.x86_64.qcow2"
    OS_VARIANT="almalinux${VERSION}"
    CHECKSUM_FILE="CHECKSUM"
    
    log_info "Checking AlmaLinux ${VERSION} image..."
    wget -q "https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/CHECKSUM" -O $CHECKSUM_FILE
    
    if [ ! -f "$IMG_NAME" ]; then
        wget -q "https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/$IMG_NAME"
    fi

    # Alma uses SHA256 hashes instead of MD5 for better security
    if ! grep "$IMG_NAME" $CHECKSUM_FILE | sha256sum --status -c -; then
        log_err "SHA256 mismatch or file corrupt. Redownloading..."
        rm -f "$IMG_NAME"
        wget -q "https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/$IMG_NAME"
        if ! grep "$IMG_NAME" $CHECKSUM_FILE | sha256sum --status -c -; then
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
