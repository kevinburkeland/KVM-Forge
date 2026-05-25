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

    # Required command mocks per project rule.
    make_mock "virt-install" 'echo "virt-install $*" >> "$CALL_LOG"; exit 0'
    make_mock "wget" 'echo "wget $*" >> "$CALL_LOG"; exit 0'
    make_mock "nmap" 'echo "nmap $*" >> "$CALL_LOG"; exit 0'
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

    # Additional helpers used by scripts.
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'
    make_mock "md5sum" 'exit 0'
    make_mock "yq" '
if [[ "$1" == ".users[0].name" ]]; then
  cat >/dev/null
  echo "null"
  exit 0
fi
cat
'
    make_mock "shuf" 'cat'
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -f "$CALL_LOG"
    rm -rf "$TEST_HOME"
}

@test "kvm-forge-cli execute_provisioner parses VM details" {
    local prov
    prov="$(mktemp)"
    cat > "$prov" <<'EOF'
#!/usr/bin/env bash
echo "[INFO] beginning"
echo "vm-a.example.test"
echo "192.168.122.55"
echo "forge"
EOF
    chmod +x "$prov"

    # ==========================================
    # Systems Engineering: BATS Subshell Execution & Capture
    # - The 'run' built-in in BATS executes the following command block inside a completely isolated subshell.
    # - It intercepts standard output and standard error, saving it into the global '$output' variable.
    # - It intercepts the shell exit code, saving it into the global '$status' variable.
    # This prevents runtime failures from crashing the main test runner and enables standard assert comparisons.
    # ==========================================
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/bin/kvm-forge-cli'; PROVISION_SCRIPT='$prov'; DISTRO=ubuntu; PROFILE=base; VERSION=24.04; VCPU=2; MEMORY=2048; DISK_SIZE=20; execute_provisioner; echo \"\$VMNAME|\$VMIP|\$VMUSER\""
    rm -f "$prov"

    [ "$status" -eq 0 ]
    [[ "$output" == *"vm-a.example.test|192.168.122.55|forge"* ]]
}

@test "kvm-forge-cli execute_provisioner fails on malformed output" {
    local prov
    prov="$(mktemp)"
    cat > "$prov" <<'EOF'
#!/usr/bin/env bash
# Simulate a broken provisioner that produced no parseable VM detail lines.
exit 0
EOF
    chmod +x "$prov"

    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/bin/kvm-forge-cli'; sudo(){ :; }; PROVISION_SCRIPT='$prov'; DISTRO=ubuntu; PROFILE=base; VERSION=24.04; VCPU=2; MEMORY=2048; DISK_SIZE=20; execute_provisioner"
    rm -f "$prov"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to get VM details from provision script."* ]]
}

@test "kvm-forge-cli update_known_hosts removes both IP and hostname entries" {
    touch "$HOME/.ssh/known_hosts"

    run bash -c "export BATS_RUNNING=true; export HOME='$HOME'; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/bin/kvm-forge-cli'; VMIP='192.168.122.55'; VMNAME='vm-a.example.test'; update_known_hosts"
    [ "$status" -eq 0 ]

    run grep -q "ssh-keygen -f $HOME/.ssh/known_hosts -R 192.168.122.55" "$CALL_LOG"
    [ "$status" -eq 0 ]
    run grep -q "ssh-keygen -f $HOME/.ssh/known_hosts -R vm-a.example.test" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "provision_vm main fails when distro module is missing" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/lib/provision_vm.sh'; parse_vm_args(){ DISTRO='nope'; PROFILE='base'; VERSION='1'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Distribution module 'nope' not found"* ]]
}

@test "provision_vm main fails when profile yaml is missing" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/lib/provision_vm.sh'; parse_vm_args(){ DISTRO='ubuntu'; PROFILE='doesnotexist'; VERSION='24.04'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist for profile 'doesnotexist'"* ]]
}

@test "provision_vm main falls back to root when yq username is null" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; export FORGE_DEFAULT_USER=''; source() { if [[ \"\$1\" == *\"/lib/distros/\"* ]]; then return 0; else builtin source \"\$@\"; fi; }; source '$REPO_ROOT/lib/provision_vm.sh'; parse_vm_args(){ DISTRO='ubuntu'; PROFILE='base'; VERSION='24.04'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; download_os_image(){ IMG_NAME='placeholder.img'; OS_VARIANT='ubuntu24.04'; export IMG_NAME OS_VARIANT; }; get_available_ip(){ NEWIP='192.168.122.77'; NEWIP_YAML='192.168.122.77/24'; export NEWIP NEWIP_YAML; }; get_random_hostname(){ NEWNAME='vmroot'; NEWNAME_FQDN='vmroot.example.test'; export NEWNAME NEWNAME_FQDN; }; prepare_cloud_init_config(){ TEMP_DIR=\"\$(mktemp -d)\"; export TEMP_DIR; :; }; launch_vm(){ :; }; main | tail -n1"
    if [ "$status" -ne 0 ]; then
        echo "Output: $output"
    fi
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}
