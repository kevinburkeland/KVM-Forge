#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats &> /dev/null; then
    echo -e "\033[1;31m[ERROR]\033[0m 'bats' is not installed."
    echo "Please install bats-core to run these tests."
    echo "e.g., sudo apt-get install bats or npm install -g bats"
    exit 1
fi

echo "Running KVM-Forge unit tests..."
bats "$SCRIPT_DIR"/*.bats
