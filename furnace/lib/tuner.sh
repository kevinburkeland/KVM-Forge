#!/bin/bash
# ==========================================
# KVM-Furnace Host Tuner Library
# ==========================================

# Minimal self-contained loggers for standalone repo readiness
furnace_log_info() {
    echo -e "\033[1;34m[FURNACE-INFO]\033[0m $1"
}

furnace_log_err() {
    echo -e "\033[1;31m[FURNACE-ERROR]\033[0m $1" >&2
}

# ==========================================
# Function: check_virtualization
# Mechanism: Asserts host hardware hypervisor capabilities.
# Checks `/dev/kvm` existence and virtualization BIOS flags.
# ==========================================
check_virtualization() {
    furnace_log_info "Diagnosing hardware virtualization capability..."
    
    # 1. Check if virtualization extensions are enabled in BIOS/hardware
    if ! grep -E -q "vmx|svm" /proc/cpuinfo; then
        furnace_log_err "Hardware virtualization extensions (Intel VT-x or AMD-V) are missing from CPU info."
        furnace_log_err "Ensure virtualization is enabled in your BIOS/UEFI settings."
        return 1
    fi
    furnace_log_info "  [OK] CPU hardware virtualization support detected (Intel VMX or AMD SVM flags present)."

    # 2. Check if the KVM kernel module is loaded and accessible
    if [ ! -c /dev/kvm ]; then
        furnace_log_err "The virtualization kernel module device '/dev/kvm' is missing or inaccessible."
        furnace_log_err "Please run 'sudo modprobe kvm' (and 'sudo modprobe kvm_intel' or 'kvm_amd') to load KVM."
        return 1
    fi
    furnace_log_info "  [OK] Kernel KVM module loaded successfully (/dev/kvm is active)."

    # 3. Optional: Run kvm-ok diagnostic helper if installed
    if command -v kvm-ok &>/dev/null; then
        if ! kvm-ok &>/dev/null; then
            furnace_log_err "Diagnostic command 'kvm-ok' reports KVM acceleration cannot be used."
            return 1
        fi
        furnace_log_info "  [OK] kvm-ok validation passed successfully."
    fi

    furnace_log_info "System hardware virtualization capability validated successfully!"
    return 0
}

# ==========================================
# Function: enable_ip_forwarding
# Mechanism: Enables host IPv4 kernel packet forwarding via sysctl.
# ==========================================
enable_ip_forwarding() {
    furnace_log_info "Checking host IP packet forwarding parameters..."
    
    local is_forwarding
    is_forwarding=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    
    if [ "$is_forwarding" -eq 1 ]; then
        furnace_log_info "  [OK] IPv4 packet forwarding is already active."
        return 0
    fi
    
    furnace_log_info "IPv4 packet forwarding is currently disabled. Attempting to activate..."
    
    # Require root/sudo to write to sysctl
    local check_uid=${FURNACE_MOCK_UID:-$EUID}
    if [ "$check_uid" -ne 0 ]; then
        furnace_log_err "Elevated privileges are required to configure kernel sysctl parameters."
        furnace_log_err "Please rerun this setup wizard with sudo."
        return 1
    fi

    
    # Enable forwarding in real-time
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || echo 1 > /proc/sys/net/ipv4/ip_forward; then
        furnace_log_info "  [OK] Successfully enabled IPv4 packet forwarding dynamically in host kernel."
    else
        furnace_log_err "Failed to modify net.ipv4.ip_forward kernel parameter."
        return 1
    fi

    # Persist the change in sysctl.conf if possible
    local sysctl_conf="/etc/sysctl.d/99-kvm-furnace.conf"
    if [ -d "/etc/sysctl.d" ]; then
        echo "net.ipv4.ip_forward=1" > "$sysctl_conf" 2>/dev/null && \
        furnace_log_info "  [OK] Persisted forwarding parameter across reboots in $sysctl_conf."
    fi
    
    return 0
}
