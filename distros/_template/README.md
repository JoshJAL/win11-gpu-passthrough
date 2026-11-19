# Distro: <ID> (template)

Copy this folder to `distros/<ID>/`, where `<ID>` is the `ID=` line of `/etc/os-release` (lowercase;
`./handoff.sh` prints the ids it tried). Write `distro.sh` (see the comments in `distros/_template/distro.sh`
and the finished `distros/arch/distro.sh`), fill in the sections below, delete this line, and keep personal
data out.

**Status:** untested | partly tested (tier N) | tested. Tested reports: see `COMPATIBILITY.md`.

## Steps that differ

What is different from `distros/arch/`: package names and repos, how the firewall is managed, how the
kernel command line is edited, SELinux/AppArmor notes, where libvirt keeps its images.

## Known issues

Symptoms seen on this distro, with the cause if known. Link a `reports/` file for each one.
