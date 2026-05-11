#!/usr/bin/env bats

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
    make_mock "apt-get" 'echo "apt-get $*" >> "$CALL_LOG"; exit 0'
    make_mock "dnf" 'echo "dnf $*" >> "$CALL_LOG"; exit 0'

    # Additional helpers used by scripts.
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'
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
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/host/provision_vm.sh'; parse_vm_args(){ DISTRO='nope'; PROFILE='base'; VERSION='1'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Distribution module 'nope' not found"* ]]
}

@test "provision_vm main fails when profile yaml is missing" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; source '$REPO_ROOT/host/provision_vm.sh'; parse_vm_args(){ DISTRO='ubuntu'; PROFILE='doesnotexist'; VERSION='24.04'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; main"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist for profile 'doesnotexist'"* ]]
}

@test "provision_vm main falls back to root when yq username is null" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; export FORGE_DEFAULT_USER=''; source '$REPO_ROOT/host/provision_vm.sh'; parse_vm_args(){ DISTRO='ubuntu'; PROFILE='base'; VERSION='24.04'; VCPU=1; MEMORY=512; DISK_SIZE=5; export DISTRO PROFILE VERSION VCPU MEMORY DISK_SIZE; }; check_and_install_dependencies(){ :; }; download_os_image(){ IMG_NAME='dummy.img'; OS_VARIANT='ubuntu24.04'; export IMG_NAME OS_VARIANT; }; get_available_ip(){ NEWIP='192.168.122.77'; NEWIP_YAML='192.168.122.77/24'; export NEWIP NEWIP_YAML; }; get_random_hostname(){ NEWNAME='vmroot'; NEWNAME_FQDN='vmroot.example.test'; export NEWNAME NEWNAME_FQDN; }; prepare_cloud_init_config(){ TEMP_DIR=\"$(mktemp -d)\"; export TEMP_DIR; :; }; launch_vm(){ :; }; main | tail -n1"
    [ "$status" -eq 0 ]
    [ "$output" = "root" ]
}
