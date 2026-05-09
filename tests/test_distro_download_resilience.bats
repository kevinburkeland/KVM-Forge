#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."

    export ORIG_PWD
    ORIG_PWD="$(pwd)"

    export MOCK_DIR
    MOCK_DIR="$(mktemp -d)"
    export CALL_LOG
    CALL_LOG="$(mktemp)"
    export WORK_DIR
    WORK_DIR="$(mktemp -d)"

    cd "$WORK_DIR"
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

    # Required mocks per project rule.
    make_mock "virt-install" 'echo "virt-install $*" >> "$CALL_LOG"; exit 0'
    make_mock "wget" '
 echo "wget $*" >> "$CALL_LOG"
 # If -O is passed, touch the target to simulate checksum file download.
 if [[ "$1" == "-q" && "$3" == "-O" ]]; then
   : > "$4"
 fi
 exit 0
 '
    make_mock "nmap" 'echo "nmap $*" >> "$CALL_LOG"; exit 0'
    make_mock "ping" 'echo "ping $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh" 'echo "ssh $*" >> "$CALL_LOG"; exit 0'
    make_mock "ssh-keygen" 'echo "ssh-keygen $*" >> "$CALL_LOG"; exit 0'
    make_mock "apt-get" 'echo "apt-get $*" >> "$CALL_LOG"; exit 0'
    make_mock "dnf" 'echo "dnf $*" >> "$CALL_LOG"; exit 0'

    # Helpers used by distro scripts.
    make_mock "sudo" 'echo "sudo $*" >> "$CALL_LOG"; "$@"'
    make_mock "install" 'echo "install $*" >> "$CALL_LOG"; exit 0'
    make_mock "rm" 'echo "rm $*" >> "$CALL_LOG"; /bin/rm "$@"'

    # Checksum command mocks with deterministic first/second call behavior.
    make_mock "md5sum" '
 state_file="$MOCK_DIR/.md5sum_count"
 c=0
 [[ -f "$state_file" ]] && c=$(cat "$state_file")
 c=$((c + 1))
 echo "$c" > "$state_file"

 case "${CHECKSUM_FAIL_MODE:-never}" in
   once)
     [[ "$c" -eq 1 ]] && exit 1 || exit 0
     ;;
   always)
     exit 1
     ;;
   *)
     exit 0
     ;;
 esac
 '

    make_mock "sha256sum" '
 state_file="$MOCK_DIR/.sha256sum_count"
 c=0
 [[ -f "$state_file" ]] && c=$(cat "$state_file")
 c=$((c + 1))
 echo "$c" > "$state_file"

 case "${CHECKSUM_FAIL_MODE:-never}" in
   once)
     [[ "$c" -eq 1 ]] && exit 1 || exit 0
     ;;
   always)
     exit 1
     ;;
   *)
     exit 0
     ;;
 esac
 '

    make_mock "sha512sum" '
 state_file="$MOCK_DIR/.sha512sum_count"
 c=0
 [[ -f "$state_file" ]] && c=$(cat "$state_file")
 c=$((c + 1))
 echo "$c" > "$state_file"

 case "${CHECKSUM_FAIL_MODE:-never}" in
   once)
     [[ "$c" -eq 1 ]] && exit 1 || exit 0
     ;;
   always)
     exit 1
     ;;
   *)
     exit 0
     ;;
 esac
 '

  # Distro modules rely on log helpers from common.sh
  source "$REPO_ROOT/lib/common.sh"
}

teardown() {
    cd "$ORIG_PWD"
  /bin/rm -rf "$MOCK_DIR"
  /bin/rm -f "$CALL_LOG"
  /bin/rm -rf "$WORK_DIR"
}

@test "ubuntu download_os_image redownloads once after checksum mismatch" {
    source "$REPO_ROOT/lib/distros/ubuntu.sh"
    export VERSION="24.04"
    export CHECKSUM_FAIL_MODE="once"

    : > "ubuntu-24.04-server-cloudimg-amd64.img"

    run download_os_image
    [ "$status" -eq 0 ]

    run grep -q "MD5 mismatch or file corrupt. Redownloading" <<< "$output"
    [ "$status" -eq 0 ]

    run /bin/grep -c "wget -q https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "ubuntu download_os_image aborts on second checksum mismatch" {
    source "$REPO_ROOT/lib/distros/ubuntu.sh"
    export VERSION="24.04"
    export CHECKSUM_FAIL_MODE="always"

    : > "ubuntu-24.04-server-cloudimg-amd64.img"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"MD5 still mismatches after redownload"* ]]
}

@test "debian download_os_image redownloads once after checksum mismatch" {
    source "$REPO_ROOT/lib/distros/debian.sh"
    export VERSION="12"
    export CHECKSUM_FAIL_MODE="once"

    : > "debian-12-generic-amd64.qcow2"

    run download_os_image
    [ "$status" -eq 0 ]

    run grep -q "SHA512 mismatch or file corrupt. Redownloading" <<< "$output"
    [ "$status" -eq 0 ]

    run /bin/grep -c "wget -q https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "debian download_os_image aborts on second checksum mismatch" {
    source "$REPO_ROOT/lib/distros/debian.sh"
    export VERSION="12"
    export CHECKSUM_FAIL_MODE="always"

    : > "debian-12-generic-amd64.qcow2"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA512 still mismatches after redownload"* ]]
}

@test "alma download_os_image redownloads once after checksum mismatch" {
    source "$REPO_ROOT/lib/distros/alma.sh"
    export VERSION="10"
    export CHECKSUM_FAIL_MODE="once"

    : > "AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"

    run download_os_image
    [ "$status" -eq 0 ]

    run grep -q "SHA256 mismatch or file corrupt. Redownloading" <<< "$output"
    [ "$status" -eq 0 ]

    run /bin/grep -c "wget -q https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "alma download_os_image aborts on second checksum mismatch" {
    source "$REPO_ROOT/lib/distros/alma.sh"
    export VERSION="10"
    export CHECKSUM_FAIL_MODE="always"

    : > "AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA256 still mismatches after redownload"* ]]
}
