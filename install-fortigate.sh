#!/usr/bin/env bash
# FortiOS KVM Install Script
# Tested on: Debian 13, libvirt + QEMU/KVM
# Image: fortios.qcow2 (FortiGate VM64-KVM)
# Usage: bash install-fortigate.sh

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
VM_NAME="fortigate"
IMAGE_SRC="$HOME/fortios.qcow2"
IMAGE_DIR="/var/lib/libvirt/images"
IMAGE_DST="$IMAGE_DIR/fortios.qcow2"
RAM_MB=2048          # 2 GB RAM (minimum for FortiGate VM)
VCPUS=2              # 2 vCPUs
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ -f "$IMAGE_SRC" ]] || die "Source image not found: $IMAGE_SRC"
command -v virt-install &>/dev/null || die "virt-install not found (install virtinst)"
command -v virsh       &>/dev/null || die "virsh not found"

if virsh list --all --name 2>/dev/null | grep -q "^${VM_NAME}$"; then
    die "VM '$VM_NAME' already exists. Remove it first with:\n  virsh destroy $VM_NAME; virsh undefine $VM_NAME --remove-all-storage"
fi

# ── Storage: create image directory and copy disk ─────────────────────────────
info "Preparing disk image..."
sudo mkdir -p "$IMAGE_DIR"
if [[ ! -f "$IMAGE_DST" ]]; then
    sudo cp "$IMAGE_SRC" "$IMAGE_DST"
    sudo chmod 640 "$IMAGE_DST"
    sudo chown root:kvm "$IMAGE_DST" 2>/dev/null || true
fi
info "Disk: $IMAGE_DST"

# ── Network: define the default NAT network if missing ───────────────────────
if ! virsh net-info default &>/dev/null; then
    info "Creating 'default' NAT network (192.168.122.0/24)..."
    cat > /tmp/libvirt-default-net.xml <<'EOF'
<network>
  <name>default</name>
  <forward mode="nat"/>
  <bridge name="virbr0" stp="on" delay="0"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.122.2" end="192.168.122.254"/>
    </dhcp>
  </ip>
</network>
EOF
    virsh net-define  /tmp/libvirt-default-net.xml
    virsh net-autostart default
    virsh net-start   default
    rm /tmp/libvirt-default-net.xml
else
    virsh net-start default 2>/dev/null || true
fi

# Optionally create an isolated LAN network for port2
if ! virsh net-info fortigate-lan &>/dev/null; then
    info "Creating isolated 'fortigate-lan' network for port2..."
    cat > /tmp/libvirt-fgt-lan.xml <<'EOF'
<network>
  <name>fortigate-lan</name>
  <bridge name="virbr1" stp="on" delay="0"/>
</network>
EOF
    virsh net-define  /tmp/libvirt-fgt-lan.xml
    virsh net-autostart fortigate-lan
    virsh net-start   fortigate-lan
    rm /tmp/libvirt-fgt-lan.xml
fi

# ── Install VM ────────────────────────────────────────────────────────────────
info "Installing FortiGate VM (this imports the disk, no ISO needed)..."

virt-install \
    --name          "$VM_NAME"                     \
    --memory        "$RAM_MB"                      \
    --vcpus         "$VCPUS"                       \
    --cpu           host-passthrough               \
    --os-variant    generic                        \
    --disk          "path=$IMAGE_DST,format=qcow2,bus=ide,cache=none" \
    --network       "network=default,model=e1000"  \
    --network       "network=fortigate-lan,model=e1000" \
    --graphics      none                           \
    --serial        pty                            \
    --console       "pty,target_type=serial"       \
    --noautoconsole                                \
    --import                                       \
    --boot          hd

info "VM '$VM_NAME' defined and started."

# ── Print connection info ─────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  FortiGate VM is booting."
echo ""
echo "  Serial console (initial config):"
echo "    virsh console $VM_NAME"
echo "    (Press Ctrl+] to detach)"
echo ""
echo "  Default credentials:"
echo "    Username: admin"
echo "    Password: (blank — press Enter)"
echo ""
echo "  After boot, find the management IP:"
echo "    virsh console $VM_NAME"
echo "    > get system interface | grep port1 -A5"
echo ""
echo "  Or check via DHCP leases:"
echo "    virsh net-dhcp-leases default"
echo ""
echo "  Web GUI (HTTPS):"
echo "    https://<port1-ip>"
echo "══════════════════════════════════════════════════════"
