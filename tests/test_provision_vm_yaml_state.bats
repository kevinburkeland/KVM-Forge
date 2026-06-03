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
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."

    export MOCK_DIR
    MOCK_DIR="$(mktemp -d)"
    export CALL_LOG
    CALL_LOG="$(mktemp)"

    export PATH="${MOCK_DIR}:$PATH"

    export TEST_HOME
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    mkdir -p "$HOME/.ssh"

    export CLOUD_INIT_DIR
    CLOUD_INIT_DIR="$(mktemp -d)"
    mkdir -p "$CLOUD_INIT_DIR/common"

    # Shared fixture files used by prepare_cloud_init_config.
    cat > "$CLOUD_INIT_DIR/common/network-config" <<'EOF'
#cloud-config
iface: INTERFACE_NAME
address: OLD_ADDR
gateway4: OLD_GW
search: OLD_SEARCH
dns: OLD_DNS
EOF

    cat > "$CLOUD_INIT_DIR/common/names.txt" <<'EOF'
foo
qux
EOF

    export USER_DATA_FILE
    USER_DATA_FILE="$(mktemp)"
    cat > "$USER_DATA_FILE" <<'EOF'
#cloud-config
hostname: old-host
fqdn: old-host.example
timezone: old-tz
user_name: old-user
ssh_key: old-key
EOF

    export PUBKEY_PATH="$HOME/.ssh/id_ed25519.pub"
    echo "ssh-ed25519 AAAATESTKEY test@kvm-forge" > "$PUBKEY_PATH"

    # ==========================================
    # Systems Engineering: Intercepting Binaries via PATH Manipulation (make_mock)
    # - How it works: The make_mock function creates a lightweight executable shell script in a dedicated
    #   temporary folder (MOCK_DIR).
    # - Interception: By prepending MOCK_DIR to the system PATH environment variable (PATH="${MOCK_DIR}:$PATH"),
    #   the operating system will look in our temporary folder FIRST when searching for binary commands.
    #   Any call to virt-install, ssh, wget, etc., resolves to our mock script rather than the actual system binary,
    #   allowing us to record invocations in CALL_LOG and control execution return codes dynamically.
    # ==========================================
    make_mock() {
        local name="$1"
        local body="$2"
        cat > "${MOCK_DIR}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
        chmod +x "${MOCK_DIR}/${name}"
    }

    # Required mocks per rule.
    make_mock "virt-install" 'echo "virt-install $*" >> "$CALL_LOG"; exit 0'
    make_mock "wget" 'echo "wget $*" >> "$CALL_LOG"; exit 0'
    make_mock "nmap" '
 echo "nmap $*" >> "$CALL_LOG"
 if [[ "$*" == *"-sL"* ]]; then
   cat <<INNER
Nmap scan report for 192.168.1.10
Nmap scan report for 192.168.1.11
Nmap scan report for 192.168.1.12
Nmap scan report for 192.168.1.13
Nmap scan report for 192.168.1.14
INNER
 elif [[ "$*" == *"-sn"* ]]; then
   cat <<INNER
Host: 192.168.1.11 ()\tStatus: Up
INNER
 fi
 exit 0
 '
    make_mock "ping" 'echo "ping $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh" 'echo "ssh $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh-keygen" 'echo "ssh-keygen $*" >> "$CALL_LOG"; exit 0'
    # ==========================================
    # Systems Engineering: Simulating Heterogeneous Host Distributions
    # - Mocking Package Managers: By mocking 'apt-get' (Debian/Ubuntu) and 'dnf' (RHEL/Alma), we can simulate
    #   both primary Linux packaging environments. This allows us to verify that our dependency installer
    #   logic correctly detects the host OS flavor and invokes the appropriate package management commands.
    # ==========================================
    make_mock "apt-get" 'echo "apt-get $*" >> "$CALL_LOG"; exit 0'
    make_mock "dnf" 'echo "dnf $*" >> "$CALL_LOG"; exit 0'

    # Helper mocks used by script internals.
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'
    make_mock "virsh" '
 echo " Id   Name               State"
 echo "----------------------------------"
 echo " 1    foo.forge.example      running"
 '

    # Deterministic shuf:
    # - For hostname selection (-n 1), return foo first then qux to force one collision loop.
    # - Otherwise return stdin unchanged (used by get_available_ip ordering).
    make_mock "shuf" '
 state_file="$MOCK_DIR/.shuf_state"
 if [[ "$1" == "-n" && "$2" == "1" ]]; then
   c=0
   [[ -f "$state_file" ]] && c=$(cat "$state_file")
   if [[ "$c" -eq 0 ]]; then
     echo "1" > "$state_file"
     echo "foo"
   else
     echo "qux"
   fi
 else
   cat
 fi
 '

    # Minimal yq mock that intentionally drops #cloud-config header to verify yq_edit restores it.
    # It applies deterministic replacements matching queries used by prepare_cloud_init_config.
    make_mock "yq" '
 query="$1"
 input="$(cat)"
 input="$(printf "%s\n" "$input" | sed "1{/^#cloud-config$/d}")"

 case "$query" in
   *"addresses[0]"*)
     printf "%s\n" "$input" | sed "s|^address: .*|address: ${NEWIP_YAML}|"
     ;;
   *"gateway4"*)
     printf "%s\n" "$input" | sed "s|^gateway4: .*|gateway4: ${FORGE_GATEWAY}|"
     ;;
   *"nameservers.search[0]"*)
     printf "%s\n" "$input" | sed "s|^search: .*|search: ${FORGE_DNS_SEARCH}|"
     ;;
   *"nameservers.addresses"*)
     printf "%s\n" "$input" | sed "s|^dns: .*|dns: ${FORGE_DNS_SERVERS}|"
     ;;
   *".hostname"*)
     printf "%s\n" "$input" | sed "s|^hostname: .*|hostname: ${REPNAME}|"
     ;;
   *".fqdn"*)
     printf "%s\n" "$input" | sed "s|^fqdn: .*|fqdn: ${REPNAME_FQDN}|"
     ;;
   *".timezone"*)
     printf "%s\n" "$input" | sed "s|^timezone: .*|timezone: ${FORGE_TIMEZONE}|"
     ;;
   *"ssh_authorized_keys"*)
     printf "%s\n" "$input" | sed "s|^ssh_key: .*|ssh_key: ${FORGE_SSH_KEY}|"
     ;;
   *"users[0].name"*)
     printf "%s\n" "$input" | sed "s|^user_name: .*|user_name: ${FORGE_DEFAULT_USER}|"
     ;;
   *)
     printf "%s\n" "$input"
     ;;
 esac
 '

    source "$REPO_ROOT/lib/provision_vm.sh"

    # Function provided by distro modules in production; define deterministic value for unit tests.
    get_interface_name() {
        echo "enp1s0"
    }
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -f "$CALL_LOG"
    rm -rf "$TEST_HOME"
    rm -rf "$CLOUD_INIT_DIR"
    rm -f "$USER_DATA_FILE"
    if [[ -n "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

@test "prepare_cloud_init_config preserves cloud-config header in generated files" {
    export NEWIP_YAML="192.168.1.22/24"
    export NEWNAME="host22"
    export NEWNAME_FQDN="host22.example.test"
    export FORGE_GATEWAY="192.168.1.1"
    export FORGE_DNS_SEARCH="example.test"
    export FORGE_DNS_SERVERS="1.1.1.1,8.8.8.8"
    export FORGE_TIMEZONE="UTC"
    export FORGE_DEFAULT_USER="forge"
    export FORGE_SSH_KEY_PATH="~/.ssh/id_ed25519.pub"

    prepare_cloud_init_config "$USER_DATA_FILE"

    read -r net_first < "$TEMP_DIR/network-config"
    read -r user_first < "$TEMP_DIR/user-data"

    [ "$net_first" = "#cloud-config" ]
    [ "$user_first" = "#cloud-config" ]
}

@test "prepare_cloud_init_config injects expected network and user values" {
    export NEWIP_YAML="192.168.1.33/24"
    export NEWNAME="host33"
    export NEWNAME_FQDN="host33.example.test"
    export FORGE_GATEWAY="192.168.1.1"
    export FORGE_DNS_SEARCH="example.test"
    export FORGE_DNS_SERVERS="9.9.9.9,1.1.1.1"
    export FORGE_TIMEZONE="America/New_York"
    export FORGE_DEFAULT_USER="forgeuser"
    export FORGE_SSH_KEY_PATH="~/.ssh/id_ed25519.pub"

    prepare_cloud_init_config "$USER_DATA_FILE"

    # ==========================================
    # Systems Engineering: BATS Subshell Execution & Capture
    # - The 'run' built-in in BATS executes the following command block inside a completely isolated subshell.
    # - It intercepts standard output and standard error, saving it into the global '$output' variable.
    # - It intercepts the shell exit code, saving it into the global '$status' variable.
    # This prevents runtime failures from crashing the main test runner and enables standard assert comparisons.
    # ==========================================
    run grep -q "iface: enp1s0" "$TEMP_DIR/network-config"
    [ "$status" -eq 0 ]
    run grep -q "address: 192.168.1.33/24" "$TEMP_DIR/network-config"
    [ "$status" -eq 0 ]
    run grep -q "gateway4: 192.168.1.1" "$TEMP_DIR/network-config"
    [ "$status" -eq 0 ]
    run grep -q "search: example.test" "$TEMP_DIR/network-config"
    [ "$status" -eq 0 ]
    run grep -q "dns: 9.9.9.9,1.1.1.1" "$TEMP_DIR/network-config"
    [ "$status" -eq 0 ]

    run grep -q "hostname: host33" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]
    run grep -q "fqdn: host33.example.test" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]
    run grep -q "timezone: America/New_York" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]
    run grep -q "user_name: forgeuser" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]
    run grep -q "ssh_key: ssh-ed25519 AAAATESTKEY test@kvm-forge" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]
}

@test "get_available_ip excludes network broadcast and occupied hosts" {
    export SUBNET_SCAN="192.168.1.0/24"
    export CIDR_SUFFIX="24"

    get_available_ip

    # 10 and 14 are dropped as first/last from sL list; 11 is up.
    [ "$NEWIP" = "192.168.1.12" ]
    [ "$NEWIP_YAML" = "192.168.1.12/24" ]
}

@test "get_available_ip exits when no free addresses remain" {
    cat > "$MOCK_DIR/nmap" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-sL"* ]]; then
  cat <<INNER
Nmap scan report for 192.168.1.10
Nmap scan report for 192.168.1.11
Nmap scan report for 192.168.1.12
Nmap scan report for 192.168.1.13
Nmap scan report for 192.168.1.14
INNER
elif [[ "$*" == *"-sn"* ]]; then
  cat <<INNER
Host: 192.168.1.11 ()\tStatus: Up
Host: 192.168.1.12 ()\tStatus: Up
Host: 192.168.1.13 ()\tStatus: Up
INNER
fi
EOF
    chmod +x "$MOCK_DIR/nmap"

    run get_available_ip
    [ "$status" -ne 0 ]
    [[ "$output" == *"No available IPs found"* ]]
}

@test "get_random_hostname loops until unused name is found" {
    export FORGE_BASE_DOMAIN="forge.example"

    get_random_hostname

    [ "$NEWNAME" = "qux" ]
    [ "$NEWNAME_FQDN" = "qux.forge.example" ]
}

@test "launch_vm includes bypass and UEFI arguments when DISTRO=gentoo" {
    cat << 'EOF' > "${MOCK_DIR}/ip"
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    export DISTRO="gentoo"
    export NEWNAME_FQDN="gentoo-vm.forge.example"
    export NEWIP="192.168.122.50"
    export BRIDGE_IF="virbr0"
    export VCPU="2"
    export MEMORY="2048"
    export OS_VARIANT="gentoo"
    export DISK_SIZE="20"
    export IMG_NAME="di-amd64-cloudinit-latest.qcow2"
    export TEMP_DIR="$(mktemp -d)"

    launch_vm

    run cat "$CALL_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"virt-install"* ]]
    [[ "$output" == *"--sysinfo type=smbios,system_serial=ds=nocloud"* ]]
    [[ "$output" == *"--boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"* ]]
    [[ "$output" == *"--tpm none"* ]]

    rm -rf "$TEMP_DIR"
}

@test "launch_vm does not include bypass or UEFI arguments when DISTRO=ubuntu" {
    cat << 'EOF' > "${MOCK_DIR}/ip"
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    export DISTRO="ubuntu"
    export NEWNAME_FQDN="ubuntu-vm.forge.example"
    export NEWIP="192.168.122.51"
    export BRIDGE_IF="virbr0"
    export VCPU="2"
    export MEMORY="2048"
    export OS_VARIANT="ubuntu24.04"
    export DISK_SIZE="20"
    export IMG_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
    export TEMP_DIR="$(mktemp -d)"

    launch_vm

    run cat "$CALL_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"virt-install"* ]]
    [[ "$output" != *"--sysinfo"* ]]
    [[ "$output" != *"--boot"* ]]

    rm -rf "$TEMP_DIR"
}

@test "launch_vm does not include bypass or UEFI arguments when DISTRO=debian" {
    cat << 'EOF' > "${MOCK_DIR}/ip"
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    export DISTRO="debian"
    export NEWNAME_FQDN="debian-vm.forge.example"
    export NEWIP="192.168.122.52"
    export BRIDGE_IF="virbr0"
    export VCPU="2"
    export MEMORY="2048"
    export OS_VARIANT="debian12"
    export DISK_SIZE="20"
    export IMG_NAME="debian-12-generic-amd64.qcow2"
    export TEMP_DIR="$(mktemp -d)"

    launch_vm

    run cat "$CALL_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"virt-install"* ]]
    [[ "$output" != *"--sysinfo"* ]]
    [[ "$output" != *"--boot"* ]]

    rm -rf "$TEMP_DIR"
}

@test "prepare_cloud_init_config substitutes JUPYTER_TOKEN_PLACEHOLDER in user-data" {
    export NEWIP_YAML="192.168.1.44/24"
    export NEWNAME="host44"
    export NEWNAME_FQDN="host44.example.test"
    export FORGE_GATEWAY="192.168.1.1"
    export FORGE_DNS_SEARCH="example.test"
    export FORGE_DNS_SERVERS="1.1.1.1"
    export FORGE_TIMEZONE="UTC"
    export FORGE_DEFAULT_USER="forge"
    export FORGE_SSH_KEY_PATH="~/.ssh/id_ed25519.pub"
    export FORGE_JUPYTER_TOKEN="mycustomjupytertoken"

    local custom_user_data
    custom_user_data="$(mktemp)"
    cat > "$custom_user_data" <<'EOF'
#cloud-config
hostname: old-host
fqdn: old-host.example
timezone: old-tz
user_name: old-user
ssh_key: old-key
token_line: --ServerApp.token='JUPYTER_TOKEN_PLACEHOLDER'
EOF

    prepare_cloud_init_config "$custom_user_data"

    run grep -q "token_line: --ServerApp.token='mycustomjupytertoken'" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]

    rm -f "$custom_user_data"
}

@test "prepare_cloud_init_config defaults JUPYTER_TOKEN_PLACEHOLDER to forge when unset" {
    export NEWIP_YAML="192.168.1.45/24"
    export NEWNAME="host45"
    export NEWNAME_FQDN="host45.example.test"
    export FORGE_GATEWAY="192.168.1.1"
    export FORGE_DNS_SEARCH="example.test"
    export FORGE_DNS_SERVERS="1.1.1.1"
    export FORGE_TIMEZONE="UTC"
    export FORGE_DEFAULT_USER="forge"
    export FORGE_SSH_KEY_PATH="~/.ssh/id_ed25519.pub"
    unset FORGE_JUPYTER_TOKEN

    local custom_user_data
    custom_user_data="$(mktemp)"
    cat > "$custom_user_data" <<'EOF'
#cloud-config
hostname: old-host
fqdn: old-host.example
timezone: old-tz
user_name: old-user
ssh_key: old-key
token_line: --ServerApp.token='JUPYTER_TOKEN_PLACEHOLDER'
EOF

    prepare_cloud_init_config "$custom_user_data"

    run grep -q "token_line: --ServerApp.token='forge'" "$TEMP_DIR/user-data"
    [ "$status" -eq 0 ]

    rm -f "$custom_user_data"
}
