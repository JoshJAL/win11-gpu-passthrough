# Distro: Arch Linux

`distro.sh` holds the packages, the ufw rules for `virbr0` and the generic IOMMU boot hint. This is the
reference implementation: derivatives with `ID_LIKE=arch` use it (see `distros/omarchy/`).

**Status:** the code is exactly what ran on the machine the bundle was built on (an Omarchy install, which
is Arch). Plain Arch has not been reported separately. Tested reports: see `COMPATIBILITY.md` (rows with
this distro or a derivative).

## Steps that differ

- Packages: `pacman` for the official ones, `yay` for the AUR ones (`looking-glass`, `virtio-win`).
  `install.sh --packages` runs both; install `yay` first.
- Firewall: when ufw is enabled, `install.sh` adds the four `virbr0` rules (DHCP, DNS, route in, route
  out); without them the VM gets no network.
- Bootloader: edit the kernel command line for your bootloader (GRUB, systemd-boot, Limine, ...). The hint
  `detect.sh` prints is generic.

## Known issues

None recorded.
