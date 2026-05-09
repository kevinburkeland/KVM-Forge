# KVM-Forge TODO

A running list of planned improvements and additions.

---

## 🐧 Distros

- [x] Add **Debian** support (cloud image + checksum handling)
- [ ] Add **Fedora** support
- [ ] Add **Rocky Linux** support
- [ ] Add **openSUSE** support
- [ ] Auto-fetch latest cloud image URLs instead of hardcoding versions

---

## 🧩 Profiles

- [ ] `k3s` — Lightweight Kubernetes (k3s) single-node or agent setup
- [ ] `podman` — Rootless container host using Podman instead of Docker
- [ ] `dev` — General developer environment (git, build tools, language runtimes)
- [ ] `monitoring` — Prometheus + Grafana stack
- [ ] `jellyfin` — Media server via Docker Compose
- [ ] Extend existing `docker` profile with optional Portainer deployment
- [ ] Allow profiles to accept runtime variables (e.g. custom image, port)

---

## 🖥️ TUI Improvements

- [ ] Add VM name/hostname input field to TUI
- [ ] Show estimated resource summary (e.g. warn if memory > host available RAM)
- [ ] Add a "dry run" mode that prints the final `kvm-forge-cli` command without executing
- [ ] Support re-running TUI with previous values pre-filled

---

## ⚙️ CLI Improvements

- [ ] `--list-profiles` flag to print available profiles for a given distro
- [ ] `--list-distros` flag to print supported distros and versions
- [ ] `--dry-run` flag to print the resolved config without provisioning
- [x] Validate that requested profile exists for the selected distro before starting
- [x] Add bounded timeout retries for ping/SSH wait loops

---

## 🧪 Testing

- [x] Add bats tests for `kvm-forge-tui` input validation logic
- [x] Add tests for profile resolution and missing-profile error handling
- [x] Add tests for CLI wait/cloud-init retry behavior
- [x] Add tests for distro checksum mismatch + redownload paths
- [ ] Add integration smoke test that verifies cloud-init YAML is valid

---

## 📦 Infrastructure / Misc

- [x] Package `setup.sh` dependency checks into `lib/common.sh`
- [ ] Add a `kvm-forge-destroy` script to cleanly remove a VM and its disk
- [ ] Support reading default flag values from `config/forge.env`
- [ ] GitHub Actions CI to run bats test suite on push
- [ ] Add shellcheck linting and enforce it in CI
- [ ] Expand env-file validation to support safe escaped values while rejecting command substitution
