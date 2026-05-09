#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    export MOCK_DIR="${BATS_TEST_DIRNAME}/mock_bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:$PATH"

    # We need to set some environment variables that the script expects
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../host"
    export CLOUD_INIT_DIR="${BATS_TEST_DIRNAME}/mock_cloud_init"
    export FORGE_BRIDGE_IF="testbridge"
    export FORGE_SUBNET_SCAN="192.168.1.0/24"
    export DISTRO="ubuntu"
    export VERSION="24.04"
    
    # Create mock nmap
    cat << 'EOF' > "${MOCK_DIR}/nmap"
#!/bin/bash
if [[ "$*" == *"-sL"* ]]; then
    echo "Nmap scan report for 192.168.1.0"
    echo "Nmap scan report for 192.168.1.1"
    echo "Nmap scan report for 192.168.1.2"
    echo "Nmap scan report for 192.168.1.3"
    echo "Nmap scan report for 192.168.1.255"
elif [[ "$*" == *"-sn"* ]]; then
    echo "Host: 192.168.1.1 ()	Status: Up"
fi
EOF
    chmod +x "${MOCK_DIR}/nmap"

    # Create mock virsh
    cat << 'EOF' > "${MOCK_DIR}/virsh"
#!/bin/bash
echo " Id   Name               State"
echo "----------------------------------"
echo " 1    foo.beltec.us      running"
EOF
    chmod +x "${MOCK_DIR}/virsh"

    # Mock sudo
    cat << 'EOF' > "${MOCK_DIR}/sudo"
#!/bin/bash
"$@"
EOF
    chmod +x "${MOCK_DIR}/sudo"

    # Create dummy common names.txt
    mkdir -p "${CLOUD_INIT_DIR}/common"
    echo "baz" > "${CLOUD_INIT_DIR}/common/names.txt"
    echo "qux" >> "${CLOUD_INIT_DIR}/common/names.txt"

    # Source the script (which will now not run main thanks to BASH_SOURCE check)
    source "${BATS_TEST_DIRNAME}/../host/provision_vm.sh"
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
    [[ "$NEWIP_YAML" == "${NEWIP}/16" ]]
}

@test "get_random_hostname gets a valid unused name" {
    export FORGE_BASE_DOMAIN="beltec.us"
    get_random_hostname
    
    [[ "$NEWNAME" == "baz" || "$NEWNAME" == "qux" ]]
    [[ "$NEWNAME_FQDN" == "${NEWNAME}.beltec.us" ]]
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

    download_os_image
    [ "$IMG_NAME" = "ubuntu-24.04-server-cloudimg-amd64.img" ]
    [ "$OS_VARIANT" = "ubuntu24.04" ]
}
