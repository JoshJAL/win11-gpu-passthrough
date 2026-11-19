#!/usr/bin/env bash
# report.sh - turn a verify.sh results file into a report under reports/, and keep COMPATIBILITY.md
# (the matrix of the latest report per distro/desktop/hardware/form factor) in sync.
#
#   tools/report.sh [--results FILE] [--date YYYY-MM-DD] [--note "text"]...
#       validate results.local.json (tiers cumulative, highest_passed consistent, only allowlisted
#       keys), write reports/<date>_<distro>_<desktop>_<hwkey>_<form>.md, regenerate COMPATIBILITY.md
#   tools/report.sh --regen      regenerate COMPATIBILITY.md from reports/ only
#   tools/report.sh --check      write nothing; verify every report and that COMPATIBILITY.md is current
#                                (used by CI; needs no results file; works with zero reports)
#
#   --results FILE   default <bundle>/results.local.json
#   --date D         report date, default today (needed to write a second report for the same machine
#                    on one day)
#   --note "text"    free text, repeatable. Notes are written by a human or agent, so they go through
#                    tools/privacy-check.sh before anything is pushed.
#
# ReportHonest: the recorded tier is the highest tier that PASSED, nothing more. A T0-only report and
# a NO-GO report (tier -1, T0 failed) are valid, honest reports. An inconsistent results file is
# refused. The report holds only allowlisted profile keys, check names and statuses.
#
# Exit: 0 ok, 1 refused / check failed / error, 2 usage.
# Env (tests): REPORT_ROOT=<dir> uses <dir>/reports, <dir>/COMPATIBILITY.md and <dir>/results.local.json
set -uo pipefail
export LC_ALL=C
shopt -s nullglob

B=${REPORT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
REPORTS=$B/reports
COMPAT=$B/COMPATIBILITY.md
RESULTS=$B/results.local.json
DATE=$(date +%F)
NOTES=()
MODE=write

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die_usage() { echo "report.sh: $*" >&2; exit 2; }
die() { echo "report.sh: $*" >&2; exit 1; }

while (( $# )); do
  case $1 in
    --results) (( $# >= 2 )) || die_usage "--results needs a file"; RESULTS=$2; shift ;;
    --date) (( $# >= 2 )) || die_usage "--date needs YYYY-MM-DD"; DATE=$2; shift ;;
    --note) (( $# >= 2 )) || die_usage "--note needs text"; NOTES+=("$2"); shift ;;
    --regen) MODE=regen ;;
    --check) MODE=check ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done
[[ $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die_usage "--date must look like YYYY-MM-DD"
command -v jq >/dev/null 2>&1 || die "jq is required"

# ------------------------------------------------------------------------------------------------
# Tables
# ------------------------------------------------------------------------------------------------
# front matter keys, in the order they are written
FM_KEYS=(date distro distro_version distro_id_like desktop session_type hardware_key form_factor machine
  cpu host_gpu pt_gpu iommu_mgaw kernel bootloader firewall libvirt qemu looking_glass verdict tier_passed existing_vm)
# profile keys a results file may carry (anything else is refused: privacy)
PROFILE_KEYS=(PROFILE_VERSION DISTRO_ID DISTRO_ID_LIKE DISTRO_VERSION_ID KERNEL INIT BOOTLOADER FIREWALL
  PKG_MANAGER DESKTOP SESSION_TYPE CPU_VENDOR CPU_MODEL CPU_PHYS_BITS IOMMU IOMMU_VENDOR IOMMU_MGAW
  HOST_GPU_VENDOR HOST_GPU_MODEL HOST_GPU_PCI PT_GPU_VENDOR PT_GPU_MODEL PT_GPU_PCI PT_GROUP_ISOLATED
  PT_GROUP_SIZE FORM_FACTOR SYS_VENDOR PRODUCT_NAME RAM_GIB IMAGE_FS DISPLAYS_HOST DISPLAYS_ON_PT_GPU
  LIBVIRT_VERSION QEMU_VERSION LOOKING_GLASS_VERSION WARN_COUNT NOGO_COUNT VERDICT)
PROFILE_REQUIRED=(DISTRO_ID DESKTOP HOST_GPU_VENDOR PT_GPU_VENDOR FORM_FACTOR VERDICT)
TIER_STATUSES=("pass" "pass (existing)" "fail" "incomplete" "not run")
MAX_TIER=3

# ------------------------------------------------------------------------------------------------
# String helpers
# ------------------------------------------------------------------------------------------------
san() {   # lowercase, only [a-z0-9._-], anything else becomes -, empty becomes unknown
  local s=${1,,}
  s=${s//[^a-z0-9._-]/-}
  printf '%s' "${s:-unknown}"
}
esc_q() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
unq() {   # strip YAML double quotes written by esc_q
  local s=$1
  if [[ $s == \"*\" && ${#s} -ge 2 ]]; then s=${s:1:${#s}-2}; s=${s//\\\"/\"}; s=${s//\\\\/\\}; fi
  printf '%s' "$s"
}
tier_text() { if (( $1 < 0 )); then printf 'none (T0 failed)'; else printf 'T%s' "$1"; fi; }

# ------------------------------------------------------------------------------------------------
# Reading a written report: front matter into FM[], table statuses into ST[]
# ------------------------------------------------------------------------------------------------
declare -A FM=()
declare -a ST=()
parse_report() {   # parse_report <file>; fails when there is no front matter
  local f=$1 line first=1 in_fm=0 k v
  FM=(); ST=()
  while IFS= read -r line || [[ -n $line ]]; do
    if (( first )); then
      first=0
      [[ $line == --- ]] || return 1
      in_fm=1; continue
    fi
    if (( in_fm == 1 )); then
      if [[ $line == --- ]]; then in_fm=2; continue; fi
      if [[ $line =~ ^([a-z_]+):[[:space:]]*(.*)$ ]]; then
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        FM[$k]=$(unq "$v")
      fi
      continue
    fi
    if [[ $line =~ ^\|[[:space:]]T([0-9])[[:space:]]*\|[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\| ]]; then
      ST[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
  done <"$f"
  (( in_fm == 2 ))
}

# report_problems <file>: print one line per problem, return the count in $PROBLEMS
PROBLEMS=0
problem() { echo "reports/$1: $2"; PROBLEMS=$((PROBLEMS + 1)); }
check_report() {
  local f=$1 name k want n hp i s ok
  name=$(basename "$f")
  if ! parse_report "$f"; then problem "$name" "no front matter (file must start with a --- block)"; return; fi
  for k in "${FM_KEYS[@]}"; do
    [[ -n ${FM[$k]+x} ]] || problem "$name" "front matter lacks key: $k"
  done
  if [[ -n ${FM[date]+x} && -n ${FM[distro]+x} && -n ${FM[desktop]+x} && -n ${FM[hardware_key]+x} && -n ${FM[form_factor]+x} ]]; then
    want="${FM[date]}_$(san "${FM[distro]}")_$(san "${FM[desktop]}")_$(san "${FM[hardware_key]}")_$(san "${FM[form_factor]}").md"
    [[ $name == "$want" ]] || problem "$name" "filename does not match its front matter (expected $want)"
    [[ ${FM[date]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || problem "$name" "date is not YYYY-MM-DD"
  fi
  n=${FM[tier_passed]:-}
  if ! [[ $n =~ ^-?[0-9]+$ ]] || (( n < -1 || n > MAX_TIER )); then
    problem "$name" "tier_passed must be an integer from -1 to $MAX_TIER (got: ${n:-empty})"
    return
  fi
  hp=-1
  for ((i = 0; i <= MAX_TIER; i++)); do
    s=${ST[i]:-not run}
    ok=0
    for k in "${TIER_STATUSES[@]}"; do [[ $s == "$k" ]] && ok=1; done
    (( ok )) || problem "$name" "table row T$i has an unknown status: $s"
    if [[ $s == pass || $s == "pass (existing)" ]] && (( hp == i - 1 )); then hp=$i; fi
  done
  (( hp == n )) || problem "$name" "tier_passed is $n but the table says the highest passed tier is $hp"
  if [[ ${ST[2]:-} == "pass (existing)" && ${FM[existing_vm]:-} != true ]]; then
    problem "$name" "table says T2 passed on an existing VM but existing_vm is not true"
  fi
  [[ ${FM[existing_vm]:-false} == true || ${FM[existing_vm]:-false} == false ]] || problem "$name" "existing_vm must be true or false"
}

# ------------------------------------------------------------------------------------------------
# COMPATIBILITY.md
# ------------------------------------------------------------------------------------------------
compat_text() {   # prints the whole file; reads reports/*.md (latest per key, by date then filename)
  local f name key d cur tier link row
  local -A LATEST_DATE=() LATEST_FILE=() ROW=()
  for f in "$REPORTS"/*.md; do
    name=$(basename "$f")
    parse_report "$f" || continue
    key="${FM[distro]:-?}|${FM[desktop]:-?}|${FM[hardware_key]:-?}|${FM[form_factor]:-?}"
    d=${FM[date]:-0000-00-00}
    cur=${LATEST_DATE[$key]:-}
    if [[ -z $cur || $d > $cur || ( $d == "$cur" && $name > ${LATEST_FILE[$key]} ) ]]; then
      tier=$(tier_text "${FM[tier_passed]:--1}")
      link="[report](reports/$name)"
      row="| ${FM[distro]:-?} | ${FM[desktop]:-?} | ${FM[hardware_key]:-?} | ${FM[machine]//|//} | $tier | ${FM[verdict]:-?} | $d | $link |"
      LATEST_DATE[$key]=$d; LATEST_FILE[$key]=$name; ROW[$key]=$row
    fi
  done
  cat <<'EOF'
<!-- generated by tools/report.sh; do not edit -->
# Compatibility

One row per distro / desktop / hardware / form factor, from the latest report for that combination.
"Highest tier" is the highest verification tier that passed on that machine: T0 read-only facts,
T1 host install, T2 VM and Windows, T3 GPU, USB and Looking Glass. A lower tier is not a failure of
the project; it is how far the person got. Add yours with `./handoff.sh`, `./verify.sh` and
`tools/report.sh`.

| Distro | Desktop | Hardware | Machine | Highest tier | Verdict | Date | Report |
|---|---|---|---|---|---|---|---|
EOF
  if (( ${#ROW[@]} == 0 )); then
    echo '| (no reports yet) | | | | | | | |'
  else
    while IFS= read -r key; do printf '%s\n' "${ROW[$key]}"; done < <(printf '%s\n' "${!ROW[@]}" | sort -t'|' -k1,1 -k2,2 -k3,3 -k4,4)
  fi
}

check_all() {   # runs check_report over every report; sets PROBLEMS
  local f
  PROBLEMS=0
  for f in "$REPORTS"/*.md; do check_report "$f"; done
}

regen_compat() {
  local tmp
  check_all
  (( PROBLEMS == 0 )) || { echo "report.sh: not regenerating COMPATIBILITY.md while reports have problems" >&2; return 1; }
  tmp=$(mktemp "$B/.compat.XXXXXX") || return 1
  compat_text >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$COMPAT" || { rm -f "$tmp"; return 1; }
  echo "wrote $COMPAT"
}

# ------------------------------------------------------------------------------------------------
# Modes
# ------------------------------------------------------------------------------------------------
if [[ $MODE == check ]]; then
  check_all
  n=0; for f in "$REPORTS"/*.md; do n=$((n + 1)); done
  tmp=$(mktemp) || die "mktemp failed"
  trap 'rm -f "$tmp"' EXIT
  compat_text >"$tmp"
  if [[ ! -e $COMPAT ]]; then
    echo "COMPATIBILITY.md: missing (run tools/report.sh --regen)"; PROBLEMS=$((PROBLEMS + 1))
  elif ! cmp -s "$tmp" "$COMPAT"; then
    echo "COMPATIBILITY.md: stale or hand-edited (run tools/report.sh --regen)"; PROBLEMS=$((PROBLEMS + 1))
  fi
  if (( PROBLEMS )); then echo "report check: FAILED ($PROBLEMS problem(s), $n reports)"; exit 1; fi
  echo "report check: OK ($n reports)"
  exit 0
fi

if [[ $MODE == regen ]]; then
  regen_compat || exit 1
  exit 0
fi

# ---- default mode: validate results, write the report ----
[[ -r $RESULTS ]] || die "no results file: $RESULTS (run ./verify.sh first)"
jq -e . "$RESULTS" >/dev/null 2>&1 || die "$RESULTS is not valid JSON"

errs=$(jq -r --argjson allowed "$(printf '%s\n' "${PROFILE_KEYS[@]}" | jq -Rn '[inputs]')" \
  --argjson required "$(printf '%s\n' "${PROFILE_REQUIRED[@]}" | jq -Rn '[inputs]')" '
  def stat($t): .tiers[$t | tostring].status;
  def has_t($t): (.tiers | has($t | tostring));
  . as $r
  | [
    (if .schema != 1 then "schema is not 1 (old or unknown results format)" else empty end),
    ((keys - ["schema","date","profile","tiers","human","highest_passed"])
       | if length > 0 then "unexpected top-level keys: " + join(",") else empty end),
    ((["schema","date","profile","tiers","human","highest_passed"] - keys)
       | if length > 0 then "missing top-level keys: " + join(",") else empty end),
    (if (.profile | type) != "object" then "profile is not an object"
     else
       ((.profile | keys) - $allowed | map(select(test("^NOGO_[0-9]+$") | not))
          | if length > 0 then "profile has keys outside the allowlist: " + join(",") else empty end),
       ($required - (.profile | keys) | if length > 0 then "profile lacks required keys: " + join(",") else empty end),
       (.profile | to_entries[] | select((.value | type) != "string" or (.value | test("[[:cntrl:]]")))
          | "profile value for \(.key) is not a plain string"),
       (if (.profile.VERDICT // "") | IN("GO", "NO-GO") | not then "profile VERDICT must be GO or NO-GO" else empty end)
     end),
    (if (.tiers | type) != "object" then "tiers is not an object"
     else
       ((.tiers | keys) - ["0","1","2","3"] | if length > 0 then "unknown tiers: " + join(",") else empty end),
       (if has_t(0) | not then "tier 0 is missing" else empty end),
       (range(0; 4) as $t | select(has_t($t))
          | (.tiers[$t | tostring]) as $x
          | (if ($x.status // "") | IN("pass", "fail", "incomplete") | not then "tier \($t) has status \($x.status)" else empty end),
            (if ($x.existing | type) != "boolean" then "tier \($t) existing is not a boolean" else empty end),
            (if ($x.checks | type) != "object" or ($x.checks | length) == 0 then "tier \($t) has no checks"
             else
               ($x.checks | to_entries[] | select(.value | IN("pass","fail","skip","need") | not) | "tier \($t) check \(.key) has status \(.value)"),
               (if $x.status == "pass" and ([$x.checks[] | select(. == "fail" or . == "need")] | length) > 0 then "tier \($t) says pass but has a failed or needed check" else empty end),
               (if $x.status == "fail" and ([$x.checks[] | select(. == "fail")] | length) == 0 then "tier \($t) says fail but no check failed" else empty end),
               (if $x.status == "incomplete" and ([$x.checks[] | select(. == "need")] | length) == 0 then "tier \($t) says incomplete but no check is needed" else empty end)
             end),
            (if $t > 0 and (has_t($t - 1) | not) then "tier \($t) ran but tier \($t - 1) is absent"
             elif $t > 0 and stat($t - 1) != "pass" then "tier \($t) is recorded although tier \($t - 1) did not pass (tiers are cumulative)"
             else empty end))
     end),
    (if (.human | type) != "object" then "human is not an object"
     else (.human | to_entries[] | select(.value | IN("pass","fail","skip") | not) | "human key \(.key) has value \(.value)") end),
    (try (
       (reduce range(0; 4) as $i (-1; if . == $i - 1 and ($r.tiers[$i | tostring].status? == "pass") then $i else . end)) as $hp
       | (if .highest_passed != $hp then "highest_passed is \(.highest_passed) but the tiers say \($hp)" else empty end),
         (if (.profile.VERDICT == "NO-GO") and ($hp >= 0 or stat(0) != "fail") then "VERDICT is NO-GO so tier 0 must be fail and highest_passed -1" else empty end)
     ) catch "could not compute highest_passed")
  ] | .[]' "$RESULTS" 2>&1) || true
if [[ -n $errs ]]; then
  echo "report.sh: refusing $RESULTS (ReportHonest):" >&2
  sed 's/^/  - /' <<<"$errs" >&2
  exit 1
fi

declare -A PR=()
while IFS=$'\t' read -r k v; do PR[$k]=$v; done < <(jq -r '.profile | to_entries[] | "\(.key)\t\(.value)"' "$RESULTS")
HP=$(jq -r '.highest_passed' "$RESULTS")
EXISTING=$(jq -r '.tiers["2"].existing // false' "$RESULTS")

distro=$(san "${PR[DISTRO_ID]}")
desktop=$(san "${PR[DESKTOP]}")
hwkey="$(san "${PR[HOST_GPU_VENDOR]}")-host_$(san "${PR[PT_GPU_VENDOR]}")-pt"
form=$(san "${PR[FORM_FACTOR]}")
OUT=$REPORTS/${DATE}_${distro}_${desktop}_${hwkey}_${form}.md
if [[ -e $OUT ]]; then
  echo "report.sh: $OUT already exists: same machine twice on one day: pass --date" >&2
  exit 1
fi
mkdir -p "$REPORTS" || die "cannot create $REPORTS"

machine="${PR[SYS_VENDOR]:-} ${PR[PRODUCT_NAME]:-}"
machine=${machine# }; machine=${machine% }
declare -A FMV=(
  [date]=$DATE [distro]=$distro [distro_version]=${PR[DISTRO_VERSION_ID]:-} [distro_id_like]=${PR[DISTRO_ID_LIKE]:-}
  [desktop]=$desktop [session_type]=${PR[SESSION_TYPE]:-} [hardware_key]=$hwkey [form_factor]=$form
  [machine]=$machine [cpu]=${PR[CPU_MODEL]:-} [host_gpu]=${PR[HOST_GPU_MODEL]:-} [pt_gpu]=${PR[PT_GPU_MODEL]:-}
  [iommu_mgaw]=${PR[IOMMU_MGAW]:-} [kernel]=${PR[KERNEL]:-} [bootloader]=${PR[BOOTLOADER]:-}
  [firewall]=${PR[FIREWALL]:-} [libvirt]=${PR[LIBVIRT_VERSION]:-} [qemu]=${PR[QEMU_VERSION]:-}
  [looking_glass]=${PR[LOOKING_GLASS_VERSION]:-} [verdict]=${PR[VERDICT]}
)

emit_report() {
  local k t s cell checks line
  echo '---'
  for k in "${FM_KEYS[@]}"; do
    case $k in
      tier_passed) echo "tier_passed: $HP" ;;
      existing_vm) echo "existing_vm: $EXISTING" ;;
      *) printf '%s: "%s"\n' "$k" "$(esc_q "${FMV[$k]}")" ;;
    esac
  done
  echo '---'
  echo
  echo "# Report: $distro / $desktop / $hwkey ($form)"
  echo
  echo "Highest tier passed: $(tier_text "$HP"). Verdict: ${PR[VERDICT]}. This report records only the highest tier that passed, nothing more; it was generated by tools/report.sh from a verify.sh results file."
  echo
  echo '| Tier | Status | Checks |'
  echo '|---|---|---|'
  for ((t = 0; t <= MAX_TIER; t++)); do
    s=$(jq -r --arg t "$t" '.tiers[$t] // empty | if .status == "pass" and .existing then "pass (existing)" else .status end' "$RESULTS")
    if [[ -z $s ]]; then s="not run"; checks="-"
    else checks=$(jq -r --arg t "$t" '.tiers[$t].checks | to_entries | map("\(.key)=\(.value)") | join(", ")' "$RESULTS"); fi
    echo "| T$t | $s | $checks |"
  done
  echo
  echo '## Failed or missing checks'
  echo
  cell=0
  while IFS= read -r line; do [[ -n $line ]] && { echo "$line"; cell=1; }; done < <(jq -r '
    range(0; 4) as $t | select(.tiers | has($t | tostring))
    | .tiers[$t | tostring].checks | to_entries[] | select(.value != "pass")
    | "- T\($t) \(.key): " + (if .value == "fail" then "failed" elif .value == "need" then "missing (needs the human, or the VM running)" else "skipped" end)' "$RESULTS")
  if [[ ${PR[VERDICT]} == NO-GO ]]; then
    for ((t = 1; t <= ${PR[NOGO_COUNT]:-0}; t++)); do echo "- blocker: ${PR[NOGO_$t]:-?}"; cell=1; done
  fi
  (( cell )) || echo 'none'
  echo
  echo '## Notes'
  echo
  echo '<!-- Notes are free text from the human or agent. They go through tools/privacy-check.sh before any push. -->'
  echo
  if (( ${#NOTES[@]} )); then
    for line in "${NOTES[@]}"; do echo "- ${line//$'\n'/ }"; done
  else
    echo 'none'
  fi
  echo
  echo '## Known issues'
  echo
  echo '<!-- The agent fills this in: symptoms seen on this machine, with LESSONS.md entries. -->'
  echo
  echo 'none recorded'
}

( set -o noclobber; emit_report >"$OUT" ) || die "could not write $OUT"
echo "wrote $OUT"
regen_compat || exit 1
exit 0
