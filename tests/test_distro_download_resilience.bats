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
    make_mock "arping" 'echo "arping $*" >> "$CALL_LOG"; exit 0'
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
    export DISTRO="ubuntu"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="24.04"
    export CHECKSUM_FAIL_MODE="once"

    : > "ubuntu-24.04-server-cloudimg-amd64.img"

    # ==========================================
    # Systems Engineering: BATS Subshell Execution & Capture
    # - The 'run' built-in in BATS executes the following command block inside a completely isolated subshell.
    # - It intercepts standard output and standard error, saving it into the global '$output' variable.
    # - It intercepts the shell exit code, saving it into the global '$status' variable.
    # This prevents runtime failures from crashing the main test runner and enables standard assert comparisons.
    # ==========================================
    run download_os_image
    [ "$status" -eq 0 ]

    run grep -q "MD5 mismatch or file corrupt. Redownloading" <<< "$output"
    [ "$status" -eq 0 ]

    run /bin/grep -c "wget -q https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "ubuntu download_os_image aborts on second checksum mismatch" {
    export DISTRO="ubuntu"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="24.04"
    export CHECKSUM_FAIL_MODE="always"

    : > "ubuntu-24.04-server-cloudimg-amd64.img"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"The image verification failed due to an issue with the mirror or file."* ]]
}

@test "debian download_os_image redownloads once after checksum mismatch" {
    export DISTRO="debian"
    source "$REPO_ROOT/lib/provision_vm.sh"
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
    export DISTRO="debian"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="12"
    export CHECKSUM_FAIL_MODE="always"

    : > "debian-12-generic-amd64.qcow2"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"The image verification failed due to an issue with the mirror or file."* ]]
}

@test "alma download_os_image redownloads once after checksum mismatch" {
    export DISTRO="alma"
    source "$REPO_ROOT/lib/provision_vm.sh"
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
    export DISTRO="alma"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="10"
    export CHECKSUM_FAIL_MODE="always"

    : > "AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"The image verification failed due to an issue with the mirror or file."* ]]
}

@test "gentoo download_os_image redownloads once after checksum mismatch" {
    export DISTRO="gentoo"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="latest"
    export CHECKSUM_FAIL_MODE="once"

    : > "di-amd64-cloudinit-20260510T170106Z.qcow2"

    run download_os_image
    [ "$status" -eq 0 ]

    run grep -q "SHA256 mismatch or file corrupt. Redownloading" <<< "$output"
    [ "$status" -eq 0 ]

    run /bin/grep -c "wget -q https://distfiles.gentoo.org/releases/amd64/autobuilds/20260510T170106Z/di-amd64-cloudinit-20260510T170106Z.qcow2$" "$CALL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "gentoo download_os_image aborts on second checksum mismatch" {
    export DISTRO="gentoo"
    source "$REPO_ROOT/lib/provision_vm.sh"
    export VERSION="latest"
    export CHECKSUM_FAIL_MODE="always"

    : > "di-amd64-cloudinit-20260510T170106Z.qcow2"

    run download_os_image
    [ "$status" -ne 0 ]
    [[ "$output" == *"The image verification failed due to an issue with the mirror or file."* ]]
}

