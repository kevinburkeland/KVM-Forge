#!/bin/bash

# ==========================================
# Function: get_interface_name
# Mechanism: Returns the standard string "enp1s0".
# Networking Context: Modern Fedora Cloud images use Predictable Network Interface Names
# (enp1s0) based on hardware topology, rather than legacy eth0, to ensure NIC mapping
# stability across reboots.
# ==========================================
get_interface_name() {
    echo "enp1s0"
}

# ==========================================
# Function: download_os_image
# Mechanism: Configures variables for Fedora cloud images, resolves the latest
# build number dynamically using MirrorManager, and delegates to the centralized helper.
# ==========================================
download_os_image() {
    local RELEASE_NUMBER=""

    # 1. Check if we're running inside the BATS testing suite or completely offline
    if [ -n "${BATS_RUNNING:-}" ]; then
        RELEASE_NUMBER="1.7"
    else
        # 2. Attempt dynamic MirrorManager version resolution
        local MIRROR_LIST_URL="https://mirrors.fedoraproject.org/mirrorlist?path=pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/"
        log_info "Resolving closest Fedora mirror for version ${VERSION}..."
        
        local MIRROR_URL=""
        if command -v curl &> /dev/null; then
            MIRROR_URL=$(curl -s "$MIRROR_LIST_URL" | grep -v '^#' | grep -E '^https?://' | head -n 1)
        elif command -v wget &> /dev/null; then
            MIRROR_URL=$(wget -qO- "$MIRROR_LIST_URL" | grep -v '^#' | grep -E '^https?://' | head -n 1)
        fi

        if [ -n "$MIRROR_URL" ]; then
            log_info "Fetching Fedora directory index from mirror: $MIRROR_URL"
            local HTML_INDEX=""
            if command -v curl &> /dev/null; then
                HTML_INDEX=$(curl -s "$MIRROR_URL")
            elif command -v wget &> /dev/null; then
                HTML_INDEX=$(wget -qO- "$MIRROR_URL")
            fi
            
            if [ -n "$HTML_INDEX" ]; then
                RELEASE_NUMBER=$(echo "$HTML_INDEX" | grep -oE "Fedora-Cloud-Base-Generic-${VERSION}-[0-9.]+\.x86_64\.qcow2" | head -n 1 | sed -E "s/Fedora-Cloud-Base-Generic-${VERSION}-([0-9.]+)\.x86_64\.qcow2/\1/")
                if [ -n "$RELEASE_NUMBER" ]; then
                    log_info "Successfully resolved Fedora build number dynamically: $RELEASE_NUMBER"
                fi
            fi
        fi
    fi

    # 3. Local fallback database if resolution failed or wasn't run
    if [ -z "$RELEASE_NUMBER" ]; then
        case "$VERSION" in
            "44") RELEASE_NUMBER="1.7" ;;
            "43") RELEASE_NUMBER="1.6" ;;
            *)
                log_err "Fedora version $VERSION not found in local fallback database. Attempting default '1.7'."
                RELEASE_NUMBER="1.7"
                ;;
        esac
        log_info "Using fallback build number: $RELEASE_NUMBER"
    fi

    local target_img_name="Fedora-Cloud-Base-Generic-${VERSION}-latest.x86_64.qcow2"
    local os_variant="fedora${VERSION}"
    local checksum_file="Fedora-Cloud-${VERSION}-${RELEASE_NUMBER}-x86_64-CHECKSUM"
    
    local image_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${VERSION}-${RELEASE_NUMBER}.x86_64.qcow2"
    local checksum_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${VERSION}/Cloud/x86_64/images/Fedora-Cloud-${VERSION}-${RELEASE_NUMBER}-x86_64-CHECKSUM"
    
    verify_and_sync_image "$image_url" "$checksum_url" "$checksum_file" "sha256" "$target_img_name" "$os_variant"
}
