# Distro: Omarchy

Arch-based (`ID=omarchy`, `ID_LIKE=arch`). `distro.sh` sources `distros/arch/distro.sh` and overrides only the
bootloader hint (Omarchy boots with Limine and keeps the kernel command line in `/etc/default/limine`).

**Status:** the machine the bundle was built on. Tested reports: see `COMPATIBILITY.md` (rows with distro
`omarchy`).

## Steps that differ

- Enabling the IOMMU: add the flag to a `KERNEL_CMDLINE[default]+=` line in `/etc/default/limine`, run
  `limine-update`, reboot.
- The default firewall is ufw and drops VM DHCP/DNS/NAT until the `virbr0` rules from `distros/arch/` are added;
  `install.sh` does it.
- The desktop is Hyprland: see `desktops/hyprland/`.

## Known issues

None recorded.
