#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    export FURNACE_ROOT="${BATS_TEST_DIRNAME}/.."

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

    # Mock system commands to track execution logs deterministically
    make_mock "sysctl" 'echo "sysctl $*" >> "$CALL_LOG"; echo "0"; exit 0'
    make_mock "iptables" '
        echo "iptables $*" >> "$CALL_LOG"
        if [[ "$*" == *"-C"* ]]; then
            exit 1
        fi
        exit 0
    '
    make_mock "ip" '
        echo "ip $*" >> "$CALL_LOG"
        # Simulate that bridge link check fails initially so bridge gets created
        if [[ "$*" == "link show "* ]]; then
            exit 1
        fi
        exit 0
    '
    make_mock "kvm-ok" 'echo "kvm-ok" >> "$CALL_LOG"; exit 0'
    make_mock "gum" 'echo "gum $*" >> "$CALL_LOG"; exit 0'

    # Mock /dev/kvm existence
    mkdir -p "${MOCK_DIR}/dev"
    touch "${MOCK_DIR}/dev/kvm"
}

teardown() {
    cd "$ORIG_PWD"
    /bin/rm -rf "$MOCK_DIR"
    /bin/rm -f "$CALL_LOG"
    /bin/rm -rf "$WORK_DIR"
}

@test "furnace-tune standalone execution fails on missing parameters" {
    run "${FURNACE_ROOT}/bin/furnace-tune"
    [ "$status" -eq 2 ]
}

@test "tuner check_virtualization completes successfully in mock environment" {
    source "${FURNACE_ROOT}/lib/tuner.sh"
    
    # Mock /dev/kvm check inside tuner
    # Force cpuinfo check to pass by mocking grep for /proc/cpuinfo specifically
    make_mock "grep" '
        if [[ "$*" == *"/proc/cpuinfo"* ]]; then
            exit 0
        fi
        exec /bin/grep "$@"
    '

    run check_virtualization
    [ "$status" -eq 0 ]
}

@test "tuner enable_ip_forwarding triggers sysctl when currently disabled" {
    source "${FURNACE_ROOT}/lib/tuner.sh"

    # Make sysctl net.ipv4.ip_forward return 0 initially, and run as fake root to bypass EUID
    export FURNACE_MOCK_UID=0
    
    run enable_ip_forwarding
    [ "$status" -eq 0 ]
    run grep -q "sysctl -w net.ipv4.ip_forward=1" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "networking create_bridge executes correct ip link link and addr setup commands" {
    source "${FURNACE_ROOT}/lib/networking.sh"
    export FURNACE_MOCK_UID=0

    run create_bridge "forgebr0" "192.168.122.1" "24"
    [ "$status" -eq 0 ]

    run grep -q "ip link add name forgebr0 type bridge" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "ip link set forgebr0 up" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "ip addr add 192.168.122.1/24 dev forgebr0" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "networking setup_nat_masquerade executes iptables configuration rules" {
    source "${FURNACE_ROOT}/lib/networking.sh"
    export FURNACE_MOCK_UID=0

    run setup_nat_masquerade "forgebr0" "192.168.122.0/24"
    [ "$status" -eq 0 ]

    run grep -q "iptables -t nat -A POSTROUTING -s 192.168.122.0/24 ! -o forgebr0 -j MASQUERADE" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "furnace-tune parses standalone parameters and executes core tune helpers" {
    # Force cpuinfo and root checks to succeed
    make_mock "grep" '
        if [[ "$*" == *"/proc/cpuinfo"* ]]; then
            exit 0
        fi
        exec /bin/grep "$@"
    '
    export FURNACE_MOCK_UID=0

    run "${FURNACE_ROOT}/bin/furnace-tune" --bridge forgebr0 --subnet 192.168.122.0/24 --gateway 192.168.122.1
    [ "$status" -eq 0 ]

    run grep -q "ip link add name forgebr0 type bridge" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "iptables -t nat -A POSTROUTING -s 192.168.122.0/24 ! -o forgebr0 -j MASQUERADE" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "furnace-tune interactive wizard runs successfully with mocked gum inputs" {
    # Force cpuinfo and root checks to succeed
    make_mock "grep" '
        if [[ "$*" == *"/proc/cpuinfo"* ]]; then
            exit 0
        fi
        exec /bin/grep "$@"
    '
    export FURNACE_MOCK_UID=0

    # Custom gum mock to answer prompts in interactive wizard
    make_mock "gum" '
        echo "gum $*" >> "$CALL_LOG"
        if [[ "$*" == *"confirm"* ]]; then
            exit 0
        elif [[ "$*" == *"Enter bridge interface"* ]]; then
            echo "forgebr0"
        elif [[ "$*" == *"Enter gateway IP"* ]]; then
            echo "192.168.122.1"
        elif [[ "$*" == *"Enter full subnet"* ]]; then
            echo "192.168.122.0/24"
        fi
        exit 0
    '

    run "${FURNACE_ROOT}/bin/furnace-tune" --interactive
    [ "$status" -eq 0 ]

    # Verify that the -- flag was used before the styled headers that start with -
    run grep -q "gum style --foreground 117 --bold -- --- STEP 1: Hardware Virtualization Diagnostics ---" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "gum style --foreground 117 --bold -- --- STEP 2: IP Forwarding Configuration ---" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "gum style --foreground 117 --bold -- --- STEP 3: Layer-2 Bridge & Layer-3 NAT Routing ---" "$CALL_LOG"
    [ "$status" -eq 0 ]

    run grep -q "ip link add name forgebr0 type bridge" "$CALL_LOG"
    [ "$status" -eq 0 ]
}

