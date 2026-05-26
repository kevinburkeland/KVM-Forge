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
# Mechanism: Configures variables for Debian cloud images and delegates to the centralized helper.
# ==========================================
download_os_image() {
    CODENAME=$(get_debian_codename "$VERSION")
    
    local target_img_name="debian-${VERSION}-generic-amd64.qcow2"
    local os_variant="debian${VERSION}"
    local checksum_file="SHA512SUMS"
    
    local image_url="https://cloud.debian.org/images/cloud/${CODENAME}/latest/${target_img_name}"
    local checksum_url="https://cloud.debian.org/images/cloud/${CODENAME}/latest/SHA512SUMS"
    
    verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "sha512" "$target_img_name" "$os_variant"
}

