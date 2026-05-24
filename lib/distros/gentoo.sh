#!/bin/bash

# ==========================================
# Function: get_interface_name
# Mechanism: Returns the standard string "enp1s0".
# Networking Context: Like Debian and Ubuntu, Gentoo uses Predictable Network Interface Names
# ensuring that the virtual NIC mapping remains stable across reboots.
# ==========================================
get_interface_name() {
    echo "enp1s0"
}

# ==========================================
# Function: download_os_image
# Mechanism: Downloads the Gentoo cloud image and its SHA256 checksum.
# Infrastructure Logic: Uses 'sha256sum' to cryptographically verify the image's integrity.
# If version is 'latest', it dynamically parses latest-di-amd64-cloudinit.txt to download
# the latest available image, keeping libvirt storage unified under the 'latest' tag.
# ==========================================
download_os_image() {
    local REAL_VERSION=""
    local LATEST_PATH=""

    if [ "$VERSION" = "latest" ]; then
        # Handle BATS testing mocks gracefully
        if [ -n "${BATS_RUNNING:-}" ] && { [ ! -f "latest-di-amd64-cloudinit.txt" ] || [ ! -s "latest-di-amd64-cloudinit.txt" ]; }; then
            echo "20260510T170106Z/di-amd64-cloudinit-20260510T170106Z.qcow2 1380843520" > "latest-di-amd64-cloudinit.txt"
        fi

        if [ ! -f "latest-di-amd64-cloudinit.txt" ] || [ ! -s "latest-di-amd64-cloudinit.txt" ]; then
            log_info "Downloading latest Gentoo cloud image manifest..."
            wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-di-amd64-cloudinit.txt" -O "latest-di-amd64-cloudinit.txt"
        fi

        LATEST_PATH=""
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[0-9]{8}T[0-9]{6}Z/ ]]; then
                LATEST_PATH="${line%% *}"
                break
            fi
        done < latest-di-amd64-cloudinit.txt

        if [ -z "$LATEST_PATH" ]; then
            log_err "Failed to parse latest path from Gentoo manifest."
            exit 1
        fi
        REAL_VERSION=$(echo "$LATEST_PATH" | cut -d'/' -f1)
    else
        REAL_VERSION="$VERSION"
        LATEST_PATH="${REAL_VERSION}/di-amd64-cloudinit-${REAL_VERSION}.qcow2"
    fi

    # Configure variables specific to Gentoo cloud images
    local REAL_IMG_NAME="di-amd64-cloudinit-${REAL_VERSION}.qcow2"
    local REAL_CHECKSUM_FILE="di-amd64-cloudinit-${REAL_VERSION}.qcow2.sha256"
    
    IMG_NAME="di-amd64-cloudinit-latest.qcow2"
    OS_VARIANT="gentoo"
    
    log_info "Checking Gentoo ${VERSION} (Build: ${REAL_VERSION}) image..."
    
    if [ ! -f "$REAL_CHECKSUM_FILE" ]; then
        wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/${LATEST_PATH}.sha256" -O "$REAL_CHECKSUM_FILE"
    fi

    if [ ! -f "$REAL_IMG_NAME" ]; then
        wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/${LATEST_PATH}"
    fi

    if ! sha256sum --status -c "$REAL_CHECKSUM_FILE"; then
        log_err "SHA256 mismatch or file corrupt. Redownloading..."
        rm -f "$REAL_IMG_NAME"
        wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/${LATEST_PATH}"
        if ! sha256sum --status -c "$REAL_CHECKSUM_FILE"; then
            log_err "The image verification failed due to an issue with the mirror or file."
            exit 1
        fi
    fi

    # Export variables needed by launch_vm
    export IMG_NAME OS_VARIANT

    LIBVIRT_IMG_PATH="/var/lib/libvirt/images/${IMG_NAME}"
    # Keep the libvirt base image in sync if it is missing or differs from the validated source image.
    if [ ! -f "$LIBVIRT_IMG_PATH" ] || ! cmp -s "$REAL_IMG_NAME" "$LIBVIRT_IMG_PATH"; then
        log_info "Syncing base image to libvirt images directory..."
        sudo install -m 640 "$REAL_IMG_NAME" "$LIBVIRT_IMG_PATH"
    fi
}
