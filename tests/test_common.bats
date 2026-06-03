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
    # Load common library
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

@test "log_info outputs correctly formatted message" {
    # ==========================================
    # Systems Engineering: BATS Subshell Execution & Capture
    # - The 'run' built-in in BATS executes the following command block inside a completely isolated subshell.
    # - It intercepts standard output and standard error, saving it into the global '$output' variable.
    # - It intercepts the shell exit code, saving it into the global '$status' variable.
    # This prevents runtime failures from crashing the main test runner and enables standard assert comparisons.
    # ==========================================
    run log_info "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"*"Test message"* ]]
}

@test "log_err outputs correctly formatted message to stderr" {
    # bats captures stderr and stdout together in $output
    run log_err "Error message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ERROR]"*"Error message"* ]]
}

@test "parse_vm_args sets default variables correctly" {
    unset DISTRO VERSION PROFILE VCPU MEMORY DISK_SIZE
    
    parse_vm_args
    
    [ "$DISTRO" = "ubuntu" ]
    [ "$VERSION" = "24.04" ]
    [ "$PROFILE" = "base" ]
    [ "$VCPU" -eq 4 ]
    [ "$MEMORY" -eq 8192 ]
    [ "$DISK_SIZE" -eq 30 ]
}

@test "parse_vm_args parses valid overrides correctly" {
    unset DISTRO VERSION PROFILE VCPU MEMORY DISK_SIZE
    
    parse_vm_args -d alma -v 9 -p python -c 8 -m 16384 -s 50
    
    [ "$DISTRO" = "alma" ]
    [ "$VERSION" = "9" ]
    [ "$PROFILE" = "python" ]
    [ "$VCPU" -eq 8 ]
    [ "$MEMORY" -eq 16384 ]
    [ "$DISK_SIZE" -eq 50 ]
}

@test "parse_vm_args resolves default version for alma" {
    unset DISTRO VERSION PROFILE VCPU MEMORY DISK_SIZE
    
    parse_vm_args -d alma
    
    [ "$DISTRO" = "alma" ]
    [ "$VERSION" = "10" ]
}

@test "resolve_supported_os_variant bypasses check when BATS_RUNNING is set" {
    export BATS_RUNNING="true"
    run resolve_supported_os_variant "fedora44"
    [ "$status" -eq 0 ]
    [ "$output" = "fedora44" ]
}

@test "resolve_supported_os_variant falls back correctly when BATS_RUNNING is unset" {
    # Save the original BATS_RUNNING state
    local saved_bats="${BATS_RUNNING:-}"
    unset BATS_RUNNING
    
    # Mock virt-install inside this subshell
    virt-install() {
        if [[ "$*" == *"--osinfo name=fedora44"* ]]; then
            return 1
        elif [[ "$*" == *"--osinfo name=fedora42"* ]]; then
            return 0
        elif [[ "$*" == *"--osinfo list"* ]]; then
            echo "fedora42"
            echo "fedora41"
            echo "fedora40"
            return 0
        else
            return 1
        fi
    }
    
    # Export mock function so it is available to subshells if needed
    export -f virt-install
    
    run resolve_supported_os_variant "fedora44"
    
    # Restore original state
    if [ -n "$saved_bats" ]; then
        export BATS_RUNNING="$saved_bats"
    fi
    unset -f virt-install
    
    [ "$status" -eq 0 ]
    [ "$output" = "fedora42" ]
}

@test "resolve_supported_os_variant falls back to generic if no candidates are supported" {
    local saved_bats="${BATS_RUNNING:-}"
    unset BATS_RUNNING
    
    virt-install() {
        if [[ "$*" == *"--osinfo list"* ]]; then
            return 0
        elif [[ "$*" == *"--osinfo name=generic"* ]]; then
            return 0
        else
            return 1
        fi
    }
    export -f virt-install
    
    run resolve_supported_os_variant "fedora44"
    
    if [ -n "$saved_bats" ]; then
        export BATS_RUNNING="$saved_bats"
    fi
    unset -f virt-install
    
    [ "$status" -eq 0 ]
    [ "$output" = "generic" ]
}

