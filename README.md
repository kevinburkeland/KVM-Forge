# KVM-Forge

KVM-Forge is an automated, highly-modular provisioning system for creating and managing KVM virtual machines. Designed for local infrastructure and homelabs, it provides a simple CLI framework that supports multiple Linux distributions (Ubuntu, AlmaLinux) and allows you to rapidly deploy VMs with pre-configured software stacks via `cloud-init`.

## ✨ Features

- **Multi-Distro Support:** Seamlessly deploy Ubuntu, Debian, and AlmaLinux, automatically handling OS-specific quirks like predictable network interface names and checksum algorithms.
- **Automated Provisioning:** Uses `cloud-init` and `virt-install` to bootstrap new VMs with your SSH keys, custom users, and security hardening (disabled root SSH & password auth).
- **Dynamic Networking:** Automatically scans your local subnet with `nmap`, identifies active IPs, and assigns the first available IP address to your new VM.
- **Dynamic Thematic VM Naming:** Automatically assigns hostnames from curated theme-based name lists and avoids collisions with existing VM names.
- **Pre-configured Profiles:** Deploy purpose-built environments instantly. Available profiles include: `base`, `docker`, and `python`.
- **Interactive TUI:** Includes both a `setup.sh` configuration wizard and a `kvm-forge-tui` provisioner, both powered by `gum`, for a guided Terminal UI experience without needing to memorize flags.
- **Hardened Runtime Behavior:** Includes bounded SSH/ping wait loops, bridge preflight checks, and stricter shell safety defaults in entrypoints.
- **Educational Focus:** The repository is heavily documented with in-line contextual explanations of networking concepts (DNS, bridging, subnetting) and infrastructure logic (cloud-init, KVM), making it an excellent learning tool for IT and Networking students.
- **Standardized Portability:** Works out-of-the-box with generic `virt-manager` defaults (`virbr0`, `192.168.122.0/24`, `forge.example`) to ensure maximum compatibility and predictability across different Linux host environments.
- **Fully Tested:** Includes a robust `bats-core` unit testing suite with mocked dependencies and repeat-run stability checks.

## 🚀 Getting Started

### Prerequisites

Before starting, ensure your host machine is a Linux environment with KVM and Libvirt installed and running.

### 1. Setup Your Environment

Run the interactive setup script to configure your bridge interface, timezone, network details, and default SSH keys. This will securely generate a local `config/forge.env` file.

```bash
chmod +x setup.sh
./setup.sh
```

### 2. Provision a VM

#### Option A: Interactive TUI

Launch the interactive Terminal UI to be guided through each option step-by-step with menus and prompts:

```bash
bin/kvm-forge-tui
```

The TUI will walk you through selecting a distro, version, profile, vCPUs, memory, and disk size — then display a confirmation summary before provisioning.

> **Requires:** [`gum`](https://github.com/charmbracelet/gum) — installed automatically if missing.

#### Option B: CLI (non-interactive)

Use the CLI tool directly with flags for scripting or one-liners:

```bash
# Example: Deploy an AlmaLinux Docker host with 4 cores, 8GB RAM, and 50GB disk
bin/kvm-forge-cli --distro alma --profile docker --cpus 4 --memory 8192 --disk-size 50
```

**Available Flags:**

- `-d, --distro` : Distro to use (`ubuntu`, `debian`, or `alma`, default: `ubuntu`)
- `-v, --version` : Distro version (default: `24.04` for ubuntu, `12` for debian, `10` for alma)
- `-p, --profile` : Software profile to use (`base`, `docker`, `python`)
- `-c, --cpus` : Number of vCPUs (default: 4)
- `-m, --memory` : Memory in MB (default: 8192)
- `-s, --disk-size`: Disk size in GB (default: 30)

## 🏷️ Dynamic Thematic Naming

KVM-Forge assigns hostnames automatically from `cloud-init/common/names.txt` to keep VM names memorable and consistent.

- Names are selected randomly from the list.
- Existing VM names are checked first to avoid collisions.
- The selected short name is expanded to an FQDN using your configured base domain.

This gives you predictable, human-friendly naming without requiring manual hostname entry for every provision.

### 3. Run Unit Tests

To run the testing suite, ensure you have `bats` installed on your host system, then run:

```bash
./tests/run_tests.sh
```

## 🤖 AI Generation Disclosure

**Note:** Portions of the code in this repository—including the provisioning scripts, cloud-init configurations, dynamic networking logic, and security hardening—were generated and refined with the assistance of an AI coding agent (Antigravity by Google DeepMind). This was done to accelerate development, improve modularity, and ensure enterprise-grade bash best practices.

---

## 📋 Roadmap

See [TODO.md](TODO.md) for planned features, additional distros, new profiles, and other improvements.
