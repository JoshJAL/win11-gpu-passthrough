# TEMPLATE for a new distro. Copy this folder to distros/<ID>/ where <ID> is the ID= line of
# /etc/os-release (lowercase, [a-z0-9._-]), fill in the four functions and the arrays, delete this
# paragraph, then run ./install.sh --check and ./detect.sh on that distro. Look at distros/arch/ for
# a finished one. If your distro is a derivative (ID_LIKE=...), you can instead source the parent's
# distro.sh and override only what differs, the way distros/omarchy/ does.
#
# Rules: this file is sourced by bash, once as your user and once as root (pkexec), and by detect.sh.
# Define functions and arrays only; nothing may run at source time. Do not read or print anything
# personal. Root-only work goes in distro_firewall_virbr0, nowhere else.

# Package names for: QEMU with USB host/redirect, libvirt, virt-manager, virt-viewer, OVMF (UEFI),
# swtpm (TPM), dnsmasq, the libvirt python bindings, Looking Glass (client + host), virtio-win ISO.
DISTRO_PACKAGES=()

# Install them. Runs as the normal user; use pkexec for the root part (never plain sudo).
# `die <message>` is available. Leave a comment for packages that need a third-party repo.
distro_install_packages() {
  die "distros/<ID>/distro.sh: distro_install_packages is not written yet"
}

# Let the VM network through the firewall: DHCP (udp 67) and DNS (53) in on virbr0, and routing
# in and out of virbr0. Runs as root. Do nothing when no firewall is active.
distro_firewall_virbr0() {
  :
}

# Print one line per missing firewall rule, nothing when none are missing or no firewall is active.
# Runs as the normal user, read-only. install.sh --check reports each line as drift.
distro_firewall_check() {
  :
}

# Print how to enable the IOMMU in this distro's bootloader. $1 is the flag to add
# (intel_iommu=on or amd_iommu=on). detect.sh prints the result after "fix 2: ".
distro_iommu_cmdline_hint() {
  echo "add '$1 iommu=pt' to the kernel command line in your bootloader configuration, regenerate its config, reboot, run ./detect.sh again"
}
