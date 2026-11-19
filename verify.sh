#!/usr/bin/env bash
# verify.sh - read-only verification of this machine, in cumulative tiers.
#
#   ./verify.sh                         run tier T0 only (no consent needed)
#   ./verify.sh --yes-tier N            run tiers T0..TN in order (N = 1, 2 or 3)
#   ./verify.sh --record KEY=VALUE      store a check only the human can confirm (pass|fail|skip)
#   tools/report.sh                     turn the results file into reports/<...>.md
#
#   --yes-tier N    the human said yes to tiers up to N. Ask them first; the tier descriptions are:
#                     T0 read-only facts, automatic        T1 host install state
#                     T2 VM + Windows state                T3 GPU / USB / Looking Glass state
#                   A tier runs only if the one before it passed in this run; a failed tier stops
#                   the run (exit 1), an incomplete one (human keys missing) refuses the next (exit 3).
#   --record K=V    K is one of the human-confirmed keys below. Only stores the value in the results
#                   file (merged); it runs no tier. Re-run ./verify.sh --yes-tier N afterwards.
#   --existing-vm   the Windows VM already existed (this run did not install it): T2 is recorded as
#                   "pass (existing)"; the two Windows human keys then may stay unrecorded (skip).
#   --results FILE  results file (default <bundle>/results.local.json, gitignored)
#   --json          print the results file on stdout (the human-readable lines go to stderr)
#
# Everything here is a READ-ONLY inspection: it never installs, starts the VM, binds a GPU or touches
# USB. Acting is the agent's job under the human's yes; this script verifies the resulting state.
# The results file holds only allowlisted profile keys, per-check pass/fail/skip/need and the human
# keys: no host name, user name, path, serial or journal text.
#
# Exit: 0 every requested tier passed, 1 a check failed or a human-confirmed key is missing,
#       2 usage, 3 refused (a requested tier cannot run because the one before it is incomplete).
#
# Test hook (tests only): VERIFY_FORCE_FAIL=<check name>[,<check name>] forces those checks to fail.
# chk_<name> functions are called dynamically
# shellcheck disable=SC2329,SC2317
set -uo pipefail
export LC_ALL=C

B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/bundle.sh
. "$B/lib/bundle.sh"

# ------------------------------------------------------------------------------------------------
# Tables: edit here to add a check or a human key. A name without a prefix needs a function
# chk_<name> that sets R_STATUS (pass|fail|skip|need) and R_DETAIL; "h:<key>" is a human key.
# ------------------------------------------------------------------------------------------------
TIER_TITLE=("read-only facts" "host install state" "VM and Windows state" "GPU, USB and Looking Glass")
TIER_CHECKS=(
  "profile verdict iommu_on pt_group_isolated distro_folder scripts_syntax kvm_access libvirt_group"
  "packages libvirtd_active config_installed install_no_drift net_default_active"
  "vm_defined h:windows_boots_to_desktop h:windows_network vm_disk_nocow_if_btrfs"
  "gpu_vfio_bound_while_vm_runs lg_shm_exists usb_hook_log_seen h:gpu_no_code43 h:lg_shows_desktop_input_works h:usb_attach_detach_live h:usb_attach_at_boot h:switch_back_to_linux h:launcher_no_prompt"
)
# human key -> what the human must confirm (FOR_AGENT.md section 10 item in brackets)
declare -A HUMAN_WHAT=(
  [gpu_no_code43]="Device Manager shows the GPU with no warning icon [item 1]"
  [lg_shows_desktop_input_works]="Looking Glass shows the desktop, mouse and keyboard work [item 3]"
  [usb_attach_detach_live]="USB device attaches and detaches while the VM runs [item 4]"
  [usb_attach_at_boot]="USB device present at VM start is attached [item 5]"
  [windows_network]="Windows has network [item 7]"
  [switch_back_to_linux]="closing Looking Glass returns the GPU to Linux [item 8]"
  [launcher_no_prompt]="the Windows 11 (GPU) launcher starts with no password prompt [item 9]"
  [windows_boots_to_desktop]="Windows boots to its desktop"
)
# human keys that an existing VM may leave unrecorded (shown as skip)
EXISTING_VM_OPTIONAL=" windows_boots_to_desktop windows_network "
MAX_TIER=$((${#TIER_CHECKS[@]} - 1))

die_usage() { echo "verify.sh: $*" >&2; echo "try: ./verify.sh --help" >&2; exit 2; }
usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------------------------
YES_TIER=0
YES_SET=0
RESULTS=$B/results.local.json
EXISTING_VM=0
JSON=0
RECORDS=()
while (( $# )); do
  case $1 in
    --yes-tier)
      (( $# >= 2 )) || die_usage "--yes-tier needs a number"
      YES_TIER=$2; YES_SET=1; shift ;;
    --yes-tier=*) YES_TIER=${1#*=}; YES_SET=1 ;;
    --record)
      (( $# >= 2 )) || die_usage "--record needs KEY=pass|fail|skip"
      RECORDS+=("$2"); shift ;;
    --record=*) RECORDS+=("${1#*=}") ;;
    --existing-vm) EXISTING_VM=1 ;;
    --results)
      (( $# >= 2 )) || die_usage "--results needs a file"
      RESULTS=$2; shift ;;
    --results=*) RESULTS=${1#*=} ;;
    --json) JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done
[[ $YES_TIER =~ ^[0-9]+$ ]] && (( YES_TIER <= MAX_TIER )) || die_usage "--yes-tier must be 0..$MAX_TIER"
command -v jq >/dev/null 2>&1 || { echo "verify.sh: jq is required" >&2; exit 1; }

# human_tier <key>: the tier that owns a human key
human_tier() {
  local t c
  for t in "${!TIER_CHECKS[@]}"; do
    for c in ${TIER_CHECKS[t]}; do [[ $c == "h:$1" ]] && { echo "$t"; return 0; }; done
  done
  return 1
}

# ------------------------------------------------------------------------------------------------
# Results file: load existing human keys, write atomically (0600)
# ------------------------------------------------------------------------------------------------
declare -A HUMAN=()
load_human() {
  local k v
  [[ -e $RESULTS ]] || return 0
  if ! jq -e '.schema == 1' "$RESULTS" >/dev/null 2>&1; then
    echo "verify.sh: $RESULTS is not a schema-1 results file; starting a fresh one" >&2
    return 0
  fi
  while IFS=$'\t' read -r k v; do
    [[ -n $k && -n ${HUMAN_WHAT[$k]+x} && $v =~ ^(pass|fail|skip)$ ]] && HUMAN[$k]=$v
  done < <(jq -r '(.human // {}) | to_entries[] | "\(.key)\t\(.value)"' "$RESULTS" 2>/dev/null)
  return 0
}

human_json() {
  local k
  for k in "${!HUMAN[@]}"; do printf '%s\t%s\n' "$k" "${HUMAN[$k]}"; done | sort |
    jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
}

# write_results <profile-json> <tiers-json>: highest_passed is computed here, from tiers only.
write_results() {
  local profile=$1 tiers=$2 dir tmp
  dir=$(dirname "$RESULTS")
  [[ -d $dir ]] || { echo "verify.sh: no such directory: $dir" >&2; return 1; }
  tmp=$(umask 077; mktemp "$dir/.results.XXXXXX") || return 1
  if jq -n --arg date "$(date +%F)" --argjson profile "$profile" --argjson tiers "$tiers" \
       --argjson human "$(human_json)" '
       def hp($t): reduce range(0; 4) as $i (-1;
         if . == $i - 1 and ($t[($i | tostring)].status? == "pass") then $i else . end);
       {schema: 1, date: $date, profile: $profile, tiers: $tiers, human: $human,
        highest_passed: hp($tiers)}' >"$tmp" &&
     chmod 600 "$tmp" && mv -f "$tmp" "$RESULTS"; then
    return 0
  fi
  rm -f "$tmp"
  echo "verify.sh: could not write $RESULTS" >&2
  return 1
}

# ------------------------------------------------------------------------------------------------
# --record mode: store human-confirmed keys, run nothing
# ------------------------------------------------------------------------------------------------
if (( ${#RECORDS[@]} )); then
  (( YES_SET == 0 )) || die_usage "--record only stores values; do not combine it with --yes-tier"
  load_human
  declare -A NEWREC=()
  for r in "${RECORDS[@]}"; do
    [[ $r == *=* ]] || die_usage "--record wants KEY=pass|fail|skip, got: $r"
    k=${r%%=*}; v=${r#*=}
    [[ -n ${HUMAN_WHAT[$k]+x} ]] || die_usage "unknown --record key: $k (allowed: $(printf '%s ' "${!HUMAN_WHAT[@]}" | tr ' ' '\n' | sort | tr '\n' ' '))"
    [[ $v =~ ^(pass|fail|skip)$ ]] || die_usage "--record $k: value must be pass, fail or skip"
    NEWREC[$k]=$v
  done
  for k in "${!NEWREC[@]}"; do HUMAN[$k]=${NEWREC[$k]}; done
  if jq -e '.schema == 1' "$RESULTS" >/dev/null 2>&1; then
    profile=$(jq -c '.profile' "$RESULTS"); tiers=$(jq -c '.tiers' "$RESULTS")
  else
    profile='{}'; tiers='{}'
  fi
  write_results "$profile" "$tiers" || exit 1
  for k in $(printf '%s\n' "${!NEWREC[@]}" | sort); do
    echo "recorded $k=${NEWREC[$k]} (T$(human_tier "$k"))"
  done
  echo "tiers in the results file are unchanged; re-run ./verify.sh --yes-tier N to update them."
  exit 0
fi

# ------------------------------------------------------------------------------------------------
# Check helpers
# ------------------------------------------------------------------------------------------------
declare -A P=()           # profile
PROFILE_RAW=""
R_STATUS=""; R_DETAIL=""
pass() { R_STATUS=pass; R_DETAIL=${1:-ok}; }
fail() { R_STATUS=fail; R_DETAIL=${1:-failed}; }
skip() { R_STATUS=skip; R_DETAIL=${1:-skipped}; }
need() { R_STATUS=need; R_DETAIL=${1:-needed}; }

VIRSH=(virsh -c qemu:///system)
conf_get() {   # conf_get KEY: value from /etc/win11-vm.conf, read with grep, never sourced
  local l v
  l=$(grep -m1 "^$1=" /etc/win11-vm.conf 2>/dev/null) || return 1
  v=${l#*=}; v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  printf '%s' "$v"
}
vm_name() {
  local n
  n=$(conf_get VM_NAME 2>/dev/null) || n=
  [[ $n =~ ^[A-Za-z0-9._-]+$ ]] || n=win11
  printf '%s' "$n"
}

# --- T0 ---
chk_profile() {
  local out line k v
  out=$("$B/detect.sh" --profile 2>/dev/null) || true
  PROFILE_RAW=$out
  while IFS= read -r line; do
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    [[ $k =~ ^[A-Z0-9_]+$ ]] && P[$k]=$v
  done <<<"$out"
  if [[ -n ${P[PROFILE_VERSION]:-} ]]; then pass "detect.sh --profile, version ${P[PROFILE_VERSION]}"
  else fail "detect.sh --profile printed no PROFILE_VERSION"; fi
}
chk_verdict() {
  local i n=${P[NOGO_COUNT]:-0} msg=""
  if [[ ${P[VERDICT]:-} == GO ]]; then pass "GO (${P[WARN_COUNT]:-0} warnings)"; return; fi
  for ((i = 1; i <= n; i++)); do msg+="NOGO_$i: ${P[NOGO_$i]:-?}; "; done
  fail "${P[VERDICT]:-no verdict}${msg:+ - $msg}"
}
chk_iommu_on() {
  if [[ ${P[IOMMU]:-} == on ]]; then pass "IOMMU on (${P[IOMMU_VENDOR]:-?})"; else fail "IOMMU is ${P[IOMMU]:-unknown}"; fi
}
chk_pt_group_isolated() {
  if [[ ${P[PT_GROUP_ISOLATED]:-} == yes ]]; then pass "passthrough GPU group isolated (size ${P[PT_GROUP_SIZE]:-?})"
  else fail "passthrough GPU group isolated: ${P[PT_GROUP_ISOLATED]:-unknown}"; fi
}
chk_distro_folder() {
  local id
  if id=$(pick_distro "$B"); then pass "distros/$id"; else fail "no distros/<id> for ${P[DISTRO_ID]:-this distro}"; fi
}
bundle_scripts() {   # every shell script of the bundle, one path per line
  local f
  {
    find "$B" -path "$B/.git" -prune -o -type f -name '*.sh' -print
    find "$B/files" "$B/.githooks" -type f 2>/dev/null
  } | sort -u | while IFS= read -r f; do
    if [[ $f == *.sh ]] || head -n1 "$f" 2>/dev/null | grep -Eq '^#!.*bash'; then printf '%s\n' "$f"; fi
  done
}
chk_scripts_syntax() {
  local f n=0 bad=""
  while IFS= read -r f; do
    n=$((n + 1))
    bash -n "$f" 2>/dev/null || bad+=" ${f#"$B"/}"
  done < <(bundle_scripts)
  if (( n == 0 )); then fail "found no scripts to check"
  elif [[ -n $bad ]]; then fail "bash -n failed:$bad"
  else pass "bash -n ok on $n scripts"; fi
}
chk_kvm_access() {
  if [[ ! -e /dev/kvm ]]; then fail "/dev/kvm missing (virtualisation off in firmware, or kvm module not loaded)"
  elif [[ -r /dev/kvm && -w /dev/kvm ]]; then pass "/dev/kvm readable and writable"
  else fail "/dev/kvm exists (group $(stat -c %G /dev/kvm 2>/dev/null)) but you cannot read and write it"; fi
}
chk_libvirt_group() {
  local g
  for g in $(id -nG 2>/dev/null); do [[ $g == libvirt ]] && { pass "current user is in group libvirt"; return; }; done
  fail "current user is not in group libvirt (log out and in after adding)"
}

# --- T1 ---
chk_packages() {
  local c missing="" ovmf
  for c in virsh qemu-system-x86_64 looking-glass-client swtpm; do command -v "$c" >/dev/null 2>&1 || missing+=" $c"; done
  ovmf=$(find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu -iname '*ovmf*' -print -quit 2>/dev/null)
  [[ -n $ovmf ]] || missing+=" OVMF-firmware"
  if [[ -n $missing ]]; then fail "missing:$missing"; else pass "virsh qemu-system-x86_64 looking-glass-client swtpm OVMF present"; fi
}
chk_libvirtd_active() {
  local u
  for u in libvirtd virtqemud virtqemud.socket libvirtd.socket; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then pass "$u active"; return; fi
  done
  fail "none of libvirtd, virtqemud, virtqemud.socket, libvirtd.socket is active"
}
chk_config_installed() {
  if [[ -r /etc/win11-vm.conf ]]; then pass "/etc/win11-vm.conf readable"; else fail "/etc/win11-vm.conf missing or unreadable"; fi
}
chk_install_no_drift() {
  local out rc
  if [[ ! -r /etc/win11-vm.conf ]]; then fail "cannot run install.sh --check: /etc/win11-vm.conf missing"; return; fi
  out=$("$B/install.sh" --check 2>&1); rc=$?
  if (( rc == 0 )) && grep -q 'No drift\.' <<<"$out"; then pass "install.sh --check: No drift."
  else fail "install.sh --check exit $rc: $(head -n 3 <<<"$out" | tr '\n' ' ')"; fi
}
chk_net_default_active() {
  local info   # captured first: grep -q on a pipe would SIGPIPE virsh and trip pipefail
  info=$("${VIRSH[@]}" net-info default 2>/dev/null)
  if grep -Eq '^Active:[[:space:]]+yes' <<<"$info"; then pass "libvirt network default active"
  else fail "libvirt network default is not active (or virsh cannot reach libvirtd)"; fi
}

# --- T2 ---
chk_vm_defined() {
  local vm; vm=$(vm_name)
  if "${VIRSH[@]}" dominfo "$vm" >/dev/null 2>&1; then pass "domain $vm defined"; else fail "domain $vm is not defined (or virsh cannot reach libvirtd)"; fi
}
chk_vm_disk_nocow_if_btrfs() {
  local vm img attrs
  if [[ ${P[IMAGE_FS]:-} != btrfs ]]; then skip "image filesystem is ${P[IMAGE_FS]:-unknown}, not btrfs"; return; fi
  vm=$(vm_name)
  img=$("${VIRSH[@]}" domblklist "$vm" 2>/dev/null | awk 'NR > 2 && $2 ~ /^\// {print $2; exit}')
  [[ -n $img ]] || { skip "no disk image path from virsh domblklist"; return; }
  attrs=$(lsattr -d "$img" 2>/dev/null | awk '{print $1}')
  [[ -n $attrs ]] || { skip "disk image attributes not readable"; return; }
  if [[ $attrs == *C* ]]; then pass "disk image has the NOCOW (C) attribute"; else fail "btrfs disk image lacks the NOCOW (C) attribute (see LESSONS.md)"; fi
}

# --- T3 ---
chk_gpu_vfio_bound_while_vm_runs() {
  local vm state status gw
  vm=$(vm_name)
  state=$("${VIRSH[@]}" domstate "$vm" 2>/dev/null | head -n1)
  if [[ $state != running ]]; then need "VM is not running (${state:-state unknown}): start the VM (the human's yes) then re-run"; return; fi
  gw=$(command -v winvm-gpu 2>/dev/null) || gw=
  [[ -n $gw ]] || { fail "winvm-gpu is not installed"; return; }
  status=$("$gw" status 2>/dev/null)
  if grep -Eq '^gpu driver:[[:space:]]+vfio-pci' <<<"$status"; then pass "gpu driver: vfio-pci while the VM runs"
  else fail "winvm-gpu status: $(grep -m1 '^gpu driver:' <<<"$status" || echo 'no gpu driver line')"; fi
}
chk_lg_shm_exists() {
  if [[ -e /dev/shm/looking-glass ]]; then pass "/dev/shm/looking-glass exists"; else fail "/dev/shm/looking-glass missing (tmpfiles rule not applied?)"; fi
}
chk_usb_hook_log_seen() {
  local out n
  out=$(journalctl -t winvm-usb -n 50 --no-pager 2>/dev/null) || { skip "no journal access"; return; }
  [[ -n $out ]] || { skip "no journal access or no winvm-usb entries"; return; }
  n=$(grep -c ' attach ' <<<"$out")
  if (( n > 0 )); then pass "$n attach line(s) in the last 50 winvm-usb entries"; else skip "0 attach lines in the last 50 winvm-usb entries"; fi
}

# human key check
chk_human() {
  local key=$1
  case ${HUMAN[$key]:-} in
    pass) pass "human confirmed: ${HUMAN_WHAT[$key]}" ;;
    fail) fail "human reported FAIL: ${HUMAN_WHAT[$key]}" ;;
    skip) skip "human skipped: ${HUMAN_WHAT[$key]}" ;;
    *)
      if (( EXISTING_VM )) && [[ $EXISTING_VM_OPTIONAL == *" $key "* ]]; then
        skip "existing VM, not re-confirmed: ${HUMAN_WHAT[$key]}"
      else
        need "ask the human: ${HUMAN_WHAT[$key]}; then ./verify.sh --record $key=pass|fail|skip"
      fi ;;
  esac
}

forced_fail() { [[ ",${VERIFY_FORCE_FAIL:-}," == *",$1,"* ]]; }

# ------------------------------------------------------------------------------------------------
# Tier runner
# ------------------------------------------------------------------------------------------------
declare -a TIER_STATUS=() TIER_EXIST=() TIER_NEEDS=()
TIER_CHECK_LINES=()   # per tier: "name<TAB>status" lines

label() { case $1 in pass) echo PASS;; fail) echo FAIL;; skip) echo SKIP;; need) echo NEED;; esac; }

run_tier() {
  local t=$1 c name nfail=0 nneed=0 npass=0 nskip=0 lines="" needs=""
  for c in ${TIER_CHECKS[t]}; do
    name=${c#h:}
    if [[ $c == h:* ]]; then chk_human "$name"; else "chk_$name"; fi
    if forced_fail "$name"; then R_STATUS=fail; R_DETAIL="forced by VERIFY_FORCE_FAIL (test hook)"; fi
    printf '%-4s  T%d %s: %s\n' "$(label "$R_STATUS")" "$t" "$name" "$R_DETAIL" >&"$OUTFD"
    lines+="$name"$'\t'"$R_STATUS"$'\n'
    case $R_STATUS in
      pass) npass=$((npass + 1)) ;;
      fail) nfail=$((nfail + 1)) ;;
      skip) nskip=$((nskip + 1)) ;;
      need) nneed=$((nneed + 1)); needs+=" $name" ;;
    esac
  done
  TIER_CHECK_LINES[t]=$lines
  TIER_EXIST[t]=false
  if (( nfail )); then TIER_STATUS[t]=fail
  elif (( nneed )); then TIER_STATUS[t]=incomplete
  else TIER_STATUS[t]=pass; fi
  if (( t == 2 && EXISTING_VM )) && [[ ${TIER_STATUS[t]} == pass ]]; then TIER_EXIST[t]=true; fi
  TIER_NEEDS[t]=${needs# }
  case ${TIER_STATUS[t]} in
    pass) printf '== T%d %s: pass (%d pass, %d skip)%s\n' "$t" "${TIER_TITLE[t]}" "$npass" "$nskip" "$([[ ${TIER_EXIST[t]} == true ]] && echo ', existing VM')" >&"$OUTFD" ;;
    fail) printf '== T%d %s: FAIL (%d failed)\n' "$t" "${TIER_TITLE[t]}" "$nfail" >&"$OUTFD" ;;
    incomplete) printf '== T%d %s: incomplete, still needed: %s\n' "$t" "${TIER_TITLE[t]}" "${TIER_NEEDS[t]}" >&"$OUTFD" ;;
  esac
}

tier_json() {
  local t=$1 checks
  checks=$(printf '%s' "${TIER_CHECK_LINES[t]}" | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
  jq -n --arg s "${TIER_STATUS[t]}" --argjson e "${TIER_EXIST[t]}" --argjson c "$checks" '{status: $s, existing: $e, checks: $c}'
}

if (( JSON )); then exec {OUTFD}>&2; else exec {OUTFD}>&1; fi
load_human

RC=0
STOP_MSG=""
for ((t = 0; t <= YES_TIER; t++)); do
  # cumulative rule: tier t needs tier t-1 passed in this run's passing set (the results file is
  # rewritten from scratch every run, so an older recorded pass never stands in for a fresh one)
  if (( t > 0 )) && [[ ${TIER_STATUS[t-1]:-} != pass ]]; then
    case ${TIER_STATUS[t-1]:-} in
      fail) RC=1; STOP_MSG="T$((t - 1)) failed; T$t and above do not run until it passes" ;;
      incomplete) RC=3; STOP_MSG="refused T$t: T$((t - 1)) is incomplete, still needed: ${TIER_NEEDS[t-1]}" ;;
      *) RC=3; STOP_MSG="refused T$t: T$((t - 1)) has not passed" ;;
    esac
    for ((u = t; u <= YES_TIER; u++)); do printf '%-4s  T%d (not run): %s\n' "STOP" "$u" "$STOP_MSG" >&"$OUTFD"; done
    break
  fi
  run_tier "$t"
done

# the last requested tier that actually ran decides RC when nothing refused it
last=$YES_TIER
while (( last > 0 )) && [[ -z ${TIER_STATUS[last]:-} ]]; do last=$((last - 1)); done
if (( RC == 0 )) && [[ ${TIER_STATUS[last]:-} != pass ]]; then RC=1; fi

# results file
profile_json=$(printf '%s\n' "$PROFILE_RAW" | jq -Rn '[inputs | select(test("^[A-Z0-9_]+=")) | capture("^(?<k>[A-Z0-9_]+)=(?<v>.*)$")] | map({(.k): .v}) | add // {}')
tiers_json='{}'
for t in "${!TIER_STATUS[@]}"; do
  tiers_json=$(jq -c --arg k "$t" --argjson v "$(tier_json "$t")" '. + {($k): $v}' <<<"$tiers_json")
done
write_results "$profile_json" "$tiers_json" || exit 1

hp=$(jq -r '.highest_passed' "$RESULTS")
if (( hp < 0 )); then hp_txt="none (T0 failed)"; else hp_txt="T$hp"; fi
echo "highest tier passed: $hp_txt (results: $RESULTS)" >&"$OUTFD"
if (( YES_TIER == 0 )); then echo "T1..T3 change the machine: ask the human, then ./verify.sh --yes-tier N" >&"$OUTFD"; fi
(( JSON )) && cat "$RESULTS"
exit "$RC"
