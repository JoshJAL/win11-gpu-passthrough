# Omarchy (ID=omarchy, ID_LIKE=arch): everything is Arch's, except how the kernel command line is edited.
# shellcheck source=../arch/distro.sh
. "$(dirname "${BASH_SOURCE[0]}")/../arch/distro.sh"

distro_iommu_cmdline_hint() {
  echo "Omarchy boots with Limine; add '$1 iommu=pt' to a KERNEL_CMDLINE[default]+= line in /etc/default/limine, run 'sudo limine-update', reboot, run ./detect.sh again"
}
