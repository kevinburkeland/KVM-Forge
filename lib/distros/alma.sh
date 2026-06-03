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
# Mechanism: Configures variables for AlmaLinux cloud images and delegates to the centralized helper.
# ==========================================
download_os_image() {
    local target_img_name="AlmaLinux-${VERSION}-GenericCloud-latest.x86_64.qcow2"
    local os_variant="almalinux${VERSION}"
    local checksum_file="alma-${VERSION}-CHECKSUM"
    
    local image_url="https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/${target_img_name}"
    local checksum_url="https://repo.almalinux.org/almalinux/${VERSION}/cloud/x86_64/images/CHECKSUM"
    
    verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "sha256" "$target_img_name" "$os_variant"
}

