#!/usr/bin/env bash
# Tests for tools/report.sh and verify.sh. Exits non-zero if any expectation fails.
# Read-only on the host (verify.sh only inspects); everything it writes lives in a mktemp -d scratch dir.
# No network. Host-dependent expectations (does T1 pass here?) are checked as invariants, not values.
# single-quoted bash -c and jq programs; functions are passed to check as arguments
# shellcheck disable=SC2016,SC2329,SC2317
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FIX=$HERE/fixtures
REPORT=$ROOT/tools/report.sh
VERIFY=$ROOT/verify.sh
PRIV=$ROOT/tools/privacy-check.sh
FAILS=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() {
  local name=$1 out; shift
  if out=$("$@" 2>&1); then ok "$name"; else bad "$name"; [[ -z $out ]] || printf "%s\n" "$out" | sed "s/^/    | /"; fi
}
note() { echo "note  $1"; }
# teq a b [c d ...]: every pair is equal
teq() { while (( $# >= 2 )); do [[ $1 == "$2" ]] || return 1; shift 2; done; }

# rep <root> <args...>: run report.sh against a scratch root
rep() { local r=$1; shift; REPORT_ROOT=$r "$REPORT" "$@"; }
new_root() { local d; d=$(mktemp -d "$TMPD/root.XXXXXX"); mkdir -p "$d/reports"; rep "$d" --regen >/dev/null; printf '%s' "$d"; }
fm() { sed -n "s/^$2: *//p" "$1" | head -n1; }   # front matter value (quotes kept)

# ---------------------------------------------------------------- syntax
check "bash -n verify.sh" bash -n "$VERIFY"
check "bash -n tools/report.sh" bash -n "$REPORT"
check "bash -n this runner" bash -n "${BASH_SOURCE[0]}"

# ---------------------------------------------------------------- report.sh: names and front matter
R=$(new_root)
out=$(rep "$R" --results "$FIX/go-t3.json" --date 2026-01-10 --note "tested with a spare key" 2>&1); rc=$?
F3=$R/reports/2026-01-10_arch_hyprland_intel-host_nvidia-pt_laptop.md
check "go-t3: exit 0 and expected file name" bash -c '[[ $1 == 0 && -f $2 ]]' _ "$rc" "$F3"
keys_ok=1
for k in date distro distro_version distro_id_like desktop session_type hardware_key form_factor machine cpu host_gpu pt_gpu iommu_mgaw kernel bootloader firewall libvirt qemu looking_glass verdict tier_passed existing_vm; do
  grep -q "^$k: " "$F3" || { keys_ok=0; echo "  missing key $k"; }
done
check "go-t3: every front matter key present" test "$keys_ok" = 1
check "go-t3: tier_passed integer 3, existing_vm false" teq "$(fm "$F3" tier_passed)" 3 "$(fm "$F3" existing_vm)" false
check "go-t3: values quoted" test "$(fm "$F3" hardware_key)" = '"intel-host_nvidia-pt"'
check "go-t3: first line is --- and a title follows" bash -c 'head -n1 "$1" | grep -qx -- "---" && grep -q "^# Report: arch / hyprland / intel-host_nvidia-pt (laptop)$" "$1"' _ "$F3"
check "go-t3: four table rows, all pass" bash -c '[[ $(grep -c "^| T[0-3] | pass |" "$1") == 4 ]]' _ "$F3"
check "go-t3: note present, sections present" bash -c 'grep -q "^- tested with a spare key$" "$1" && grep -q "^## Failed or missing checks$" "$1" && grep -q "^## Notes$" "$1" && grep -q "^## Known issues$" "$1"' _ "$F3"
check "go-t3: COMPATIBILITY.md row says T3" grep -q '^| arch | hyprland | intel-host_nvidia-pt | Example Corp Laptop 1000 | T3 | GO | 2026-01-10 |' "$R/COMPATIBILITY.md"

# privacy: full local mode (not --static-only), plus no user name or host name
"$PRIV" --files "$F3" "$R/COMPATIBILITY.md" >"$TMPD/priv.out" 2>&1; prc=$?
check "go-t3: privacy-check --files (full local mode) passes" test "$prc" = 0
[[ $prc == 0 ]] || sed 's/^/  /' "$TMPD/priv.out"
HOSTN=$(hostname 2>/dev/null || true)
leak=0
grep -qF -- "$USER" "$F3" && leak=1
[[ -n $HOSTN ]] && grep -qiF -- "$HOSTN" "$F3" && leak=1
check "go-t3: report has no \$USER or hostname" test "$leak" = 0

# duplicate refusal
out=$(rep "$R" --results "$FIX/go-t3.json" --date 2026-01-10 2>&1); rc=$?
check "same machine twice on one day: refused (exit 1) and says pass --date" bash -c '[[ $1 == 1 && $2 == *"pass --date"* ]]' _ "$rc" "$out"

# other fixtures
rep "$R" --results "$FIX/go-t1.json" --date 2026-01-10 >/dev/null; rc1=$?
rep "$R" --results "$FIX/nogo.json" --date 2026-01-10 >/dev/null; rcn=$?
rep "$R" --results "$FIX/existing-vm.json" --date 2026-01-10 >/dev/null; rce=$?
check "go-t1 / nogo / existing-vm all written (exit 0)" test "$rc1$rcn$rce" = 000
F1=$R/reports/2026-01-10_fedora_gnome_amd-host_nvidia-pt_desktop.md
FN=$R/reports/2026-01-10_debian_kde_intel-host_nvidia-pt_desktop.md
FE=$R/reports/2026-01-10_omarchy_hyprland_intel-host_nvidia-pt_laptop.md
check "go-t1: tier_passed 1, T2/T3 'not run'" bash -c '[[ $(grep "^tier_passed:" "$1") == "tier_passed: 1" ]] && grep -q "^| T2 | not run |" "$1" && grep -q "^| T3 | not run |" "$1"' _ "$F1"
check "nogo: tier_passed -1, T0 fail, matrix says 'none (T0 failed)'" bash -c '[[ $(grep "^tier_passed:" "$1") == "tier_passed: -1" ]] && grep -q "^| T0 | fail |" "$1" && grep -q "| none (T0 failed) | NO-GO |" "$2"' _ "$FN" "$R/COMPATIBILITY.md"
check "nogo: blockers listed under failed checks" grep -q '^- blocker: IOMMU is off' "$FN"
check "existing-vm: 'pass (existing)' row and existing_vm true, tier 2" bash -c 'grep -q "^| T2 | pass (existing) |" "$1" && grep -q "^existing_vm: true$" "$1" && grep -q "^tier_passed: 2$" "$1"' _ "$FE"
rep "$R" --results "$FIX/t0-only.json" --date 2026-01-11 >/dev/null; rc0=$?
F0=$R/reports/2026-01-11_arch_hyprland_intel-host_nvidia-pt_laptop.md
check "t0-only: a T0-only report is valid (exit 0, tier_passed 0)" teq "$rc0" 0 "$(fm "$F0" tier_passed)" 0
"$PRIV" --files "$F1" "$FN" "$FE" "$F0" >/dev/null 2>&1
check "other reports pass privacy-check --files" test $? = 0

# matrix keeps the latest report per key (2026-01-11 beats 2026-01-10 for the arch row)
check "matrix: one row for the arch key, the later date, T0" bash -c '[[ $(grep -c "^| arch | hyprland | intel-host_nvidia-pt |" "$1") == 1 ]] && grep -q "^| arch | hyprland | intel-host_nvidia-pt | Example Corp Laptop 1000 | T0 | GO | 2026-01-11 | \[report\](reports/2026-01-11_arch" "$1"' _ "$R/COMPATIBILITY.md"
check "matrix: rows sorted by distro (arch, debian, fedora, omarchy)" bash -c '[[ $(grep "^| [a-z]" "$1" | grep -v "^| Distro" | cut -d"|" -f2 | tr -d " \n") == archdebianfedoraomarchy ]]' _ "$R/COMPATIBILITY.md"
# tie on date: lexicographically last filename wins; make a second arch-keyed report with another date order
R2=$(new_root)
rep "$R2" --results "$FIX/t0-only.json" --date 2026-03-01 >/dev/null
rep "$R2" --results "$FIX/go-t3.json" --date 2026-02-01 >/dev/null
check "matrix: latest by date even when written in the other order" grep -q '| T0 | GO | 2026-03-01 |' "$R2/COMPATIBILITY.md"

# ---------------------------------------------------------------- refusing inconsistent / bad results
R3=$(new_root)
out=$(rep "$R3" --results "$FIX/inconsistent.json" --date 2026-01-10 2>&1); rc=$?
check "inconsistent results (highest_passed 3, T1 failed): refused, exit 1, nothing written" bash -c '[[ $1 == 1 && $2 == *ReportHonest* ]] && [[ -z $(ls "$3/reports") ]]' _ "$rc" "$out" "$R3"
jq '.schema = 2' "$FIX/go-t3.json" >"$TMPD/old.json"
rep "$R3" --results "$TMPD/old.json" >/dev/null 2>&1
check "old schema: refused" test $? = 1
jq '.profile.HOSTNAME = "somebox"' "$FIX/go-t3.json" >"$TMPD/extra.json"
rep "$R3" --results "$TMPD/extra.json" >/dev/null 2>&1
check "profile key outside the allowlist: refused" test $? = 1
jq '.tiers["0"].status = "fail"' "$FIX/go-t3.json" >"$TMPD/t0f.json"
rep "$R3" --results "$TMPD/t0f.json" >/dev/null 2>&1
check "T0 fail but higher tiers pass: refused" test $? = 1
rep "$R3" --results "$TMPD/does-not-exist.json" >/dev/null 2>&1
check "missing results file: error exit 1" test $? = 1
rep "$R3" --bogus >/dev/null 2>&1
check "unknown flag: usage exit 2" test $? = 2

# ---------------------------------------------------------------- report.sh --check
check "--check passes on good reports" rep "$R" --check
check "--check passes with zero reports" rep "$(new_root)" --check
R4=$(new_root); rep "$R4" --results "$FIX/go-t1.json" --date 2026-01-10 >/dev/null
G=$R4/reports/2026-01-10_fedora_gnome_amd-host_nvidia-pt_desktop.md
sed -i 's/^tier_passed: 1$/tier_passed: 3/' "$G"
out=$(rep "$R4" --check 2>&1); rc=$?
check "--check FAILS when tier_passed overstates the table" bash -c '[[ $1 == 1 && $2 == *"tier_passed is 3"* ]]' _ "$rc" "$out"
sed -i 's/^tier_passed: 3$/tier_passed: 1/' "$G"
check "--check passes again after restoring it" rep "$R4" --check
sed -i 's/^tier_passed: 1$/tier_passed: 7/' "$G"
check "--check FAILS on tier_passed outside -1..3" bash -c '! REPORT_ROOT=$1 "$2" --check >/dev/null 2>&1' _ "$R4" "$REPORT"
sed -i 's/^tier_passed: 7$/tier_passed: 1/' "$G"
sed -i 's/^| T1 | pass |/| T1 | fail |/' "$G"
check "--check FAILS when the table understates (T1 fail, tier_passed 1)" bash -c '! REPORT_ROOT=$1 "$2" --check >/dev/null 2>&1' _ "$R4" "$REPORT"
sed -i 's/^| T1 | fail |/| T1 | pass |/' "$G"
sed -i '/^cpu: /d' "$G"
out=$(rep "$R4" --check 2>&1); rc=$?
check "--check FAILS on a missing front matter key" bash -c '[[ $1 == 1 && $2 == *"lacks key: cpu"* ]]' _ "$rc" "$out"
sed -i 's/^form_factor: "desktop"$/&\ncpu: "Example CPU 1000"/' "$G"
check "--check passes after restoring the key" rep "$R4" --check
mv "$G" "$R4/reports/2026-01-10_fedora_gnome_amd-host_nvidia-pt_laptop.md"
out=$(rep "$R4" --check 2>&1); rc=$?
check "--check FAILS on a wrong file name" bash -c '[[ $1 == 1 && $2 == *"filename does not match"* ]]' _ "$rc" "$out"
mv "$R4/reports/2026-01-10_fedora_gnome_amd-host_nvidia-pt_laptop.md" "$G"
check "--check passes after renaming back" rep "$R4" --check
echo "| extra | row | | | | | | |" >>"$R4/COMPATIBILITY.md"
out=$(rep "$R4" --check 2>&1); rc=$?
check "--check FAILS on a stale / hand-edited COMPATIBILITY.md" bash -c '[[ $1 == 1 && $2 == *"COMPATIBILITY.md"* ]]' _ "$rc" "$out"
rep "$R4" --regen >/dev/null
check "--regen repairs it and --check passes" rep "$R4" --check
rm -f "$R4/COMPATIBILITY.md"
check "--check FAILS when COMPATIBILITY.md is missing" bash -c '! REPORT_ROOT=$1 "$2" --check >/dev/null 2>&1' _ "$R4" "$REPORT"

# ---------------------------------------------------------------- verify.sh (read-only on the host)
VR=$TMPD/verify-results.json
hasjq() { jq -e "$1" "$VR" >/dev/null 2>&1; }
tiers_keys() { jq -c '[.tiers | keys[]]' "$VR"; }

# (iv) no flags: T0 only, no tier 1 key
"$VERIFY" --results "$VR" >"$TMPD/v0.out" 2>&1; rc=$?
check "verify.sh (no flags): exit 0 or 1, only tier 0 in the results" bash -c '[[ $1 == 0 || $1 == 1 ]]' _ "$rc"
check "verify.sh (no flags): results have no tier 1 key" test "$(tiers_keys)" = '["0"]'
check "verify.sh (no flags): results file mode 0600" test "$(stat -c %a "$VR")" = 600
check "verify.sh: results carry schema 1, profile, human, highest_passed" hasjq '.schema == 1 and (.profile.PROFILE_VERSION == "1") and (.human == {}) and (.highest_passed | IN(-1, 0))'
T0_STATUS=$(jq -r '.tiers["0"].status' "$VR")
check "verify.sh: highest_passed matches T0 status" bash -c '[[ ($1 == pass && $2 == 0) || ($1 == fail && $2 == -1) ]]' _ "$T0_STATUS" "$(jq -r .highest_passed "$VR")"
# (v) no user name / hostname / path in the results
leak=0
grep -qF -- "$USER" "$VR" && leak=1
[[ -n $HOSTN ]] && grep -qiF -- "$HOSTN" "$VR" && leak=1
grep -qF -- "$HOME" "$VR" && leak=1
check "verify.sh: results contain no \$USER, hostname or \$HOME" test "$leak" = 0
check "verify.sh: results hold only the allowed top-level keys" hasjq '(keys | sort) == ["date","highest_passed","human","profile","schema","tiers"]'

if [[ $T0_STATUS == pass ]]; then
  # (i) force a T0 failure: stop there, exit 1, nothing above T0
  VERIFY_FORCE_FAIL=iommu_on "$VERIFY" --results "$VR" --yes-tier 3 >"$TMPD/v1.out" 2>&1; rc=$?
  check "forced T0 failure with --yes-tier 3: exit 1" test "$rc" = 1
  check "forced T0 failure: T1..T3 never ran" bash -c '! grep -Eq "^(PASS|FAIL|SKIP|NEED)  T[123] " "$1"' _ "$TMPD/v1.out"
  check "forced T0 failure: results have only tier 0 (fail) and highest_passed -1" teq "$(tiers_keys)" '["0"]' "$(jq -r '.tiers["0"].status' "$VR")" fail "$(jq -r .highest_passed "$VR")" -1
  check "forced T0 failure: output says why T1 did not run" grep -q 'T1 (not run)' "$TMPD/v1.out"
  # (ii) forced failure at T1: T0 runs, T1 fails, T2/T3 never run
  VERIFY_FORCE_FAIL=packages "$VERIFY" --results "$VR" --yes-tier 3 >"$TMPD/v2.out" 2>&1; rc=$?
  check "forced T1 failure with --yes-tier 3: exit 1" test "$rc" = 1
  check "forced T1 failure: T0 ran and passed, T2/T3 never ran" bash -c 'grep -q "^== T0 .*: pass" "$1" && grep -q "^FAIL  T1 packages" "$1" && ! grep -Eq "^(PASS|FAIL|SKIP|NEED)  T[23] " "$1"' _ "$TMPD/v2.out"
  check "forced T1 failure: results tiers are 0 and 1, highest_passed 0" teq "$(tiers_keys)" '["0","1"]' "$(jq -r .highest_passed "$VR")" 0 "$(jq -r '.tiers["1"].status' "$VR")" fail
  # real run up to T3: invariants that hold whatever the host looks like
  "$VERIFY" --results "$VR" --yes-tier 3 >"$TMPD/v3.out" 2>&1; rc=$?
  check "verify.sh --yes-tier 3 (real): exit is 0, 1 or 3" bash -c '[[ $1 == 0 || $1 == 1 || $1 == 3 ]]' _ "$rc"
  check "verify.sh --yes-tier 3 (real): a tier exists only if every lower tier passed" hasjq '
    [.tiers | to_entries[] | {t: (.key | tonumber), s: .value.status}] as $ts
    | all($ts[] | select(.t > 0); . as $x | any($ts[]; .t == $x.t - 1 and .s == "pass"))'
  check "verify.sh --yes-tier 3 (real): at most one non-pass tier, and it is the highest" hasjq '
    [.tiers | to_entries[] | {t: (.key | tonumber), s: .value.status}] as $ts
    | ([$ts[] | select(.s != "pass")] | length) <= 1
      and ([$ts[] | select(.s != "pass") | .t] | all(. == ([$ts[].t] | max)))'
  check "verify.sh --yes-tier 3 (real): highest_passed recomputed from tiers" hasjq '
    . as $r | (reduce range(0; 4) as $i (-1; if . == $i - 1 and ($r.tiers[$i | tostring].status? == "pass") then $i else . end)) == .highest_passed'
  # exit 3 needs an incomplete T2 behind a passing T1 (host dependent: only checked when that is the real state)
  if [[ $(jq -r '.tiers["2"].status // ""' "$VR") == incomplete ]]; then
    check "T2 incomplete + --yes-tier 3: refused with exit 3, T3 not run, needed keys named" bash -c '[[ $1 == 3 ]] && grep -q "refused T3: T2 is incomplete" "$2" && ! grep -Eq "^(PASS|FAIL|SKIP|NEED)  T3 " "$2"' _ "$rc" "$TMPD/v3.out"
  else
    note "exit-3 refusal not exercised: T2 is not incomplete on this host (state: $(jq -c '[.tiers[].status]' "$VR"))"
  fi
else
  note "T0 does not pass on this host; the forced-failure and real multi-tier tests were skipped"
fi

# human keys: --record
"$VERIFY" --results "$VR" --record bogus_key=pass >/dev/null 2>&1
check "--record rejects an unknown key (exit 2)" test $? = 2
"$VERIFY" --results "$VR" --record windows_network=maybe >/dev/null 2>&1
check "--record rejects a bad value (exit 2)" test $? = 2
"$VERIFY" --results "$VR" --record windows_network >/dev/null 2>&1
check "--record without =VALUE is a usage error (exit 2)" test $? = 2
"$VERIFY" --results "$VR" --record windows_network=pass --yes-tier 2 >/dev/null 2>&1
check "--record combined with --yes-tier is a usage error (exit 2)" test $? = 2
"$VERIFY" --results "$VR" --yes-tier 4 >/dev/null 2>&1
check "--yes-tier 4 is a usage error (exit 2)" test $? = 2
"$VERIFY" --results "$VR" --nonsense >/dev/null 2>&1
check "unknown flag is a usage error (exit 2)" test $? = 2
BEFORE=$(jq -c '.tiers' "$VR")
"$VERIFY" --results "$VR" --record windows_network=pass --record usb_attach_at_boot=fail >"$TMPD/rec.out" 2>&1; rc=$?
check "--record stores both keys, prints what it stored, exit 0" bash -c '[[ $1 == 0 ]] && grep -q "recorded windows_network=pass (T2)" "$2" && grep -q "recorded usb_attach_at_boot=fail (T3)" "$2"' _ "$rc" "$TMPD/rec.out"
check "--record merges into human and leaves tiers untouched" teq "$(jq -c '.human' "$VR")" '{"usb_attach_at_boot":"fail","windows_network":"pass"}' "$(jq -c '.tiers' "$VR")" "$BEFORE"
check "--record keeps mode 0600" test "$(stat -c %a "$VR")" = 600
# a fresh results file created by --record alone is valid and honest (no tiers, -1)
VR2=$TMPD/record-only.json
"$VERIFY" --results "$VR2" --record launcher_no_prompt=skip >/dev/null 2>&1
check "--record into a new file: no tiers, highest_passed -1" test "$(jq -c '[.tiers, .highest_passed]' "$VR2")" = '[{},-1]'
# recorded keys are used by the next run (windows_network=pass no longer needed); recorded fail makes the tier fail
if [[ $T0_STATUS == pass ]]; then
  VR3=$TMPD/human-fail.json
  "$VERIFY" --results "$VR3" --record windows_boots_to_desktop=fail --record windows_network=pass >/dev/null 2>&1
  VERIFY_FORCE_FAIL= "$VERIFY" --results "$VR3" --yes-tier 2 >"$TMPD/v4.out" 2>&1; rc=$?
  if [[ $(jq -r '.tiers["1"].status // ""' "$VR3") == pass && $(jq -r '.tiers["2"].checks.vm_defined // ""' "$VR3") == pass ]]; then
    check "recorded fail makes T2 fail (exit 1); the recorded pass for windows_network is used" teq "$rc" 1 "$(jq -r '.tiers["2"].status' "$VR3")" fail "$(jq -r '.tiers["2"].checks.windows_network' "$VR3")" pass
  else
    note "recorded-fail test not exercised: T1 or the VM definition does not pass on this host"
  fi
  # --existing-vm: T2 recorded as pass (existing) when its automatic checks pass
  VR4=$TMPD/existing.json
  "$VERIFY" --results "$VR4" --yes-tier 2 --existing-vm >"$TMPD/v5.out" 2>&1
  if [[ $(jq -r '.tiers["2"].status // ""' "$VR4") == pass ]]; then
    check "--existing-vm: T2 pass with existing=true and highest_passed 2" teq "$(jq -r '.tiers["2"].existing' "$VR4")" true "$(jq -r .highest_passed "$VR4")" 2
  else
    note "--existing-vm pass not exercised: T1/T2 automatic checks do not pass on this host"
  fi
fi

# the verify results feed report.sh (full chain) when T0 passed
if [[ $T0_STATUS == pass ]]; then
  R5=$(new_root)
  "$VERIFY" --results "$VR" >/dev/null 2>&1
  rep "$R5" --results "$VR" --date 2026-04-01 >"$TMPD/chain.out" 2>&1; rc=$?
  check "verify.sh T0 results -> report.sh: report written (exit 0), --check passes" bash -c '[[ $1 == 0 ]] && REPORT_ROOT=$2 "$3" --check >/dev/null' _ "$rc" "$R5" "$REPORT"
  CF=$(ls "$R5"/reports/*.md 2>/dev/null | head -n1)
  if [[ -n $CF ]]; then
    "$PRIV" --files "$CF" "$R5/COMPATIBILITY.md" >/dev/null 2>&1
    check "report from a real verify.sh run passes privacy-check --files (full local mode)" test $? = 0
    leak=0
    grep -qF -- "$USER" "$CF" && leak=1
    [[ -n $HOSTN ]] && grep -qiF -- "$HOSTN" "$CF" && leak=1
    check "report from a real verify.sh run has no \$USER or hostname" test "$leak" = 0
    check "report from a real verify.sh run: tier_passed 0, T1 not run" bash -c 'grep -q "^tier_passed: 0$" "$1" && grep -q "^| T1 | not run |" "$1"' _ "$CF"
  fi
fi

echo
if (( FAILS )); then echo "$FAILS test(s) FAILED"; exit 1; fi
echo "all tests passed"
