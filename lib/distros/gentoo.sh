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
# Mechanism: Configures variables for Gentoo cloud images, parses manifests if version is 'latest',
# and delegates to the centralized helper.
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
    local real_img_name="di-amd64-cloudinit-${REAL_VERSION}.qcow2"
    local real_checksum_file="di-amd64-cloudinit-${REAL_VERSION}.qcow2.sha256"
    
    local image_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/${LATEST_PATH}"
    local checksum_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/${LATEST_PATH}.sha256"
    
    # Export REAL_VERSION so verify_and_sync_image can display it in its dynamic log check
    export REAL_VERSION

    verify_and_sync_image "$image_url" "$checksum_url" "$real_checksum_file" "sha256" "di-amd64-cloudinit-latest.qcow2" "gentoo"
}
