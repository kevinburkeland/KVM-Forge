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
# Mechanism: Configures variables for Ubuntu cloud images and delegates to the centralized helper.
# ==========================================
download_os_image() {
    local target_img_name="ubuntu-${VERSION}-server-cloudimg-amd64.img"
    local os_variant="ubuntu${VERSION}"
    local checksum_file="ubuntu-${VERSION}-MD5SUMS"
    
    local image_url="https://cloud-images.ubuntu.com/releases/${VERSION}/release/${target_img_name}"
    local checksum_url="https://cloud-images.ubuntu.com/releases/${VERSION}/release/MD5SUMS"
    
    verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "md5" "$target_img_name" "$os_variant"
}

