#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."

    export MOCK_DIR
    MOCK_DIR="$(mktemp -d)"

    export CALL_LOG
    CALL_LOG="$(mktemp)"

    export PATH="${MOCK_DIR}:$PATH"

    make_mock() {
        local name="$1"
        local body="$2"
        cat > "${MOCK_DIR}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
        chmod +x "${MOCK_DIR}/${name}"
    }

    # Required mocks per project rule: never call real infrastructure commands.
    make_mock "virt-install" 'echo "virt-install $*" >> "$CALL_LOG"; exit 0'
    make_mock "wget" 'echo "wget $*" >> "$CALL_LOG"; exit 0'
    make_mock "nmap" 'echo "nmap $*" >> "$CALL_LOG"; exit 0'
    make_mock "ping" 'echo "ping $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh" 'echo "ssh $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh-keygen" 'echo "ssh-keygen $*" >> "$CALL_LOG"; exit 0'

    # apt-get mock: logs actions and can materialize command binaries for post-install verification.
    make_mock "apt-get" '
 echo "apt-get $*" >> "$CALL_LOG"
 if [[ "$1" == "install" ]]; then
   pkg="${@: -1}"
   case "$pkg" in
     gum|yq|virtinst|nmap|wget|coreutils)
       cmd_name="$pkg"
       [[ "$pkg" == "virtinst" ]] && cmd_name="virt-install"
       [[ "$pkg" == "coreutils" ]] && cmd_name="shuf"
       cat > "$MOCK_DIR/$cmd_name" <<INNER
#!/usr/bin/env bash
exit 0
INNER
       chmod +x "$MOCK_DIR/$cmd_name"
       if [[ "$pkg" == "coreutils" ]]; then
         cp "$MOCK_DIR/$cmd_name" "$MOCK_DIR/md5sum"
         cp "$MOCK_DIR/$cmd_name" "$MOCK_DIR/sha256sum"
       fi
       ;;
   esac
 fi
 exit 0
 '

    # dnf mock: same concept as apt-get.
    make_mock "dnf" '
 echo "dnf $*" >> "$CALL_LOG"
 if [[ "$1" == "install" ]]; then
   pkg="${@: -1}"
   case "$pkg" in
     gum|yq|virt-install|nmap|wget|coreutils)
       cmd_name="$pkg"
       cat > "$MOCK_DIR/$cmd_name" <<INNER
#!/usr/bin/env bash
exit 0
INNER
       chmod +x "$MOCK_DIR/$cmd_name"
       if [[ "$pkg" == "coreutils" ]]; then
         cp "$MOCK_DIR/$cmd_name" "$MOCK_DIR/shuf"
         cp "$MOCK_DIR/$cmd_name" "$MOCK_DIR/md5sum"
         cp "$MOCK_DIR/$cmd_name" "$MOCK_DIR/sha256sum"
       fi
       ;;
   esac
 fi
 exit 0
 '

    # Helper command mocks used by dependency installers.
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'
    make_mock "curl" 'echo "curl $*" >> "$CALL_LOG"; printf "MOCK_GPG_KEY\n"'
    make_mock "gpg" 'echo "gpg $*" >> "$CALL_LOG"; cat >/dev/null; exit 0'
    make_mock "tee" 'echo "tee $*" >> "$CALL_LOG"; cat >/dev/null; exit 0'
    make_mock "snap" 'echo "snap $*" >> "$CALL_LOG"; exit 0'
    make_mock "mkdir" 'echo "mkdir $*" >> "$CALL_LOG"; exit 0'
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -f "$CALL_LOG"
}

@test "parse_vm_args defaults are applied" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args; echo \"\$DISTRO|\$VERSION|\$PROFILE|\$VCPU|\$MEMORY|\$DISK_SIZE\""
    [ "$status" -eq 0 ]
    [ "$output" = "ubuntu|24.04|base|4|8192|30" ]
}

@test "parse_vm_args rejects cpu value 0" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -c 0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CPUs (-c) must be a positive integer."* ]]
}

@test "parse_vm_args rejects negative memory" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -m -1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Memory (-m) must be a positive integer."* ]]
}

@test "parse_vm_args rejects decimal disk size" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -s 1.5"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Disk size (-s) must be a positive integer."* ]]
}

@test "parse_vm_args handles missing cpu value" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CPUs (-c) must be a positive integer."* ]]
}

@test "parse_vm_args rejects unknown parameter" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args --wat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown parameter passed: --wat"* ]]
}

@test "parse_vm_args help returns usage text" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -h"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "parse_vm_args fails for unknown distro when version omitted" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; parse_vm_args -d nonexistent"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown distro: nonexistent"* ]]
}

@test "dependency checker no-op when command exists" {
    run bash -c "export BATS_RUNNING=true; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies bash; echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]

    run grep -Eq "apt-get|dnf" "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "dependency checker exits when user declines install" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; read(){ REPLY=n; return 0; }; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies missingcmd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Please install the missing dependencies and run the script again."* ]]
}

@test "dependency checker uses apt-get branch" {
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; command(){ if [[ \"\$1\" == \"-v\" && \"\$2\" == \"gum\" ]]; then return 1; fi; builtin command \"\$@\"; }; read(){ REPLY=y; return 0; }; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies gum || true"

    run grep -q "apt-get install -y gum" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "dependency checker uses dnf branch when apt-get absent" {
    mv "$MOCK_DIR/apt-get" "$MOCK_DIR/apt-get.disabled"

    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; command(){ if [[ \"\$1\" == \"-v\" && \"\$2\" == \"gum\" ]]; then return 1; fi; if [[ \"\$1\" == \"-v\" && \"\$2\" == \"apt-get\" ]]; then return 1; fi; builtin command \"\$@\"; }; read(){ REPLY=y; return 0; }; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies gum || true"

    run grep -q "dnf install -y gum" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "dependency checker errors on unsupported package manager" {
    mv "$MOCK_DIR/apt-get" "$MOCK_DIR/apt-get.disabled"
    mv "$MOCK_DIR/dnf" "$MOCK_DIR/dnf.disabled"

    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; command(){ if [[ \"\$1\" == \"-v\" && (\"\$2\" == \"missingcmd\" || \"\$2\" == \"apt-get\" || \"\$2\" == \"dnf\") ]]; then return 1; fi; builtin command \"\$@\"; }; read(){ REPLY=y; return 0; }; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies missingcmd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsupported package manager."* ]]
}

@test "dependency checker fails post-install verification when yq is still missing" {
    # yq branch tries: snap install yq || apt-get install -y yq
    # Our snap mock returns success but does not create yq, so verification should fail.
    run bash -c "export BATS_RUNNING=true; export PATH='$MOCK_DIR':\$PATH; command(){ if [[ \"\$1\" == \"-v\" && \"\$2\" == \"yq\" ]]; then return 1; fi; builtin command \"\$@\"; }; read(){ REPLY=y; return 0; }; source '$REPO_ROOT/lib/common.sh'; check_and_install_dependencies yq"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to install yq."* ]]
}
