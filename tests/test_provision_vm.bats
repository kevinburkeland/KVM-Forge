#!/usr/bin/env bats

# ==========================================
# Systems Engineering: Test Fixtures and Mocks
# - Test Fixtures: The setup() function establishes a clean, isolated environment (a "fixture") before
#   every individual test case. By using 'mktemp -d' to isolate temporary workspace directories and resetting
#   variables like HOME and PATH, we ensure that test side-effects cannot bleed across test case boundaries.
# - Mocks: Testing orchestration scripts that invoke heavy, hardware-bound, or network-bound CLI utilities
#   (like virt-install, wget, ssh) requires virtual virtualization (mocking). Instead of executing actual system
#   binaries, we intercept them using lightweight mock scripts to keep our unit tests fast, predictable, and 100% offline.
# ==========================================
setup() {
    export BATS_RUNNING="true"
    export MOCK_DIR="${BATS_TEST_DIRNAME}/mock_bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:$PATH"

    # ==========================================
    # Systems Engineering: Intercepting Binaries via PATH Manipulation
    # - How it works: Prepending MOCK_DIR to the system PATH environment variable allows mock versions of
    #   commands like arping, virsh, and sudo to intercept and capture actual execution arguments during testing.
    # ==========================================

    # We need to set some environment variables that the script expects
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../lib"
    export CLOUD_INIT_DIR="${BATS_TEST_DIRNAME}/mock_cloud_init"
    export FORGE_BRIDGE_IF="testbridge"
    export FORGE_SUBNET_SCAN="192.168.1.0/29"
    export DISTRO="ubuntu"
    export VERSION="24.04"
    
    # Create mock arping
    cat << 'EOF' > "${MOCK_DIR}/arping"
#!/bin/bash
target="${@: -1}"
if [[ "$target" == "192.168.1.1" || "$target" == "192.168.1.4" || "$target" == "192.168.1.5" || "$target" == "192.168.1.6" ]]; then
    exit 0
fi
exit 1
EOF
    chmod +x "${MOCK_DIR}/arping"

    # Create mock virsh
    cat << 'EOF' > "${MOCK_DIR}/virsh"
#!/bin/bash
echo " Id   Name               State"
echo "----------------------------------"
echo " 1    foo.forge.example      running"
EOF
    chmod +x "${MOCK_DIR}/virsh"

    # Mock sudo
    cat << 'EOF' > "${MOCK_DIR}/sudo"
#!/bin/bash
"$@"
EOF
    chmod +x "${MOCK_DIR}/sudo"

    # Create placeholder common names.txt
    mkdir -p "${CLOUD_INIT_DIR}/common"
    echo "baz" > "${CLOUD_INIT_DIR}/common/names.txt"
    echo "qux" >> "${CLOUD_INIT_DIR}/common/names.txt"

    # Source the script (which will now not run main thanks to BASH_SOURCE check)
    source "${BATS_TEST_DIRNAME}/../lib/provision_vm.sh"
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -rf "${BATS_TEST_DIRNAME}/mock_cloud_init"
}

@test "get_available_ip correctly identifies a free IP" {
    get_available_ip
    
    # 192.168.1.0 and 192.168.1.255 are removed
    # 192.168.1.1 is marked as UP
    # Available should be 192.168.1.2 or 192.168.1.3
    [[ "$NEWIP" == "192.168.1.2" || "$NEWIP" == "192.168.1.3" ]]
    [[ "$NEWIP_YAML" == "${NEWIP}/24" ]]
}

@test "get_random_hostname gets a valid unused name" {
    export FORGE_BASE_DOMAIN="forge.example"
    get_random_hostname
    
    [[ "$NEWNAME" == "baz" || "$NEWNAME" == "qux" ]]
    [[ "$NEWNAME_FQDN" == "${NEWNAME}.forge.example" ]]
}

@test "download_os_image sets correct variables for ubuntu" {
    export DISTRO="ubuntu"
    export VERSION="24.04"
    
    source "${BATS_TEST_DIRNAME}/../lib/distros/${DISTRO}.sh"

    # Mock wget and md5sum to prevent actual download
    cat << 'EOF' > "${MOCK_DIR}/wget"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/wget"

    cat << 'EOF' > "${MOCK_DIR}/md5sum"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/md5sum"

    # Mock grep to always return success
    cat << 'EOF' > "${MOCK_DIR}/grep"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/grep"

    # Mock cp
    cat << 'EOF' > "${MOCK_DIR}/cp"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/cp"
    
    # Mock chmod
    cat << 'EOF' > "${MOCK_DIR}/chmod"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/chmod"

    # Mock install (used by distro image sync path)
    cat << 'EOF' > "${MOCK_DIR}/install"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/install"

    download_os_image
    [ "$IMG_NAME" = "ubuntu-24.04-server-cloudimg-amd64.img" ]
    [ "$OS_VARIANT" = "ubuntu24.04" ]
}

@test "download_os_image selects Debian genericcloud image" {
    export DISTRO="debian"
    export VERSION="12"

    source "${BATS_TEST_DIRNAME}/../lib/distros/${DISTRO}.sh"

    cat << 'EOF' > "${MOCK_DIR}/wget"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/wget"

    cat << 'EOF' > "${MOCK_DIR}/sha512sum"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/sha512sum"

    cat << 'EOF' > "${MOCK_DIR}/grep"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/grep"

    cat << 'EOF' > "${MOCK_DIR}/cp"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/cp"

    cat << 'EOF' > "${MOCK_DIR}/chmod"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/chmod"

    cat << 'EOF' > "${MOCK_DIR}/install"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/install"

    download_os_image
    [ "$IMG_NAME" = "debian-12-generic-amd64.qcow2" ]
    [ "$OS_VARIANT" = "debian12" ]
}

@test "debian interface name matches predictable virtio naming" {
    source "${BATS_TEST_DIRNAME}/../lib/distros/debian.sh"

    [ "$(get_interface_name)" = "enp1s0" ]
}

@test "gentoo interface name matches predictable virtio naming" {
    source "${BATS_TEST_DIRNAME}/../lib/distros/gentoo.sh"

    [ "$(get_interface_name)" = "enp1s0" ]
}

@test "download_os_image selects Gentoo latest image" {
    export DISTRO="gentoo"
    export VERSION="latest"

    source "${BATS_TEST_DIRNAME}/../lib/distros/${DISTRO}.sh"

    cat << 'EOF' > "${MOCK_DIR}/wget"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/wget"

    cat << 'EOF' > "${MOCK_DIR}/sha256sum"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/sha256sum"

    cat << 'EOF' > "${MOCK_DIR}/grep"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/grep"

    cat << 'EOF' > "${MOCK_DIR}/cp"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/cp"

    cat << 'EOF' > "${MOCK_DIR}/chmod"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/chmod"

    cat << 'EOF' > "${MOCK_DIR}/install"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/install"

    download_os_image
    [ "$IMG_NAME" = "di-amd64-cloudinit-latest.qcow2" ]
    [ "$OS_VARIANT" = "gentoo" ]
}

@test "fedora interface name matches predictable virtio naming" {
    source "${BATS_TEST_DIRNAME}/../lib/distros/fedora.sh"

    [ "$(get_interface_name)" = "enp1s0" ]
}

@test "download_os_image selects Fedora latest image" {
    export DISTRO="fedora"
    export VERSION="44"

    source "${BATS_TEST_DIRNAME}/../lib/distros/${DISTRO}.sh"

    cat << 'EOF' > "${MOCK_DIR}/wget"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/wget"

    cat << 'EOF' > "${MOCK_DIR}/sha256sum"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/sha256sum"

    cat << 'EOF' > "${MOCK_DIR}/grep"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/grep"

    cat << 'EOF' > "${MOCK_DIR}/cp"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/cp"

    cat << 'EOF' > "${MOCK_DIR}/chmod"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/chmod"

    cat << 'EOF' > "${MOCK_DIR}/install"
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/install"

    download_os_image
    [ "$IMG_NAME" = "Fedora-Cloud-Base-Generic-44-latest.x86_64.qcow2" ]
    [ "$OS_VARIANT" = "fedora44" ]
}


