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

    # Required mocks per project rule.
    make_mock "virt-install" 'echo "virt-install $*" >> "$CALL_LOG"; exit 0'
    make_mock "wget" 'echo "wget $*" >> "$CALL_LOG"; exit 0'
    make_mock "nmap" 'echo "nmap $*" >> "$CALL_LOG"; exit 0'
    make_mock "ping" '
 echo "ping $*" >> "$CALL_LOG"
 state="$MOCK_DIR/.ping_count"
 c=0
 [[ -f "$state" ]] && c=$(cat "$state")
 c=$((c+1))
 echo "$c" > "$state"
 # fail first call, succeed second+ to exercise retry loop
 [[ "$c" -ge 2 ]] && exit 0 || exit 1
 '
    make_mock "ssh" '
 echo "ssh $*" >> "$CALL_LOG"
 # If command includes BatchMode=yes and exit probe, fail once then succeed.
 if [[ "$*" == *"BatchMode=yes"* ]] && [[ "$*" == *" exit"* ]]; then
   state="$MOCK_DIR/.ssh_probe_count"
   c=0
   [[ -f "$state" ]] && c=$(cat "$state")
   c=$((c+1))
   echo "$c" > "$state"
   [[ "$c" -ge 2 ]] && exit 0 || exit 1
 fi
 exit 0
 '
    make_mock "ssh-keygen" 'echo "ssh-keygen $*" >> "$CALL_LOG"; exit 0'
    make_mock "apt-get" 'echo "apt-get $*" >> "$CALL_LOG"; exit 0'
    make_mock "dnf" 'echo "dnf $*" >> "$CALL_LOG"; exit 0'

    # Helpers used by wait loops and command flow.
    make_mock "sleep" 'echo "sleep $*" >> "$CALL_LOG"; exit 0'
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'

    source "$REPO_ROOT/bin/kvm-forge-cli"

    export VMIP="192.168.122.50"
    export VMNAME="vm50.example.test"
    export VMUSER="forge"
}

teardown() {
    /bin/rm -rf "$MOCK_DIR"
    /bin/rm -f "$CALL_LOG"
    /bin/rm -rf "$TEST_HOME"
}

@test "wait_for_vm retries ping until success" {
    run wait_for_vm
    [ "$status" -eq 0 ]

    run /bin/grep -c "^ping -c 1 192.168.122.50$" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]

    run /bin/grep -q "^sleep 5$" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "wait_for_cloud_init retries ssh probe then runs cloud-init tail/wait command" {
    run wait_for_cloud_init
    [ "$status" -eq 0 ]

    # Two probe attempts expected (first fails, second succeeds)
    run /bin/grep -c "BatchMode=yes" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]

    # Final streaming command should be invoked after probe succeeds.
    run /bin/grep -q "cloud-init status --wait" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "wait_for_cloud_init includes private key flag when FORGE_SSH_KEY_PATH is set" {
    mkdir -p "$HOME/.ssh"
    echo "PRIVATE-KEY" > "$HOME/.ssh/id_kvmforge"
    export FORGE_SSH_KEY_PATH="~/.ssh/id_kvmforge.pub"

    run wait_for_cloud_init
    [ "$status" -eq 0 ]

    run /bin/grep -q -- "-i $HOME/.ssh/id_kvmforge" "$CALL_LOG"
    [ "$status" -eq 0 ]
}
