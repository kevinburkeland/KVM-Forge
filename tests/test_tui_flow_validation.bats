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

    export TEST_ROOT
    TEST_ROOT="$(mktemp -d)"
    export MOCK_DIR
    MOCK_DIR="$(mktemp -d)"
    export PATH="${MOCK_DIR}:$PATH"

    # ==========================================
    # Systems Engineering: Intercepting Binaries via PATH Manipulation
    # - How it works: Prepending MOCK_DIR to the PATH environment variable redirects commands like gum and yq
    #   to their sandboxed mock scripts, facilitating predictable UI testing.
    # ==========================================

    export CLI_LOG
    CLI_LOG="$(mktemp)"

    # Build a sandbox layout so SCRIPT_DIR-relative paths in kvm-forge-tui remain valid.
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config"
    ln -s "$REPO_ROOT/lib" "$TEST_ROOT/lib"
    cp "$REPO_ROOT/config/manifest.yaml" "$TEST_ROOT/config/manifest.yaml"
    cp "$REPO_ROOT/bin/kvm-forge-tui" "$TEST_ROOT/bin/kvm-forge-tui"
    chmod +x "$TEST_ROOT/bin/kvm-forge-tui"

    # Mock sibling CLI called by kvm-forge-tui execute_cli().
    cat > "$TEST_ROOT/bin/kvm-forge-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$CLI_LOG"
exit 0
EOF
    chmod +x "$TEST_ROOT/bin/kvm-forge-cli"

    # Queue-driven gum mock to simulate interactive flow deterministically.
    cat > "$MOCK_DIR/gum" <<'EOF'
#!/usr/bin/env bash
set -e
cmd="$1"
shift || true

pop_queue() {
    if [[ ! -f "$GUM_QUEUE" ]]; then
        echo "gum queue missing" >&2
        exit 1
    fi
    value="$(head -n 1 "$GUM_QUEUE")"
    tail -n +2 "$GUM_QUEUE" > "$GUM_QUEUE.tmp" || true
    mv "$GUM_QUEUE.tmp" "$GUM_QUEUE"
    printf '%s\n' "$value"
}

case "$cmd" in
    style)
        exit 0
        ;;
    choose)
        pop_queue
        ;;
    input)
        pop_queue
        ;;
    confirm)
        ans="$(pop_queue)"
        [[ "$ans" == "y" ]]
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$MOCK_DIR/gum"

    # Required command mocks per project rule.
    # ==========================================
    # Systems Engineering: Simulating Heterogeneous Host Distributions
    # - Mocking Package Managers: By mocking 'apt-get' (Debian/Ubuntu) and 'dnf' (RHEL/Alma), we can simulate
    #   both primary Linux packaging environments. This allows us to verify that our dependency installer
    #   logic correctly detects the host OS flavor and invokes the appropriate package management commands.
    # ==========================================
    for cmd in virt-install wget nmap ping ssh ssh-keygen apt-get dnf; do
        cat > "$MOCK_DIR/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$MOCK_DIR/$cmd"
    done

    # Mock yq to bypass snap confinement restrictions in /tmp
    cat > "$MOCK_DIR/yq" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == ".distros | keys | .[]" ]]; then
    echo -e "ubuntu\nalma\ndebian"
elif [[ "$1" == *".default_version" ]]; then
    if [[ "$1" == *"ubuntu"* ]]; then echo "24.04"; elif [[ "$1" == *"alma"* ]]; then echo "10"; else echo "12"; fi
elif [[ "$1" == *".supported_versions"* ]]; then
    echo "24.04"
elif [[ "$1" == *".profiles | .[]" ]]; then
    echo -e "base\npython\ndocker\ntesting\njupyter-datascience\nhome-assistant"
fi
EOF
    chmod +x "$MOCK_DIR/yq"
}

teardown() {
    /bin/rm -rf "$TEST_ROOT"
    /bin/rm -rf "$MOCK_DIR"
    /bin/rm -f "$CLI_LOG"
}

@test "tui exits with error on invalid vCPU input" {
    export GUM_QUEUE
    GUM_QUEUE="$(mktemp)"
    cat > "$GUM_QUEUE" <<'EOF'
ubuntu
24.04
base
abc
EOF

    # ==========================================
    # Systems Engineering: BATS Subshell Execution & Capture
    # - The 'run' built-in in BATS executes the following command block inside a completely isolated subshell.
    # - It intercepts standard output and standard error, saving it into the global '$output' variable.
    # - It intercepts the shell exit code, saving it into the global '$status' variable.
    # This prevents runtime failures from crashing the main test runner and enables standard assert comparisons.
    # ==========================================
    run "$TEST_ROOT/bin/kvm-forge-tui"

    [ "$status" -ne 0 ]
    [ ! -s "$CLI_LOG" ]

    /bin/rm -f "$GUM_QUEUE"
}

@test "tui exits with error on invalid memory input" {
    export GUM_QUEUE
    GUM_QUEUE="$(mktemp)"
    cat > "$GUM_QUEUE" <<'EOF'
ubuntu
24.04
base
4
mem
EOF

    run "$TEST_ROOT/bin/kvm-forge-tui"

    [ "$status" -ne 0 ]
    [ ! -s "$CLI_LOG" ]

    /bin/rm -f "$GUM_QUEUE"
}

@test "tui exits with error on invalid disk size input" {
    export GUM_QUEUE
    GUM_QUEUE="$(mktemp)"
    cat > "$GUM_QUEUE" <<'EOF'
ubuntu
24.04
base
4
8192
0
EOF

    run "$TEST_ROOT/bin/kvm-forge-tui"

    [ "$status" -ne 0 ]
    [ ! -s "$CLI_LOG" ]

    /bin/rm -f "$GUM_QUEUE"
}

@test "tui aborts cleanly when confirmation is declined" {
    export GUM_QUEUE
    GUM_QUEUE="$(mktemp)"
    cat > "$GUM_QUEUE" <<'EOF'
ubuntu
24.04
base
4
8192
30
n
EOF

    run "$TEST_ROOT/bin/kvm-forge-tui"
    
    if [ "$status" -ne 0 ]; then
        echo "TUI Output: $output"
    fi

    [ "$status" -eq 0 ]
    [ ! -s "$CLI_LOG" ]

    /bin/rm -f "$GUM_QUEUE"
}

@test "tui hands off validated args to kvm-forge-cli" {
    export GUM_QUEUE
    GUM_QUEUE="$(mktemp)"
    cat > "$GUM_QUEUE" <<'EOF'
alma
10
python
8
16384
50
y
EOF

    run "$TEST_ROOT/bin/kvm-forge-tui"

    [ "$status" -eq 0 ]

    run /bin/grep -q -- "--distro alma --version 10 --profile python --cpus 8 --memory 16384 --disk-size 50" "$CLI_LOG"
    [ "$status" -eq 0 ]

    /bin/rm -f "$GUM_QUEUE"
}
