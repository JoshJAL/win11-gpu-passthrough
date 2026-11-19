#!/usr/bin/env bash
# privacy-check.sh - keep personal data of contributors out of a public repo.
#
# Usage:
#   tools/privacy-check.sh <base>..<head>     scan every blob added/modified by
#                                             every commit in the range, every
#                                             commit message, and every commit
#                                             author/committer identity
#   tools/privacy-check.sh --tree             scan all tracked files of HEAD
#   tools/privacy-check.sh --files <path>...  scan working-tree files only
#   --static-only                             skip the local-only dynamic denylist
#                                             (CI uses this)
#
# A <base> of all zeros (new branch push) or one that is not known locally
# means: merge-base of <head> with origin/main, else main, else all history.
#
# Env: PRIVACY_CHECK_NO_ALLOW=1  ignore tools/privacy-allow.txt (used by tests)
#
# Exit: 0 clean, 1 findings, 2 usage/internal error.
# Output per finding: file:line: <rule>: <redacted snippet>
#
# bash + grep -E only. The dynamic denylist (hostname, user, real name, DMI
# serials, Wi-Fi SSIDs, git e-mail) lives in memory only and is never written
# to disk or printed; findings from it only name the rule kind.

# shellcheck disable=SC2034  # DL_<kind> arrays are read through ${!aref} / local -n
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ALLOW_FILE="$SCRIPT_DIR/privacy-allow.txt"

STATIC_ONLY=0
NO_ALLOW=${PRIVACY_CHECK_NO_ALLOW:-0}
FINDINGS=0
SKIP_RULES=" "
TMP=""
TOPLEVEL=""

die() { echo "privacy-check: $*" >&2; exit 2; }

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- allow list
ALLOW_PATHS=()
ALLOW_LINE_GLOBS=()
ALLOW_LINE_STRS=()
ALLOW_DL_GLOBS=()
ALLOW_DL_STRS=()

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

load_allow() {
  [[ -r $ALLOW_FILE ]] || return 0
  [[ $NO_ALLOW == 1 ]] && return 0
  local line rest g s
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=$(trim "$line")
    [[ -z $line || $line == \#* ]] && continue
    case $line in
      path:*)
        ALLOW_PATHS+=("$(trim "${line#path:}")") ;;
      line:*)
        rest=${line#line:}
        [[ $rest == *" :: "* ]] || continue
        g=$(trim "${rest%% :: *}")
        s=$(trim "${rest#* :: }")
        [[ -n $g && -n $s ]] || continue
        ALLOW_LINE_GLOBS+=("$g")
        ALLOW_LINE_STRS+=("$s") ;;
      dlline:*)
        rest=${line#dlline:}
        [[ $rest == *" :: "* ]] || continue
        g=$(trim "${rest%% :: *}")
        s=$(trim "${rest#* :: }")
        [[ -n $g && -n $s ]] || continue
        ALLOW_DL_GLOBS+=("$g")
        ALLOW_DL_STRS+=("$s") ;;
    esac
  done < "$ALLOW_FILE"
}

path_allowed() {
  local p=$1 g
  [[ $NO_ALLOW == 1 ]] && return 1
  for g in "${ALLOW_PATHS[@]+"${ALLOW_PATHS[@]}"}"; do
    # shellcheck disable=SC2053
    [[ $p == $g ]] && return 0
  done
  return 1
}

# line_allowed <path> <matched text>: exact (case-insensitive) match of the
# matched text against a "line:" entry whose path glob matches.
line_allowed() {
  local p=$1 m=${2,,} i
  [[ $NO_ALLOW == 1 ]] && return 1
  for i in "${!ALLOW_LINE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ $p == ${ALLOW_LINE_GLOBS[$i]} ]] || continue
    [[ $m == "${ALLOW_LINE_STRS[$i],,}" ]] && return 0
  done
  return 1
}

# dl_line_ok <path> <line text> <kind>: true when, after removing every
# "dlline:" string that applies to <path> from the line, the denylist no longer
# matches it. Lets the owner's own public handle appear in LICENSE, clone URLs
# and CODEOWNERS without opening a hole for anything else on that line.
dl_line_ok() {
  local p=$1 t=${2,,} i s aref="DL_$3[@]"
  local dl=("${!aref}")
  [[ $NO_ALLOW == 1 ]] && return 1
  for i in "${!ALLOW_DL_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ $p == ${ALLOW_DL_GLOBS[$i]} ]] || continue
    s=${ALLOW_DL_STRS[$i],,}
    t=${t//"$s"/ }
  done
  ! grep -qwiF -f <(printf '%s\n' "${dl[@]}") <<<"$t"
}

# ----------------------------------------------------------- dynamic denylist
DL_KINDS=(hostname user realname dmi wifi email)
DL_hostname=(); DL_user=(); DL_realname=(); DL_dmi=(); DL_wifi=(); DL_email=()
DL_ACTIVE=0

# Words that are generic enough that matching them would only create noise.
dl_generic() {
  case ${1,,} in
    localhost|localdomain|archlinux|arch|linux|user|admin|root|home|host|hostname|\
    test|dev|www|app|box|nas|pc|lab|laptop|desktop|ubuntu|debian|fedora|windows|\
    default|unknown|none|n/a|the|you|me) return 0 ;;
  esac
  return 1
}

# dl_add <kind> <min length> <value>
dl_add() {
  local -n arr=DL_$1
  local min=$2 v
  v=$(trim "$3")
  [[ ${#v} -ge $min ]] || return 0
  dl_generic "$v" && return 0
  arr+=("$v")
}

build_denylist() {
  local h f v me gecos part line name type
  # hostname (kernel, command, file) + short form
  for h in "$(hostname 2>/dev/null)" "$(cat /proc/sys/kernel/hostname 2>/dev/null)" \
           "$(cat /etc/hostname 2>/dev/null)"; do
    [[ -n $h ]] || continue
    dl_add hostname 3 "$h"
    dl_add hostname 3 "${h%%.*}"
  done
  # user name
  me=$(id -un 2>/dev/null)
  if [[ -n $me && $me != root ]]; then dl_add user 3 "$me"; fi
  if [[ -n ${USER:-} && ${USER:-} != root ]]; then dl_add user 3 "$USER"; fi
  # real name from GECOS
  if [[ -n $me ]]; then
    gecos=$(getent passwd "$me" 2>/dev/null | cut -d: -f5)
    gecos=${gecos%%,*}
    if [[ -n $gecos ]]; then
      dl_add realname 4 "$gecos"
      for part in $gecos; do dl_add realname 4 "$part"; done
    fi
  fi
  # DMI identifiers
  for f in product_serial product_uuid board_serial chassis_serial product_sku chassis_asset_tag; do
    v=$(cat "/sys/class/dmi/id/$f" 2>/dev/null) || continue
    v=$(trim "$v")
    case ${v,,} in
      ""|"default string"|"to be filled by o.e.m."|none|"not specified"|"system serial number"|\
      "not applicable"|unknown|"n/a"|"0") continue ;;
    esac
    dl_add dmi 4 "$v"
  done
  # saved Wi-Fi SSIDs
  if command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r line; do
      type=${line##*:}
      name=${line%:*}
      case $type in 802-11-wireless|wifi) ;; *) continue ;; esac
      name=${name//\\:/:}
      dl_add wifi 4 "$name"
    done < <(timeout 5 nmcli -t -f NAME,TYPE connection show 2>/dev/null)
  fi
  # personal git e-mail
  v=$(git config user.email 2>/dev/null)
  v=$(trim "$v")
  case ${v,,} in
    ""|*@users.noreply.github.com) ;;
    *) dl_add email 4 "$v" ;;
  esac
  DL_ACTIVE=1
}

# ------------------------------------------------------------------- helpers
redact() {
  local s=$1
  if [[ ${#s} -gt 10 ]]; then
    s="${s:0:4}***${s: -2}"
  else
    s="${s:0:2}***"
  fi
  printf '%s' "$s"
}

# report <label> <line> <rule> <matched> [suffix]
report() {
  FINDINGS=$((FINDINGS + 1))
  if [[ -n $4 ]]; then
    printf '%s:%s: %s: %s%s\n' "$1" "$2" "$3" "$(redact "$4")" "${5:-}"
  else
    printf '%s:%s: %s%s\n' "$1" "$2" "$3" "${5:-}"
  fi
}

rule_on() { [[ $SKIP_RULES != *" $1 "* ]]; }

# placeholder-looking value (redacted / ellipsis / variable / <angle>)
is_placeholder() {
  local v=${1,,}
  case $v in
    *redacted*|*...*|*…*|'<'*|*'<'*'>'*|'$'*|'%'*|*'*'*|xxxx*) return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------------------- scanner
# scan_file <disk file> <label path> <allow path or ""> [suffix]
scan_file() {
  local f=$1 label=$2 apath=$3 suffix=${4:-}
  local row ln m name lc kind n i hex groups p1 p2 p3 p4 val

  if [[ -n $apath ]] && path_allowed "$apath"; then return 0; fi
  [[ -s $f ]] || return 0
  if ! grep -qI '' "$f" 2>/dev/null; then
    # binary: scan its printable runs (metadata, embedded strings)
    tr -c '[:print:]\n' '\n' < "$f" > "$f.str" && f="$f.str"
    label="$label(binary)"
  fi

  # lines through allowed(): $1 = matched text; honours "line:" allow entries
  la() { [[ -n $apath ]] && line_allowed "$apath" "$1"; }

  # 1. home directories
  if rule_on home; then
    while IFS= read -r row; do
      ln=${row%%:*}; m=${row#*:}
      name=${m##*/}
      while [[ $name == *[.-] ]]; do name=${name%?}; m=${m%?}; done
      case $name in user|USER|me|you|example|username|YOU) continue ;; esac
      la "$m" && continue
      report "$label" "$ln" home-path "$m" "$suffix"
    done < <(grep -noE '/(home|Users)/[A-Za-z0-9_][A-Za-z0-9._-]*' "$f")
    while IFS= read -r row; do
      ln=${row%%:*}; m=${row#*:}
      name=${m##*\\}
      case $name in user|USER|you|YOU|me|example|username|Public|Default|All|Administrator) continue ;; esac
      la "$m" && continue
      report "$label" "$ln" home-path "$m" "$suffix"
    done < <(grep -noE '[A-Za-z]:\\Users\\[A-Za-z0-9_][A-Za-z0-9._-]*' "$f")
  fi

  # 2. e-mail addresses
  if rule_on email; then
    while IFS= read -r row; do
      ln=${row%%:*}; m=${row#*:}; lc=${m,,}
      case $lc in
        *@users.noreply.github.com|noreply@github.com|*@example.com|*@example.org) continue ;;
      esac
      la "$m" && continue
      report "$label" "$ln" email "$m" "$suffix"
    done < <(grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f")
  fi

  # 3. MAC addresses
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}; lc=${m,,}; lc=${lc//-/:}
    case $lc in 00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|52:54:00:*) continue ;; esac
    la "$m" && continue
    report "$label" "$ln" mac "$m" "$suffix"
  done < <(grep -noEw '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}' "$f")

  # 4. UUIDs
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}; lc=${m,,}
    case $lc in 00000000-0000-0000-0000-000000000000|12345678-1234-1234-1234-123456789abc) continue ;; esac
    la "$m" && continue
    report "$label" "$ln" uuid "$m" "$suffix"
  done < <(grep -noEw '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$f")

  # 5a. IPv4 (any 4-part dotted quad; 5+ parts or octet > 255 = version-like)
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}
    IFS=. read -r p1 p2 p3 p4 val <<< "$m"
    [[ -z $val && -n $p4 ]] || continue
    for n in $p1 $p2 $p3 $p4; do
      [[ ${#n} -le 3 && $((10#$n)) -le 255 ]] || continue 2
    done
    case $m in
      127.0.0.1|0.0.0.0|1.1.1.1|8.8.8.8|192.168.122.*|255.255.255.*) continue ;;
    esac
    la "$m" && continue
    report "$label" "$ln" ipv4 "$m" "$suffix"
  done < <(grep -noE '[0-9]+(\.[0-9]+){3,}' "$f")

  # 5b. IPv6: full form (4+ groups) and compressed (::) form
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}; lc=${m,,}
    # six 2-digit groups is a MAC: rule 3 owns it
    [[ $lc =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] && continue
    la "$m" && continue
    report "$label" "$ln" ipv6 "$m" "$suffix"
  done < <(grep -noEw '([0-9A-Fa-f]{1,4}:){3,}[0-9A-Fa-f]{1,4}' "$f")
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}; lc=${m,,}
    [[ $lc == *::* && $lc == *[0-9]* ]] || continue
    [[ $lc == '::1' || $lc == 'fe80::' ]] && continue
    hex=${lc//:/ }; groups=0
    for n in $hex; do groups=$((groups + 1)); done
    [[ $groups -ge 2 ]] || continue
    la "$m" && continue
    report "$label" "$ln" ipv6 "$m" "$suffix"
  done < <(grep -noEw '([0-9A-Fa-f]{1,4}:){0,7}:([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?' "$f")

  # 6. kernel command line identifiers
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}
    [[ $m =~ ^[^A-Za-z0-9_] ]] && m=${m#?}
    case $m in
      root=*) val=${m##*=} ;;
      *)      val=${m#*=} ;;
    esac
    is_placeholder "$val" && continue
    la "$m" && continue
    report "$label" "$ln" cmdline-id "$m" "$suffix"
  done < <(grep -noE "(^|[^A-Za-z0-9_])(root=(PART)?UUID|cryptdevice|resume)=[^[:space:]\"'\`,;)]+" "$f")
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}
    [[ $m =~ ^[^A-Za-z0-9_] ]] && m=${m#?}
    val=${m#*=}
    is_placeholder "$val" && continue
    la "$m" && continue
    report "$label" "$ln" cmdline-id "$m" "$suffix"
  done < <(grep -noE "(^|[^=A-Za-z0-9_])PARTUUID=[^[:space:]\"'\`,;)]+" "$f")

  # 7. /dev/disk/by-{uuid,id,partuuid}/<value>
  while IFS= read -r row; do
    ln=${row%%:*}; m=${row#*:}
    val=${m#/dev/disk/by-*/}
    is_placeholder "$val" && continue
    la "$m" && continue
    report "$label" "$ln" disk-id "$m" "$suffix"
  done < <(grep -noE "/dev/disk/by-(uuid|id|partuuid)/[^[:space:]\"'\`,;)]+" "$f")

  # local-only dynamic denylist (names the kind, never the value)
  if [[ $STATIC_ONLY == 0 && $DL_ACTIVE == 1 ]]; then
    for kind in "${DL_KINDS[@]}"; do
      local aref="DL_${kind}[@]"; local dl=("${!aref}")
      [[ ${#dl[@]} -gt 0 ]] || continue
      while IFS= read -r row; do
        if [[ -n $apath ]] && dl_line_ok "$apath" "${row#*:}" "$kind"; then continue; fi
        report "$label" "${row%%:*}" "local-denylist:$kind" "" "$suffix"
      done < <(grep -nwiF -f <(printf '%s\n' "${dl[@]}") "$f")
    done
  fi
}

# --------------------------------------------------------------- modes
blob_to_tmp() { git cat-file blob "$1" > "$TMP/blob" 2>/dev/null; }

scan_tree() {
  local entry meta path sha type
  git rev-parse --verify -q 'HEAD^{commit}' >/dev/null || die "no HEAD commit"
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*}; path=${entry#*$'\t'}
    sha=${meta##* }; type=${meta#* }; type=${type%% *}
    [[ $type == blob ]] || continue
    blob_to_tmp "$sha" || continue
    scan_file "$TMP/blob" "$path" "$path"
  done < <(git ls-tree -r -z HEAD)
}

scan_files() {
  local p rel abs
  for p in "$@"; do
    [[ -f $p ]] || die "not a file: $p"
    abs=$(realpath -m -- "$p")
    rel=$p
    if [[ -n $TOPLEVEL && $abs == "$TOPLEVEL"/* ]]; then rel=${abs#"$TOPLEVEL"/}; fi
    scan_file "$p" "$rel" "$rel"
  done
}

is_zero() { [[ $1 =~ ^0+$ ]]; }

default_base() {
  local head=$1 ref mb
  for ref in origin/main main; do
    mb=$(git merge-base "$head" "$ref" 2>/dev/null) && [[ -n $mb ]] && { printf '%s' "$mb"; return; }
  done
  printf ''
}

scan_range() {
  local spec=$1 base head hc bc c blob mode path meta key ident id i
  [[ $spec == *...* || $spec != *..* ]] && usage
  base=${spec%%..*}; head=${spec##*..}
  [[ -n $base && -n $head ]] || usage
  hc=$(git rev-parse --verify -q "$head^{commit}") || die "unknown head: $head"
  bc=""
  if ! is_zero "$base"; then
    bc=$(git rev-parse --verify -q "$base^{commit}") || bc=""
  fi
  [[ -n $bc ]] || bc=$(default_base "$hc")

  local revargs=("$hc")
  [[ -n $bc ]] && revargs+=("^$bc")
  local commits
  mapfile -t commits < <(git rev-list --reverse "${revargs[@]}")
  declare -A done_blob=()

  for c in "${commits[@]+"${commits[@]}"}"; do
    local short=${c:0:7}

    # (b) commit message
    git log -1 --format=%B "$c" > "$TMP/msg"
    scan_file "$TMP/msg" "commit:$short/message" ""

    # (c) author and committer identity: e-mail policy + other static rules
    for ident in author committer; do
      if [[ $ident == author ]]; then
        id=$(git log -1 --format='%an%n%ae' "$c")
      else
        id=$(git log -1 --format='%cn%n%ce' "$c")
      fi
      printf '%s\n' "$id" > "$TMP/ident"
      local iemail
      iemail=$(sed -n 2p "$TMP/ident")
      case ${iemail,,} in
        *@users.noreply.github.com|noreply@github.com) ;;
        *) report "commit:$short/$ident" 2 commit-email "$iemail" \
             " (only *@users.noreply.github.com allowed)" ;;
      esac
      SKIP_RULES=" email "
      scan_file "$TMP/ident" "commit:$short/$ident" "commit-identity"
      SKIP_RULES=" "
    done

    # (a) every blob added or modified by this commit (not just the final tree,
    # history is public too). -m: merge commits diff against each parent.
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      # meta: ":oldmode newmode oldsha newsha status"
      set -- $meta
      mode=$2; blob=$4
      [[ $mode == 160000 ]] && continue            # submodule
      key="$blob:$path"
      [[ -n ${done_blob[$key]+x} ]] && continue
      done_blob[$key]=1
      blob_to_tmp "$blob" || continue
      scan_file "$TMP/blob" "$path" "$path" " [commit $short]"
    done < <(git diff-tree -r -m --root --no-commit-id --diff-filter=AM -z "$c")
  done
}

# ------------------------------------------------------------------ main
MODE=""; RANGE=""; FILES=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --static-only) STATIC_ONLY=1 ;;
    --tree) [[ -z $MODE ]] || usage; MODE=tree ;;
    --files) [[ -z $MODE ]] || usage; MODE=files; shift; FILES=("$@"); break ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [[ -z $MODE ]] || usage; MODE=range; RANGE=$1 ;;
  esac
  shift
done
[[ -n $MODE ]] || usage
[[ $MODE != files || ${#FILES[@]} -gt 0 ]] || usage

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || TOPLEVEL=""
[[ $MODE == files || -n $TOPLEVEL ]] || die "not inside a git repository"
TMP=$(mktemp -d) || die "mktemp failed"

load_allow
[[ $STATIC_ONLY == 1 ]] || build_denylist

case $MODE in
  tree)  scan_tree ;;
  files) scan_files "${FILES[@]}" ;;
  range) scan_range "$RANGE" ;;
esac

if [[ $FINDINGS -eq 0 ]]; then
  echo "privacy-check: PASS"
  exit 0
fi
echo "privacy-check: FAIL ($FINDINGS findings)"
exit 1
