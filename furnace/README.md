# KVM-Furnace: Host Environment Tuner & Network Bootstrapper

Welcome to **KVM-Furnace**, the host-level bootstrap, diagnostics, and environment tuning module of the **KVM-Forge** distributed virtualization ecosystem.

This module is designed to cleanly isolate host-level requirements (like virtual networking switch creation, hypervisor kernel configurations, and hardware capability validation) from day-to-day Virtual Machine lifecycle management. It is designed to be completely self-contained and acts as an educational, transparent sandbox for systems engineers learning Linux systems and networking administration.

---

## 🏗️ Systems Architecture Overview

To boot and run guest virtual machines under standard KVM hypervisors, the physical host machine must have its kernel parameters and networking interfaces properly configured:

```
                      +---------------------------------------+
                      |         Physical WAN Interface        |
                      |            (e.g., eth0, wlan0)        |
                      +---------------------------------------+
                                          ^
                                          | IP Forwarding & NAT Masquerading
                                          v
+------------------+  +---------------------------------------+
| Virtual Machine  |<-|   Virtual Network Bridge Switch       |
|  (Guest OS vNIC) |  |   (e.g. virbr0, forgebr0: 10.0.0.1/24)|
+------------------+  +---------------------------------------+
```

1. **Hardware Virtualization Support**: Checks that the CPU possesses hardware-assisted virtualization extensions (Intel VT-x or AMD-V) and that the kernel virtualization module (`/dev/kvm`) is loaded.
2. **Layer-2 Software Bridge**: Creates a virtual software ethernet switch. VMs bind their virtual taps to this switch to form a local area network (LAN).
3. **Layer-3 IP Forwarding**: Instructs the Linux kernel to allow IP packet forwarding between the private VM bridge and the public external network interface.
4. **NAT Masquerading**: Translates VM private IP addresses to the host's physical IP address when packets egress, enabling internet connectivity.

---

## 📶 Wi-Fi / WLAN Bridging Limitations

> [!WARNING]
> **Bridging Over Wi-Fi is Incompatible**: Standard 802.11 Wi-Fi frames use a 3-address header protocol. A wireless NIC client cannot transparently bridge multiple MAC addresses (the host MAC and individual guest VM MACs) over a single association. Access Points reject all frames originating from unassociated guest VM MAC addresses.
> 
> **The NAT Masquerade Solution**: If your host is connected to a wireless network, you **must not** attempt to bridge the guest VMs directly onto your physical wireless interface. Instead, you must keep the VMs on a private bridge interface (like `forgebr0`), enable kernel IP forwarding, and let the host NAT MASQUERADE the VM traffic through its physical wireless interface.

---

## 💨 Standalone Educational Mode

Students can run `KVM-Furnace` completely in isolation to explore how Linux virtualization and networking works under the hood.

### 1. Interactive Diagnostic Walkthrough
Launch the interactive educational setup wizard:
```bash
./bin/furnace-tui
```
*(This is a thin wrapper that invokes `./bin/furnace-tune --interactive`)*

### 2. Standalone CLI Provisioning
Manually bootstrap a virtual network bridge and configure host masquerading:
```bash
sudo ./bin/furnace-tune --bridge forgebr0 --subnet 192.168.122.0/24 --gateway 192.168.122.1
```

---

## 💡 Key Architectural Guidelines
- **No Black Boxes**: KVM-Furnace documents every host-level action with comprehensive shell logs and visual tutorials, explaining the "why" and "how".
- **Least Privilege Principle**: Elevation of host privileges is isolated strictly to the commands requiring it (e.g., `ip link`, `sysctl`, `iptables`). Standard validations can be performed by unprivileged users.
