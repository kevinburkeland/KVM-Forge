#!/bin/bash
# ==========================================
# KVM-Furnace Networking Library
# ==========================================

# Minimal self-contained loggers for standalone repo readiness
furnace_log_info() {
    echo -e "\033[1;34m[FURNACE-INFO]\033[0m $1"
}

furnace_log_err() {
    echo -e "\033[1;31m[FURNACE-ERROR]\033[0m $1" >&2
}

# ==========================================
# Function: create_bridge
# Mechanism: Instantiates a virtual software bridge switch and assigns it an IP.
# Arguments:
#   1. bridge_name: The name of the interface (e.g. virbr0)
#   2. gateway_ip: The gateway IP for the bridge (e.g. 192.168.122.1)
#   3. cidr_suffix: The network CIDR suffix (e.g. 24)
# ==========================================
create_bridge() {
    local bridge_name="$1"
    local gateway_ip="$2"
    local cidr_suffix="$3"

    if [ -z "$bridge_name" ] || [ -z "$gateway_ip" ] || [ -z "$cidr_suffix" ]; then
        furnace_log_err "Missing arguments for bridge creation."
        return 2
    fi

    # Check if the bridge interface already exists
    if ip link show "$bridge_name" >/dev/null 2>&1; then
        furnace_log_info "  [OK] Bridge interface '$bridge_name' already exists."
        # Verify if it has the expected gateway IP address
        if ip addr show "$bridge_name" | grep -q "$gateway_ip"; then
            furnace_log_info "  [OK] Bridge '$bridge_name' is already configured with gateway IP $gateway_ip."
            # Remove any incorrect IPv4 addresses from this bridge to prevent routing issues
            local check_uid=${FURNACE_MOCK_UID:-$EUID}
            if [ "$check_uid" -eq 0 ]; then
                local existing_ips
                existing_ips=$(ip -o -4 addr show dev "$bridge_name" 2>/dev/null | awk '{print $4}' || true)
                for ip_cidr in $existing_ips; do
                    local ip_addr
                    ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
                    if [ "$ip_addr" != "$gateway_ip" ]; then
                        furnace_log_info "  [CLEANUP] Removing obsolete/incorrect IP $ip_cidr from bridge '$bridge_name'..."
                        ip addr del "$ip_cidr" dev "$bridge_name" || true
                    fi
                done
            fi
            return 0
        else
            furnace_log_info "Bridge interface '$bridge_name' exists but is not configured with IP $gateway_ip."
        fi
    fi

    # Require root/sudo to write to network interfaces
    local check_uid=${FURNACE_MOCK_UID:-$EUID}
    if [ "$check_uid" -ne 0 ]; then
        furnace_log_err "Elevated privileges are required to create and configure virtual networking interfaces."
        furnace_log_err "Please rerun this setup wizard with sudo."
        return 1
    fi

    furnace_log_info "Configuring virtual software switch bridge '$bridge_name'..."

    # 1. Create the virtual bridge device
    if ! ip link show "$bridge_name" >/dev/null 2>&1; then
        if ip link add name "$bridge_name" type bridge; then
            furnace_log_info "  [OK] Created virtual bridge interface '$bridge_name' successfully."
        else
            furnace_log_err "Failed to create virtual bridge interface '$bridge_name'."
            return 1
        fi
    fi

    # 2. Enable/Up the interface state
    if ip link set "$bridge_name" up; then
        furnace_log_info "  [OK] Successfully set bridge '$bridge_name' interface state to UP."
    else
        furnace_log_err "Failed to bring bridge interface '$bridge_name' UP."
        return 1
    fi

    # 3. Assign the Layer-3 Gateway IP with full subnet mask boundaries
    local full_cidr="${gateway_ip}/${cidr_suffix}"
    if ip addr add "$full_cidr" dev "$bridge_name" 2>/dev/null; then
        furnace_log_info "  [OK] Configured bridge '$bridge_name' gateway IP to $full_cidr."
    else
        # If it failed because it already has it, ignore. Otherwise report error.
        if ip addr show "$bridge_name" | grep -q "$gateway_ip"; then
            furnace_log_info "  [OK] Bridge '$bridge_name' already configured with gateway IP $gateway_ip."
        else
            furnace_log_err "Failed to assign gateway IP $full_cidr to bridge interface."
            return 1
        fi
    fi

    # Remove any incorrect IPv4 addresses from this bridge to prevent routing issues
    local existing_ips
    existing_ips=$(ip -o -4 addr show dev "$bridge_name" 2>/dev/null | awk '{print $4}' || true)
    for ip_cidr in $existing_ips; do
        local ip_addr
        ip_addr=$(echo "$ip_cidr" | cut -d'/' -f1)
        if [ "$ip_addr" != "$gateway_ip" ]; then
            furnace_log_info "  [CLEANUP] Removing obsolete/incorrect IP $ip_cidr from bridge '$bridge_name'..."
            ip addr del "$ip_cidr" dev "$bridge_name" || true
        fi
    done

    return 0
}

# ==========================================
# Function: setup_nat_masquerade
# Mechanism: Enables host NAT masquerading for bridge VM egress traffic.
# Arguments:
#   1. bridge_name: The name of the virtual bridge (e.g. virbr0)
#   2. subnet_cidr: The subnet CIDR (e.g. 192.168.122.0/24)
# ==========================================
setup_nat_masquerade() {
    local bridge_name="$1"
    local subnet_cidr="$2"

    if [ -z "$bridge_name" ] || [ -z "$subnet_cidr" ]; then
        furnace_log_err "Missing arguments for NAT configuration."
        return 2
    fi

    # Require root/sudo to write to iptables
    local check_uid=${FURNACE_MOCK_UID:-$EUID}
    if [ "$check_uid" -ne 0 ]; then
        furnace_log_err "Elevated privileges are required to configure host routing and NAT rules."
        furnace_log_err "Please rerun this setup wizard with sudo."
        return 1
    fi

    # Standard POSIX iptables rules setup
    if command -v iptables &>/dev/null; then
        furnace_log_info "Configuring IPTables Layer-3 NAT rules for subnet $subnet_cidr..."

        # 1. Masquerade rule: Translate guest private IP to host outbound IP
        if ! iptables -t nat -C POSTROUTING -s "$subnet_cidr" ! -o "$bridge_name" -j MASQUERADE >/dev/null 2>&1; then
            if iptables -t nat -A POSTROUTING -s "$subnet_cidr" ! -o "$bridge_name" -j MASQUERADE; then
                furnace_log_info "  [OK] Configured NAT MASQUERADE rule for egress packets."
            else
                furnace_log_err "Failed to append NAT masquerade rule."
                return 1
            fi
        else
            furnace_log_info "  [OK] NAT MASQUERADE rule already active."
        fi

        # 2. Forwarding permissions: Allow traffic to flow through the bridge
        if ! iptables -C FORWARD -i "$bridge_name" -j ACCEPT >/dev/null 2>&1; then
            iptables -A FORWARD -i "$bridge_name" -j ACCEPT
        fi
        if ! iptables -C FORWARD -o "$bridge_name" -j ACCEPT >/dev/null 2>&1; then
            iptables -A FORWARD -o "$bridge_name" -j ACCEPT
        fi
        furnace_log_info "  [OK] Successfully configured forward rules for virtual bridge traffic."
    else
        furnace_log_err "Command 'iptables' not found. Please install iptables or configure nftables manually."
        return 1
    fi

    return 0
}
