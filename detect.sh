#!/bin/bash
# Inspect this machine and propose a /etc/win11-vm.conf for the win11 GPU-passthrough VM.
#
#   ./detect.sh > win11-vm.conf    config proposal on stdout, hardware report on stderr
#   ./detect.sh --profile          machine profile only: allowlisted KEY=VALUE lines on stdout, nothing on
#                                  stderr (hardware + distro, no user/host names, serials or UUIDs); this
#                                  is what ./handoff.sh and ./verify.sh read
#   ./detect.sh -h | --help        this text
#
# Strictly read-only: it only reads /sys, /proc, /etc and runs lspci/findmnt/id/nvidia-smi.
# It never writes a file and needs no root. Report lines on stderr start with one of
#   GO      fine           WARN   works, but read it           NO-GO  blocker      INFO  context
# The last line is the verdict. Exit status: 0 = no NO-GO finding, 1 = at least one.
# Review the proposal, then install it with:  ./install.sh --conf ./win11-vm.conf
set -u
PROFILE=0
B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/bundle.sh
. "$B/lib/bundle.sh"

case ${1:-} in
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --profile) PROFILE=1 ;;
  "") ;;
  *) echo "detect.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

SYS=/sys
UDEV_RULES_DIR=${UDEV_RULES_DIR:-/etc/udev/rules.d}   # overridable only so the rule scan can be tested
IMG_DIR=/var/lib/libvirt/images
SYS_CONF=/etc/win11-vm.conf

# Defaults that do not depend on the hardware.
VM_NAME=win11
USB_VENDORS="1050"
USB_STORAGE=1
LG_SHM_MB=128

n_nogo=0 n_warn=0 nogo_msgs=()
say() {  # say <GO|WARN|NO-GO|INFO> <message>   (--profile prints no report; it only counts)
  case $1 in NO-GO) n_nogo=$((n_nogo + 1)); nogo_msgs+=("$2") ;; WARN) n_warn=$((n_warn + 1)) ;; esac
  (( PROFILE )) || printf '%-6s %s\n' "$1" "$2" >&2
}
# The kernel command line carries disk and encryption identifiers: show it with those values removed.
redact_cmdline() {
  sed -E 's/(^| )((rd\.)?luks\.[a-z.]+|root|cryptdevice|cryptkey|resume|resume_offset)=[^ ]*/\1\2=<redacted>/g;
          s/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g'
}
rd() {  # rd <file>: first line of a file, empty if unreadable
  local v=
  [[ -r $1 ]] && read -r v <"$1" 2>/dev/null
  printf '%s' "$v"
}
have() { command -v "$1" >/dev/null 2>&1; }
pci_re='^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$'

# Name of a PCI device from the PCI database ("Vendor Device"), empty if lspci is missing.
pci_vendor() { have lspci && lspci -vmm -s "$1" 2>/dev/null | sed -n 's/^Vendor:[[:space:]]*//p' | head -n1; }
pci_device() { have lspci && lspci -vmm -s "$1" 2>/dev/null | sed -n 's/^Device:[[:space:]]*//p' | head -n1; }
pci_desc() {  # pci_desc <addr>
  local v d
  v=$(pci_vendor "$1") d=$(pci_device "$1")
  if [[ -n $d ]]; then echo "$v $d"; else echo "[$(rd "$SYS/bus/pci/devices/$1/vendor" | sed 's/^0x//'):$(rd "$SYS/bus/pci/devices/$1/device" | sed 's/^0x//')]"; fi
}
drv_of() { local l; l=$(readlink "$SYS/bus/pci/devices/$1/driver" 2>/dev/null) && echo "${l##*/}"; }

# ------------------------------------------------------------------------------------------
# User, kernel, CPU (item 9, and VM_USER)
# ------------------------------------------------------------------------------------------
VM_USER=${SUDO_USER:-$(id -un)}
if [[ $VM_USER == root ]]; then
  say WARN "running as root: VM_USER=root is rejected by install.sh; run ./detect.sh as your normal login user"
fi

kernel=$(uname -r)
cpu_vendor=$(sed -n 's/^vendor_id[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n1)
cpu_model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n1)
cpu_bits=$(sed -n 's/^address sizes[[:space:]]*:[[:space:]]*\([0-9]*\) bits physical.*/\1/p' /proc/cpuinfo | head -n1)
say INFO "kernel $kernel"
say INFO "CPU: ${cpu_model:-unknown} (${cpu_vendor:-unknown vendor}, ${cpu_bits:-?} physical address bits)"
say INFO "kernel command line: $(rd /proc/cmdline | redact_cmdline)"

# CPU virtualization
if grep -qE '^flags[[:space:]]*:.*[[:space:]](vmx|svm)([[:space:]]|$)' /proc/cpuinfo; then
  say GO "CPU virtualization (vmx/svm) present"
else
  say NO-GO "CPU has no vmx/svm flag: enable Intel VT-x / AMD SVM in the firmware (or this is itself a VM without nested virtualization)"
fi

# ------------------------------------------------------------------------------------------
# 1. IOMMU
# ------------------------------------------------------------------------------------------
iommu_on=0
for g in "$SYS"/kernel/iommu_groups/*; do [[ -e $g ]] && { iommu_on=1; break; }; done
iommu_vendor=other
if [[ $cpu_vendor == GenuineIntel ]] || compgen -G "$SYS/class/iommu/dmar*" >/dev/null; then iommu_vendor=intel; fi
if [[ $cpu_vendor == AuthenticAMD ]] || compgen -G "$SYS/class/iommu/ivhd*" >/dev/null; then iommu_vendor=amd; fi
if (( iommu_on )); then
  ngroups=$(find "$SYS/kernel/iommu_groups" -mindepth 1 -maxdepth 1 | wc -l)
  say GO "IOMMU is on ($ngroups IOMMU groups)"
else
  case $iommu_vendor in intel) flag=intel_iommu=on vtd="Intel VT-d" ;; amd) flag=amd_iommu=on vtd="AMD-Vi (IOMMU)" ;; *) flag="intel_iommu=on (Intel) or amd_iommu=on (AMD)" vtd="VT-d / AMD-Vi" ;; esac
  say NO-GO "IOMMU is off (no IOMMU groups): passthrough is impossible until it is enabled"
  say INFO "fix 1: enable $vtd in the firmware/BIOS setup"
  if distro_id=$(pick_distro "$B") && load_distro "$B" "$distro_id" && declare -F distro_iommu_cmdline_hint >/dev/null; then
    say INFO "fix 2: $(distro_iommu_cmdline_hint "$flag")"
  else
    say INFO "fix 2: add '$flag iommu=pt' to the kernel command line in your bootloader configuration, regenerate its config, reboot, run ./detect.sh again"
  fi
fi

# ------------------------------------------------------------------------------------------
# 2. Find the discrete GPU
# ------------------------------------------------------------------------------------------
gpus=() tier1=() tier2=()
for d in "$SYS"/bus/pci/devices/*; do
  a=${d##*/}
  c=$(rd "$d/class")
  [[ $c == 0x0300* || $c == 0x0302* ]] || continue
  gpus+=("$a")
  [[ $(rd "$d/boot_vga") == 1 ]] && continue
  ven=$(rd "$d/vendor")
  if [[ $ven == 0x10de || $ven == 0x1002 ]]; then tier1+=("$a"); else tier2+=("$a"); fi
done
cands=("${tier1[@]}" "${tier2[@]}")
GPU= others=
if (( ${#gpus[@]} == 0 )); then
  say NO-GO "no PCI display controller (class 0x0300/0x0302) found"
elif (( ${#gpus[@]} == 1 )); then
  say NO-GO "only one GPU (${gpus[0]} $(pci_desc "${gpus[0]}")): passing it through would leave the host without a display. A second GPU (iGPU or another card) is required"
elif (( ${#cands[@]} == 0 )); then
  say NO-GO "every GPU is flagged as the boot VGA device (boot_vga=1), so there is no secondary GPU to pass through: ${gpus[*]}"
  say INFO "if your discrete GPU is the firmware's primary display, switch the primary display to the integrated GPU in the firmware"
else
  GPU=${cands[0]}
  say GO "passthrough GPU: $GPU $(pci_desc "$GPU") (driver: $(drv_of "$GPU" || true))"
  for a in "${gpus[@]}"; do
    [[ $a == "$GPU" ]] && continue
    [[ $(rd "$SYS/bus/pci/devices/$a/boot_vga") == 1 ]] && role="host GPU (boot_vga)" || { role="other GPU"; others+="$a "; }
    say INFO "other GPU: $a $(pci_desc "$a") [$role]"
  done
  [[ -n $others ]] && say WARN "more than one candidate dGPU; picked $GPU, ignoring: ${others% }. Edit GPU_PCI/GPU_NAME in the proposal if you want a different one"
fi

# ------------------------------------------------------------------------------------------
# 3. IOMMU group of the dGPU
# ------------------------------------------------------------------------------------------
gpu_pci=
if [[ -n $GPU ]]; then
  slot=${GPU%.*}
  members=()
  if [[ -d $SYS/bus/pci/devices/$GPU/iommu_group/devices ]]; then
    for m in "$SYS/bus/pci/devices/$GPU/iommu_group/devices"/*; do members+=("${m##*/}"); done
  else
    for m in "$SYS/bus/pci/devices/$slot".*; do members+=("${m##*/}"); done
    (( iommu_on )) && say NO-GO "$GPU has no IOMMU group although the IOMMU is on"
  fi
  fn=() bridges=() bad=()
  for m in "${members[@]}"; do
    [[ $m == "$GPU" ]] && continue
    mc=$(rd "$SYS/bus/pci/devices/$m/class")
    if [[ ${m%.*} == "$slot" ]]; then fn+=("$m")
    elif [[ $mc == 0x0604* ]]; then bridges+=("$m")
    else bad+=("$m")
    fi
  done
  gpu_pci=$GPU
  [[ ${#fn[@]} -gt 0 ]] && gpu_pci+=" $(printf '%s\n' "${fn[@]}" | sort | tr '\n' ' ')"
  gpu_pci=${gpu_pci% }
  if (( ${#bad[@]} )); then
    for m in "${bad[@]}"; do say NO-GO "IOMMU group of $GPU also contains $m $(pci_desc "$m") (class $(rd "$SYS/bus/pci/devices/$m/class")): the group is not isolated"; done
    say INFO "all devices in a group must go to the VM together; an ACS override patch could split it but is out of scope here"
  else
    say GO "IOMMU group of $GPU is isolated: GPU_PCI=\"$gpu_pci\""
  fi
  for m in "${fn[@]}"; do say INFO "group member $m $(pci_desc "$m") (class $(rd "$SYS/bus/pci/devices/$m/class"), same slot as the GPU, passed through)"; done
  for m in "${bridges[@]}"; do say INFO "group member $m is a PCI bridge, not passed through"; done
fi

# ------------------------------------------------------------------------------------------
# 4. GPU_NAME
# ------------------------------------------------------------------------------------------
GPU_NAME=
if [[ -n $GPU ]]; then
  if [[ $(drv_of "$GPU") == nvidia ]] && have nvidia-smi; then
    GPU_NAME=$(timeout 10 nvidia-smi --query-gpu=name --format=csv,noheader -i "$GPU" 2>/dev/null | head -n1)
    [[ -n $GPU_NAME ]] && say INFO "GPU_NAME from nvidia-smi: $GPU_NAME (Windows normally shows the same name)"
  fi
  if [[ -z $GPU_NAME ]]; then
    ven=$(pci_vendor "$GPU") dev=$(pci_device "$GPU")
    if [[ -n $dev ]]; then
      inner=$dev
      [[ $dev == *\[*\]* ]] && { inner=${dev#*\[}; inner=${inner%%\]*}; }   # e.g. "CHIP [Marketing Name]"
      case $(rd "$SYS/bus/pci/devices/$GPU/vendor") in
        0x10de) pre=NVIDIA ;; 0x1002) pre=AMD ;; 0x8086) pre=Intel ;; *) pre= ;;
      esac
      if [[ -n $pre && $inner != "$pre"* ]]; then GPU_NAME="$pre $inner"; else GPU_NAME=$inner; fi
    else
      GPU_NAME="GPU $(rd "$SYS/bus/pci/devices/$GPU/vendor" | sed 's/^0x//'):$(rd "$SYS/bus/pci/devices/$GPU/device" | sed 's/^0x//')"
      have lspci || say INFO "lspci (pciutils) is not installed, so the GPU name could not be looked up"
    fi
    say WARN "GPU_NAME must match the name Windows Device Manager shows for the GPU; confirm after installing the GPU driver in Windows (proposed: \"$GPU_NAME\")"
  fi
  # install.sh rejects " ` $ \ in values; control characters would break the file too.
  GPU_NAME=$(printf '%s' "$GPU_NAME" | tr -d '"`$\\[:cntrl:]' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
fi

# ------------------------------------------------------------------------------------------
# 5. IOMMU_LIMIT
# ------------------------------------------------------------------------------------------
IOMMU_LIMIT= mgaw_min=
if (( iommu_on )); then
  if [[ $iommu_vendor == intel ]]; then
    nunits=0
    for u in "$SYS"/class/iommu/dmar*/intel-iommu/cap; do
      [[ -r $u ]] || continue
      cap=$(rd "$u")
      [[ $cap =~ ^[0-9a-fA-F]+$ ]] || continue
      mg=$(( ((16#$cap >> 16) & 0x3f) + 1 ))
      nunits=$((nunits + 1))
      if [[ -z $mgaw_min ]] || (( mg < mgaw_min )); then mgaw_min=$mg; fi
    done
    if [[ -z $mgaw_min || -z $cpu_bits ]]; then
      say WARN "could not read the Intel IOMMU address width (dmar cap) or the CPU address bits; IOMMU_LIMIT left empty. If QEMU fails with 'vfio: DMA mapping failed', set IOMMU_LIMIT to 39 or 48"
    elif (( mgaw_min < cpu_bits )); then
      IOMMU_LIMIT=$mgaw_min
      say INFO "IOMMU supports $mgaw_min address bits (lowest of $nunits DMAR units) but the CPU has $cpu_bits: IOMMU_LIMIT=$mgaw_min caps the guest address space, otherwise QEMU dies with 'vfio: DMA mapping failed'"
    else
      say GO "IOMMU address width ($mgaw_min bits) covers the CPU ($cpu_bits bits): IOMMU_LIMIT not needed"
    fi
  elif [[ $iommu_vendor == amd ]]; then
    say WARN "AMD IOMMU address width not checked; if the VM fails with 'vfio: DMA mapping failed', set IOMMU_LIMIT (try 39/48) - best-effort"
  else
    say WARN "unknown CPU vendor, IOMMU address width not checked; if the VM fails with 'vfio: DMA mapping failed', set IOMMU_LIMIT (try 39/48)"
  fi
fi

# ------------------------------------------------------------------------------------------
# 6. Display wiring
# ------------------------------------------------------------------------------------------
n_dgpu=0 n_other=0
for c in "$SYS"/class/drm/card*-*; do
  [[ -r $c/status ]] || continue
  conn=${c##*/}; conn=${conn#card*-}
  real=$(readlink -f "$c") || continue
  owner_path=${real%%/drm/*}
  owner=${owner_path##*/}
  st=$(rd "$c/status")
  drv=$(readlink "$owner_path/driver" 2>/dev/null) && drv=${drv##*/} || drv=
  if [[ $owner =~ $pci_re ]]; then desc="PCI $owner ($(pci_desc "$owner"))"; else desc="non-PCI device $owner (USB/platform, e.g. evdi/DisplayLink)"; fi
  [[ -n $drv ]] && desc+=" driver $drv"
  [[ $st == connected ]] || continue
  if [[ -n $GPU && $owner == "$GPU" ]]; then
    n_dgpu=$((n_dgpu + 1))
    say WARN "monitor on the passthrough GPU: $conn ($desc); it goes dark while Windows has the GPU; Looking Glass shows Windows in a window instead"
  else
    n_other=$((n_other + 1))
    say INFO "connected display $conn on $desc"
  fi
done
if [[ -n $GPU ]]; then
  gdrv=$(drv_of "$GPU")
  if [[ $gdrv == vfio-pci ]]; then
    say INFO "$GPU is bound to vfio-pci (already handed over), so its connectors are not visible; cannot tell whether a monitor is wired to it. Every display listed above is on another device"
  elif (( n_dgpu == 0 )); then
    say INFO "no connected display found on $GPU (driver ${gdrv:-none})"
  fi
  if (( n_dgpu > 0 && n_other == 0 )); then
    say NO-GO "the only connected displays are on the passthrough GPU: the host would have no display once Windows takes the GPU"
  elif (( n_other > 0 )); then
    say GO "host keeps $n_other display(s) on other devices (iGPU/laptop panel/evdi) while the GPU is passed through"
  else
    say WARN "no connected display found on any other GPU; if your monitors are wired to the passthrough GPU the host will lose them"
  fi
fi

# ------------------------------------------------------------------------------------------
# 7. Host checks
# ------------------------------------------------------------------------------------------
probe=$IMG_DIR
while [[ ! -e $probe && $probe != / ]]; do probe=${probe%/*}; [[ -z $probe ]] && probe=/; done
if have findmnt; then fstype=$(findmnt -no FSTYPE -T "$probe" 2>/dev/null | head -n1); else fstype=; fi
if [[ -z $fstype ]]; then
  say INFO "filesystem of $IMG_DIR could not be determined"
else
  free=$(df -BG --output=avail "$probe" 2>/dev/null | sed -n '2s/[^0-9]//gp')
  say INFO "$IMG_DIR is on $fstype (via $probe)${free:+, ${free} GiB free (a Windows 11 disk image needs roughly 80 or more)}"
  [[ $fstype == btrfs ]] && say WARN "$IMG_DIR is on btrfs: the disk image must be NOCOW (create-vm.sh does chattr +C); btrfs + cache=none on a CoW file gave checksum failures"
fi

if grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
  say WARN "ufw is enabled: install.sh adds virbr0 DHCP/DNS/route rules, otherwise the VM gets no network"
fi

if [[ -e /dev/kvm ]]; then
  kvm_grp=$(stat -c %G /dev/kvm) kvm_mode=$(stat -c %a /dev/kvm)
  if [[ $kvm_grp == kvm ]] && (( (8#$kvm_mode & 6) == 6 )); then
    say GO "/dev/kvm is $(stat -c %U /dev/kvm):$kvm_grp $kvm_mode"
  else
    say WARN "/dev/kvm is $(stat -c %U /dev/kvm):$kvm_grp $kvm_mode, expected root:kvm 666 on Arch; a udev rule with a bare GROUP= assignment can cause this (see the udev rule scan)"
  fi
else
  say WARN "/dev/kvm does not exist: the kvm_intel/kvm_amd module is not loaded (libvirt loads it) or virtualization is disabled in the firmware"
fi

if id -nG "$VM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
  say GO "$VM_USER is in the libvirt group"
else
  say WARN "$VM_USER is not in the libvirt group (or the group does not exist yet): install.sh --packages adds you; log out and back in afterwards"
fi

mem_kb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\) kB.*/\1/p' /proc/meminfo)
if [[ -n $mem_kb ]]; then
  say INFO "RAM: $(( (mem_kb + 524288) / 1048576 )) GiB total; give the VM about half (about $(( (mem_kb / 2 + 524288) / 1048576 )) GiB)"
fi

# ------------------------------------------------------------------------------------------
# 8. Stray udev rules (assignment with no match key)
# ------------------------------------------------------------------------------------------
assign_re='(^|,)[[:space:]]*(GROUP|MODE|OWNER|RUN|TAG|ENV|SYMLINK|ATTR|SYSCTL|OPTIONS|NAME)(\{[^}]*\})?[-+:]?='
n_stray=0
for f in "$UDEV_RULES_DIR"/*.rules; do
  [[ -f $f ]] || continue
  ln=0 prev_bs=0
  while IFS= read -r line || [[ -n $line ]]; do
    ln=$((ln + 1))
    t=${line#"${line%%[![:space:]]*}"}
    t=${t%"${t##*[![:space:]]}"}
    [[ -z $t ]] && continue
    if [[ $t != \#* && $prev_bs == 0 && $t != *"=="* && $t != *"!="* && $t =~ $assign_re ]]; then
      n_stray=$((n_stray + 1))
      say WARN "$f:$ln has an assignment but no match key ('$t'): it applies to every device; this broke /dev/kvm permissions on the original machine - usually a rule split across two lines without a trailing '\\'"
    fi
    [[ $t == *\\ ]] && prev_bs=1 || prev_bs=0
  done <"$f"
done
(( n_stray == 0 )) && say GO "no match-less udev rules in $UDEV_RULES_DIR"

# ------------------------------------------------------------------------------------------
# --profile: allowlisted KEY=VALUE lines instead of the proposal (stdout), no report (stderr)
# ------------------------------------------------------------------------------------------
if (( PROFILE )); then
  pv() { printf '%s' "$*" | tr -d '[:cntrl:]' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'; }
  emit() { printf '%s=%s\n' "$1" "$(pv "${2:-}")"; }
  vendor_key() {  # vendor_key <pci addr>
    case $(rd "$SYS/bus/pci/devices/$1/vendor") in 0x10de) echo nvidia ;; 0x1002) echo amd ;; 0x8086) echo intel ;; "") echo unknown ;; *) echo other ;; esac
  }
  gpu_model_of() {  # marketing name of a GPU, "Vendor Name", from the PCI database
    local dev inner pre
    dev=$(pci_device "$1"); [[ -n $dev ]] || { echo unknown; return; }
    inner=$dev; [[ $dev == *\[*\]* ]] && { inner=${dev#*\[}; inner=${inner%%\]*}; }
    case $(rd "$SYS/bus/pci/devices/$1/vendor") in 0x10de) pre=NVIDIA ;; 0x1002) pre=AMD ;; 0x8086) pre=Intel ;; *) pre= ;; esac
    if [[ -n $pre && $inner != "$pre"* ]]; then echo "$pre $inner"; else echo "$inner"; fi
  }
  host_gpu=
  for a in "${gpus[@]}"; do [[ $a != "$GPU" && $(rd "$SYS/bus/pci/devices/$a/boot_vga") == 1 ]] && { host_gpu=$a; break; }; done
  if [[ -z $host_gpu ]]; then for a in "${gpus[@]}"; do [[ $a != "$GPU" ]] && { host_gpu=$a; break; }; done; fi

  bootloader=unknown
  if [[ -e /etc/default/limine || -e /boot/limine.conf || -e /boot/limine/limine.conf ]]; then bootloader=limine
  elif compgen -G "/sys/firmware/efi/efivars/LoaderInfo-*" >/dev/null && grep -aqi 'systemd-boot' /sys/firmware/efi/efivars/LoaderInfo-* 2>/dev/null; then bootloader=systemd-boot
  elif [[ -e /boot/grub/grub.cfg || -e /boot/grub2/grub.cfg || -e /etc/default/grub ]]; then bootloader=grub
  elif [[ -e /boot/refind_linux.conf || -d /boot/EFI/refind ]]; then bootloader=refind
  fi
  firewall=none
  if grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then firewall=ufw
  elif have systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then firewall=firewalld
  elif have systemctl && systemctl is-active --quiet nftables 2>/dev/null; then firewall=nftables
  fi
  pkgmgr=unknown
  for m in pacman apt dnf zypper xbps-install apk emerge nix-env; do have "$m" && { pkgmgr=$m; break; }; done
  desk=${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-}}; desk=${desk##*:}; desk=$(printf '%s' "$desk" | tr '[:upper:]' '[:lower:]')
  [[ $desk =~ ^[a-z0-9._-]+$ ]] || desk=unknown
  case $(rd "$SYS/class/dmi/id/chassis_type") in
    8|9|10|14|30|31|32) ff=laptop ;; 3|4|5|6|7|13|15|16|24|35|36) ff=desktop ;; 17|23|28|29) ff=server ;; 1|2|"") ff=unknown ;; *) ff=other ;; esac
  case $cpu_vendor in GenuineIntel) cpuv=intel ;; AuthenticAMD) cpuv=amd ;; *) cpuv=other ;; esac
  isolated=unknown group_size=
  if [[ -n $GPU ]]; then
    if (( ${#bad[@]} )); then isolated=no; else isolated=yes; fi
    group_size=${#members[@]}
  fi
  lg_ver=
  if have looking-glass-client; then lg_ver=$(timeout 5 looking-glass-client --help 2>&1 | sed -n 's/.*Looking Glass (\(.*\))$/\1/p' | head -n1); fi

  emit PROFILE_VERSION 1
  emit DISTRO_ID "$(os_release_val ID)"
  emit DISTRO_ID_LIKE "$(os_release_val ID_LIKE)"
  emit DISTRO_VERSION_ID "$(os_release_val VERSION_ID)"
  emit KERNEL "$kernel"
  emit INIT "$(rd /proc/1/comm)"
  emit BOOTLOADER "$bootloader"
  emit FIREWALL "$firewall"
  emit PKG_MANAGER "$pkgmgr"
  emit DESKTOP "$desk"
  emit SESSION_TYPE "${XDG_SESSION_TYPE:-unknown}"
  emit CPU_VENDOR "$cpuv"
  emit CPU_MODEL "${cpu_model:-unknown}"
  emit CPU_PHYS_BITS "${cpu_bits:-}"
  emit IOMMU "$( ((iommu_on)) && echo on || echo off )"
  emit IOMMU_VENDOR "$iommu_vendor"
  emit IOMMU_MGAW "$mgaw_min"
  emit HOST_GPU_VENDOR "$([[ -n $host_gpu ]] && vendor_key "$host_gpu" || echo none)"
  emit HOST_GPU_MODEL "$([[ -n $host_gpu ]] && gpu_model_of "$host_gpu" || echo none)"
  emit HOST_GPU_PCI "$host_gpu"
  emit PT_GPU_VENDOR "$([[ -n $GPU ]] && vendor_key "$GPU" || echo none)"
  emit PT_GPU_MODEL "${GPU_NAME:-none}"
  emit PT_GPU_PCI "$gpu_pci"
  emit PT_GROUP_ISOLATED "$isolated"
  emit PT_GROUP_SIZE "$group_size"
  emit FORM_FACTOR "$ff"
  emit SYS_VENDOR "$(rd "$SYS/class/dmi/id/sys_vendor")"
  emit PRODUCT_NAME "$(rd "$SYS/class/dmi/id/product_name")"
  emit RAM_GIB "$([[ -n $mem_kb ]] && echo $(( (mem_kb + 524288) / 1048576 )))"
  emit IMAGE_FS "$fstype"
  emit DISPLAYS_HOST "$n_other"
  emit DISPLAYS_ON_PT_GPU "$n_dgpu"
  emit LIBVIRT_VERSION "$(have virsh && virsh --version 2>/dev/null | head -n1)"
  emit QEMU_VERSION "$(have qemu-system-x86_64 && qemu-system-x86_64 --version 2>/dev/null | sed -n 's/^QEMU emulator version \([^ ]*\).*/\1/p' | head -n1)"
  emit LOOKING_GLASS_VERSION "$lg_ver"
  emit WARN_COUNT "$n_warn"
  emit NOGO_COUNT "$n_nogo"
  i=0; for m in "${nogo_msgs[@]}"; do i=$((i + 1)); emit "NOGO_$i" "$m"; done
  if (( n_nogo > 0 )); then emit VERDICT NO-GO; exit 1; fi
  emit VERDICT GO
  exit 0
fi

# ------------------------------------------------------------------------------------------
# Config proposal (stdout)
# ------------------------------------------------------------------------------------------
proposal=$(cat <<EOF
# $SYS_CONF - every machine-specific value for the win11 GPU-passthrough VM.
#
# Proposed by ./detect.sh. Review every value (the hardware report on stderr says what to look
# at), then install it with
#     ./install.sh --conf ./win11-vm.conf
# Everything in the bundle (winvm-gpu, winvm-usb, the libvirt hook, the launcher, the udev
# rule) reads this one file. It is sourced by bash as root, so keep it to plain VAR=value lines.

# libvirt domain name (qemu:///system).
VM_NAME=$VM_NAME

# Your login name. The Hyprland flag (~/.config/hypr/gpu-vm-mode), the Looking Glass shared
# memory file and the USB off-switch (~/.config/windows/usb-auto-off) live under this user.
VM_USER=$VM_USER

# Every PCI function in the passthrough GPU's IOMMU group, GPU first (VGA, then its HDMI audio).
# All of them are handed to vfio-pci together. Find them with: ./detect.sh
GPU_PCI="$gpu_pci"

# Name Windows shows for the GPU. The Virtual Display Driver is told to attach to it
# (guest/install-vdd.ps1 -GpuName). Confirm it in Windows Device Manager after installing the GPU driver.
GPU_NAME="$GPU_NAME"

# Guest physical address width in bits, when the IOMMU supports fewer bits than the CPU
# (Intel: MGAW from /sys/class/iommu/dmar*/intel-iommu/cap). Without it QEMU dies with
# "vfio: DMA mapping failed". Leave empty when not needed (detect.sh tells you).
IOMMU_LIMIT=$IOMMU_LIMIT

# USB vendor IDs (4 hex digits, space separated) whose devices are handed to Windows when
# plugged in while the VM runs. 1050 = Yubico. Leave empty for none.
USB_VENDORS="$USB_VENDORS"

# 1 = also hand USB mass-storage devices (thumbdrives, external disks) to Windows. 0 = off.
USB_STORAGE=$USB_STORAGE

# Looking Glass shared memory size in MiB (power of two). 128 covers up to 4K SDR.
LG_SHM_MB=$LG_SHM_MB
EOF
)
printf '%s\n' "$proposal"

# ------------------------------------------------------------------------------------------
# 9. Existing config
# ------------------------------------------------------------------------------------------
if [[ -e $SYS_CONF ]]; then
  if [[ -r $SYS_CONF ]]; then
    if diff -q <(grep -E '^[A-Z_]+=' "$SYS_CONF" | sort) <(printf '%s\n' "$proposal" | grep -E '^[A-Z_]+=' | sort) >/dev/null; then
      say INFO "$SYS_CONF exists and its values are identical to this proposal"
    else
      keys=$(diff <(grep -E '^[A-Z_]+=' "$SYS_CONF" | sort) <(printf '%s\n' "$proposal" | grep -E '^[A-Z_]+=' | sort) | sed -n 's/^[<>] \([A-Z_]*\)=.*/\1/p' | sort -u | tr '\n' ' ')
      say INFO "$SYS_CONF exists and differs from this proposal in: ${keys% } (compare with: diff $SYS_CONF <this output>)"
    fi
  else
    say INFO "$SYS_CONF exists but is not readable by this user"
  fi
else
  say INFO "$SYS_CONF does not exist yet"
fi

# ------------------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------------------
if (( n_nogo > 0 )); then
  say NO-GO "VERDICT: this machine cannot run the VM as it is ($n_nogo blocker(s) above)"
  exit 1
fi
say GO "VERDICT: this machine can run the VM ($n_warn warning(s) to review)"
exit 0
