#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    # Load common library
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

@test "log_info outputs correctly formatted message" {
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
