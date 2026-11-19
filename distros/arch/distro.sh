# Arch Linux: the packages, firewall rules and bootloader hint install.sh and detect.sh need.
# Sourced by install.sh (user half, and as root through pkexec for the firewall step) and by
# detect.sh. Keep it to function and array definitions: nothing may run at source time.
# The contract every distro.sh keeps is documented in distros/_template/distro.sh.

DISTRO_PACMAN_PKGS=(qemu-desktop qemu-hw-usb-host qemu-hw-usb-redirect libvirt virt-manager virt-viewer
  edk2-ovmf swtpm dnsmasq libvirt-python)
DISTRO_AUR_PKGS=(looking-glass virtio-win)
DISTRO_UFW_RULES=(  # "<tuple regex in /etc/ufw/user.rules> => <ufw arguments>"  (Omarchy's ufw drops VM DHCP/DNS/NAT)
  'allow udp 67 .* in_virbr0( |$) => allow in on virbr0 to any port 67 proto udp comment libvirt-dhcp'
  'allow any 53 .* in_virbr0( |$) => allow in on virbr0 to any port 53 comment libvirt-dns'
  'route:allow any any .* in_virbr0( |$) => route allow in on virbr0 comment libvirt-vm-out'
  'route:allow any any .* out_virbr0( |$) => route allow out on virbr0 comment libvirt-vm-in'
)

# Install the packages. Runs as the normal user and asks for root itself (pkexec).
distro_install_packages() {
  echo "Installing packages (pacman, then AUR)…"
  pkexec pacman -S --needed --noconfirm "${DISTRO_PACMAN_PKGS[@]}"
  command -v yay >/dev/null || die "yay not found; install ${DISTRO_AUR_PKGS[*]} from the AUR yourself, then re-run without --packages"
  yay -S --needed --noconfirm --sudo pkexec "${DISTRO_AUR_PKGS[@]}"
}

# Let the VM network (DHCP, DNS, routing on virbr0) through the firewall. Runs as root.
distro_firewall_virbr0() {
  local r a
  if command -v ufw >/dev/null && grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    for r in "${DISTRO_UFW_RULES[@]}"; do
      grep -qE "^### tuple ### ${r%% => *}" /etc/ufw/user.rules || { read -ra a <<<"${r#* => }"; ufw "${a[@]}"; }
    done
  fi
}

# Print one line per firewall rule that is missing (what install.sh --check reports as drift).
# Prints nothing when the firewall is off or every rule is there. Read-only, no root needed.
distro_firewall_check() {
  local r
  command -v ufw >/dev/null && grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || return 0
  for r in "${DISTRO_UFW_RULES[@]}"; do
    grep -qE "^### tuple ### ${r%% => *}" /etc/ufw/user.rules 2>/dev/null || echo "ufw ${r#* => }"
  done
}

# Print how to turn the IOMMU on in this distro's boot setup. $1 is the kernel flag
# (intel_iommu=on, amd_iommu=on, or both spelled out). detect.sh prints it after "fix 2: ".
distro_iommu_cmdline_hint() {
  echo "add '$1 iommu=pt' to the kernel command line in your bootloader configuration, regenerate its config, reboot, run ./detect.sh again"
}
