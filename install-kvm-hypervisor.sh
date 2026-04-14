#!/usr/bin/env bash
# =============================================================================
# KVM Hypervisor Installer for Debian 13 (trixie)
# Turns a bare Debian 13 server into a KVM hypervisor managed via
# Cockpit web UI (https://<host>:9090) — functionally similar to ESXi.
#
# What this installs:
#   • KVM + QEMU          — the actual hypervisor / machine emulator
#   • libvirt             — VM lifecycle management layer (virsh / API)
#   • Cockpit + cockpit-machines — browser-based VM management (port 9090)
#   • OVMF (UEFI)         — UEFI firmware so VMs can boot modern OSes
#   • Bridge networking   — VMs share the physical NIC and get LAN IPs
#   • libguestfs-tools    — inspect / mount VM disk images offline
#
# Usage:
#   sudo bash install-kvm-hypervisor.sh
#
# Requirements:
#   • Debian 13 (trixie)
#   • CPU with Intel VT-x or AMD-V
#   • Run as root (or with sudo)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root:  sudo bash $0"

# ── OS check ──────────────────────────────────────────────────────────────────
section "Pre-flight checks"

if ! grep -q 'VERSION_CODENAME=trixie\|VERSION_ID="13"' /etc/os-release 2>/dev/null; then
    warn "This script targets Debian 13 (trixie). Proceeding anyway — YMMV."
else
    success "Debian 13 (trixie) confirmed."
fi

# ── CPU virtualisation check ─────────────────────────────────────────────────
if grep -qE 'vmx|svm' /proc/cpuinfo; then
    CPU_VIRT=$(grep -m1 -oE 'vmx|svm' /proc/cpuinfo)
    [[ "$CPU_VIRT" == "vmx" ]] && VENDOR="Intel VT-x" || VENDOR="AMD-V"
    success "Hardware virtualisation supported: ${VENDOR}"
else
    die "CPU does not support hardware virtualisation (no vmx/svm flag). KVM cannot run."
fi

# Check KVM kernel modules
if modprobe kvm 2>/dev/null && modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null; then
    success "KVM kernel modules loaded successfully."
else
    warn "Could not pre-load KVM modules — they will load automatically on first use."
fi

# ── Detect network configuration ─────────────────────────────────────────────
section "Detecting network configuration"

# Find the default-route interface
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
[[ -z "$DEFAULT_IF" ]] && die "Could not detect default network interface."
success "Primary interface: ${DEFAULT_IF}"

# Gather current IP settings
HOST_IP=$(ip -4 addr show "$DEFAULT_IF" | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
PREFIX=$(ip -4 addr show "$DEFAULT_IF" | awk '/inet / {split($2,a,"/"); print a[2]; exit}')
GATEWAY=$(ip route show default | awk '/^default/ {print $3; exit}')
DNS_SERVERS=$(resolvectl dns "$DEFAULT_IF" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ' \
              || awk '/^nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ')
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 8.8.4.4}"

info "  IP     : ${HOST_IP}/${PREFIX}"
info "  Gateway: ${GATEWAY}"
info "  DNS    : ${DNS_SERVERS}"

BRIDGE_NAME="br0"
USE_NM=$(systemctl is-active NetworkManager 2>/dev/null || true)

# ── Package installation ──────────────────────────────────────────────────────
section "Installing packages"

export DEBIAN_FRONTEND=noninteractive

info "Updating package lists..."
apt-get update -qq

PACKAGES=(
    # Core hypervisor
    qemu-system-x86
    qemu-utils
    # Libvirt – VM management API + daemon
    libvirt-daemon-system
    libvirt-clients
    # VM provisioning CLI
    virtinst
    # UEFI firmware for VMs (replaces legacy BIOS)
    ovmf
    # Network bridge tools
    bridge-utils
    # Cockpit – browser-based management UI
    cockpit
    cockpit-machines
    # Disk image inspection
    libguestfs-tools
    # Useful extras
    genisoimage
    cpu-checker
    virt-top
    numactl
)

info "Installing: ${PACKAGES[*]}"
apt-get install -y --no-install-recommends "${PACKAGES[@]}"
success "All packages installed."

# ── Kernel module configuration ───────────────────────────────────────────────
section "Configuring KVM kernel modules"

cat > /etc/modprobe.d/kvm.conf << 'EOF'
# Enable nested virtualisation (run VMs inside VMs, e.g. for testing)
options kvm_intel nested=1
options kvm_amd  nested=1
EOF

# Load modules now
modprobe kvm
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
success "KVM modules loaded."

# ── sysctl tuning ─────────────────────────────────────────────────────────────
section "Applying sysctl tuning for hypervisor use"

cat > /etc/sysctl.d/99-kvm-hypervisor.conf << 'EOF'
# Allow VMs to forward packets
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Bridge traffic passes through iptables (required for libvirt NAT)
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 0

# Performance tweaks for many concurrent VMs
vm.swappiness = 10
kernel.shmmax = 68719476736
EOF

sysctl --system -q
success "sysctl settings applied."

# ── Bridge networking ─────────────────────────────────────────────────────────
section "Setting up bridge network (${BRIDGE_NAME})"

# Check if bridge already exists and is up
if ip link show "$BRIDGE_NAME" &>/dev/null; then
    success "Bridge ${BRIDGE_NAME} already exists — skipping creation."
else
    if [[ "$USE_NM" == "active" ]]; then
        info "NetworkManager detected — configuring bridge via nmcli."

        # Remove any existing stale NM connections for this bridge
        nmcli con delete "${BRIDGE_NAME}" 2>/dev/null || true
        nmcli con delete "${BRIDGE_NAME}-slave-${DEFAULT_IF}" 2>/dev/null || true

        # Create the bridge connection
        nmcli con add \
            type bridge \
            ifname "${BRIDGE_NAME}" \
            con-name "${BRIDGE_NAME}" \
            bridge.stp no \
            bridge.forward-delay 0

        # Set static IP on the bridge
        nmcli con modify "${BRIDGE_NAME}" \
            ipv4.method manual \
            ipv4.addresses "${HOST_IP}/${PREFIX}" \
            ipv4.gateway "${GATEWAY}" \
            ipv4.dns "$(echo "$DNS_SERVERS" | tr ' ' ',')" \
            connection.autoconnect yes

        # Enslave the physical interface into the bridge
        nmcli con add \
            type bridge-slave \
            ifname "${DEFAULT_IF}" \
            master "${BRIDGE_NAME}" \
            con-name "${BRIDGE_NAME}-slave-${DEFAULT_IF}" \
            connection.autoconnect yes

        # Disable IP on the enslaved physical interface
        NM_PHYS_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
                      | awk -F: -v d="$DEFAULT_IF" '$2==d {print $1; exit}')
        if [[ -n "$NM_PHYS_CON" ]]; then
            nmcli con modify "$NM_PHYS_CON" \
                ipv4.method disabled \
                ipv6.method disabled \
                connection.autoconnect yes 2>/dev/null || true
        fi

        info "Activating bridge — network will drop briefly then resume on ${BRIDGE_NAME}."
        nmcli con up "${BRIDGE_NAME}" || warn "Bridge activation returned non-zero; verify with: ip addr show ${BRIDGE_NAME}"

    else
        info "Using /etc/network/interfaces for bridge configuration."

        # Backup existing config
        cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)"

        # Write bridge config into interfaces.d
        cat > "/etc/network/interfaces.d/${BRIDGE_NAME}" << EOF
# Physical interface — enslaved to bridge, no IP of its own
auto ${DEFAULT_IF}
iface ${DEFAULT_IF} inet manual

# Bridge — carries the host IP and all VM traffic
auto ${BRIDGE_NAME}
iface ${BRIDGE_NAME} inet static
    address ${HOST_IP}/${PREFIX}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVERS}
    bridge_ports ${DEFAULT_IF}
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF

        # Remove any existing static config for the physical IF from the main file
        sed -i "/^auto ${DEFAULT_IF}/,/^$/d" /etc/network/interfaces

        warn "Bridge config written to /etc/network/interfaces.d/${BRIDGE_NAME}."
        warn "Run 'ifdown ${DEFAULT_IF} && ifup ${BRIDGE_NAME}' or reboot to activate."
    fi
fi

success "Bridge configuration complete."

# ── libvirt configuration ─────────────────────────────────────────────────────
section "Configuring libvirt"

# Enable and start libvirtd
systemctl enable --now libvirtd
systemctl enable --now virtlogd

# Configure libvirt to listen on UNIX socket only (secure default)
sed -i 's/#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf
sed -i 's/#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf
sed -i 's/#auth_unix_rw = "none"/auth_unix_rw = "none"/' /etc/libvirt/libvirtd.conf

# Use session-based QEMU driver to run VMs as root (system-wide, like ESXi)
mkdir -p /etc/libvirt/qemu
[[ -f /etc/libvirt/qemu.conf ]] && \
    sed -i 's/#user = "root"/user = "root"/'   /etc/libvirt/qemu.conf && \
    sed -i 's/#group = "root"/group = "root"/' /etc/libvirt/qemu.conf || true

systemctl restart libvirtd
success "libvirtd configured and running."

# ── Default network – use bridge instead of NAT ──────────────────────────────
section "Configuring libvirt networks"

# Destroy libvirt's default NAT network (we prefer the bridge)
virsh net-destroy default 2>/dev/null || true
virsh net-autostart default --disable 2>/dev/null || true
virsh net-undefine default 2>/dev/null || true
success "Default NAT network removed."

# Define a bridged network so VMs automatically use br0
if ! virsh net-info bridged-network &>/dev/null; then
    virsh net-define /dev/stdin << EOF
<network>
  <name>bridged-network</name>
  <forward mode="bridge"/>
  <bridge name="${BRIDGE_NAME}"/>
</network>
EOF
    virsh net-autostart bridged-network
    virsh net-start    bridged-network
    success "Bridged network 'bridged-network' created and started."
else
    success "Bridged network already defined."
fi

# ── Storage pools ─────────────────────────────────────────────────────────────
section "Configuring storage pools"

# Default pool — VM disk images
mkdir -p /var/lib/libvirt/images
if ! virsh pool-info default &>/dev/null; then
    virsh pool-define-as default dir --target /var/lib/libvirt/images
    virsh pool-autostart default
    virsh pool-start default
    success "Default storage pool created: /var/lib/libvirt/images"
else
    virsh pool-autostart default 2>/dev/null || true
    virsh pool-start default 2>/dev/null || true
    success "Default storage pool already defined."
fi

# ISO pool — store installation media
mkdir -p /var/lib/libvirt/isos
if ! virsh pool-info isos &>/dev/null; then
    virsh pool-define-as isos dir --target /var/lib/libvirt/isos
    virsh pool-autostart isos
    virsh pool-start isos
    success "ISO storage pool created: /var/lib/libvirt/isos"
else
    success "ISO storage pool already defined."
fi

chmod 711 /var/lib/libvirt/images /var/lib/libvirt/isos

# ── Cockpit (web UI) ──────────────────────────────────────────────────────────
section "Configuring Cockpit web UI"

systemctl enable --now cockpit.socket

# Open Cockpit in the firewall if nftables/iptables is active
if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q 'filter'; then
    nft add rule inet filter input tcp dport 9090 accept 2>/dev/null || true
fi
if command -v ufw &>/dev/null && ufw status | grep -q 'active'; then
    ufw allow 9090/tcp comment "Cockpit KVM management" || true
fi
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=cockpit 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

success "Cockpit enabled on port 9090."

# ── User group membership ─────────────────────────────────────────────────────
section "Configuring user permissions"

# Add the invoking user (or first non-root user) to libvirt + kvm groups
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
    # Fall back to first user with UID >= 1000
    TARGET_USER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
fi

if [[ -n "$TARGET_USER" ]]; then
    usermod -aG libvirt,kvm "$TARGET_USER"
    success "Added ${TARGET_USER} to libvirt and kvm groups."
    warn "Log out and back in (or run 'newgrp libvirt') for group changes to take effect."
else
    warn "No non-root user found — add yourself to libvirt and kvm groups manually."
fi

# ── IOMMU / PCI passthrough hint ─────────────────────────────────────────────
section "IOMMU / PCI passthrough (optional)"

GRUB_FILE=/etc/default/grub
if [[ -f "$GRUB_FILE" ]]; then
    if grep -q 'intel_iommu=on\|amd_iommu=on' "$GRUB_FILE"; then
        success "IOMMU already enabled in GRUB."
    else
        if [[ "$CPU_VIRT" == "vmx" ]]; then
            IOMMU_PARAM="intel_iommu=on iommu=pt"
        else
            IOMMU_PARAM="amd_iommu=on iommu=pt"
        fi
        # Safely append to GRUB_CMDLINE_LINUX_DEFAULT
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAM} /" "$GRUB_FILE"
        update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        warn "IOMMU enabled in GRUB (${IOMMU_PARAM}). A reboot is required for PCI passthrough."
    fi
fi

# ── Final verification ────────────────────────────────────────────────────────
section "Verification"

echo ""
info "KVM module status:"
lsmod | grep kvm || warn "KVM modules not loaded — reboot may be required."

echo ""
info "libvirtd status:"
systemctl is-active libvirtd && success "libvirtd is running." || warn "libvirtd is NOT running."

echo ""
info "Cockpit status:"
systemctl is-active cockpit.socket && success "cockpit.socket is active." || warn "cockpit.socket is NOT active."

echo ""
info "Storage pools:"
virsh pool-list --all

echo ""
info "Networks:"
virsh net-list --all

echo ""
info "Running kvm-ok:"
kvm-ok 2>/dev/null || info "(kvm-ok not available — check dmesg for KVM errors)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  KVM Hypervisor Installation Complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Cockpit Web UI${RESET} (like ESXi web client):"
echo -e "    https://${HOST_IP}:9090"
echo ""
echo -e "  ${BOLD}Login${RESET}: use any local system user account"
echo -e "           (root or a user in the 'sudo' group)"
echo ""
echo -e "  ${BOLD}VM disk images${RESET} : /var/lib/libvirt/images/"
echo -e "  ${BOLD}ISO / install media${RESET}: /var/lib/libvirt/isos/"
echo ""
echo -e "  ${BOLD}Quick CLI commands${RESET}:"
echo -e "    virsh list --all          # list all VMs"
echo -e "    virsh start <vm>          # power on a VM"
echo -e "    virsh shutdown <vm>       # graceful shutdown"
echo -e "    virsh destroy <vm>        # force off"
echo -e "    virsh console <vm>        # serial console"
echo -e "    virt-install ...          # create a new VM"
echo ""
echo -e "  ${BOLD}Create a VM example${RESET}:"
echo -e "    virt-install \\"
echo -e "      --name myvm \\"
echo -e "      --ram 2048 \\"
echo -e "      --vcpus 2 \\"
echo -e "      --disk path=/var/lib/libvirt/images/myvm.qcow2,size=40 \\"
echo -e "      --cdrom /var/lib/libvirt/isos/debian-13-amd64.iso \\"
echo -e "      --network network=bridged-network \\"
echo -e "      --os-variant debian12 \\"
echo -e "      --graphics vnc,listen=0.0.0.0"
echo ""
if [[ "$USE_NM" == "active" ]]; then
    echo -e "  ${YELLOW}${BOLD}NOTE${RESET}: Bridge is managed by NetworkManager."
    echo -e "  Network connectivity will resume automatically on ${BRIDGE_NAME}."
else
    echo -e "  ${YELLOW}${BOLD}ACTION REQUIRED${RESET}: Reboot or run the following to activate the bridge:"
    echo -e "    ifdown ${DEFAULT_IF} && ifup ${BRIDGE_NAME}"
fi
echo ""
echo -e "  ${YELLOW}${BOLD}Reboot recommended${RESET} to ensure IOMMU and all kernel changes take effect."
echo ""
