#!/usr/bin/env bash
# Tests for tools/privacy-check.sh. Exits non-zero if any expectation fails.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$ROOT/tools/privacy-check.sh"
FAILS=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }

# expect <name> <expected rc> <actual rc>
expect() { if [[ $3 -eq $2 ]]; then ok "$1"; else bad "$1 (expected exit $2, got $3)"; fi; }

# --- static fixtures (PRIVACY_CHECK_NO_ALLOW: fixtures are allow-listed) ---
for f in "$HERE"/leak-*.txt; do
  PRIVACY_CHECK_NO_ALLOW=1 "$CHECK" --static-only --files "$f" >/dev/null 2>&1
  rc=$?; expect "fixture ${f##*/} is flagged" 1 $rc
done
PRIVACY_CHECK_NO_ALLOW=1 "$CHECK" --static-only --files "$HERE/clean.txt" >"$TMPD/clean.out" 2>&1
rc=$?
expect "fixture clean.txt passes" 0 $rc
[[ $rc -eq 0 ]] || cat "$TMPD/clean.out"

# allow-list default: fixture path is skipped without the env override
"$CHECK" --static-only --files "$HERE/leak-home.txt" >/dev/null 2>&1
expect "allow-listed path is skipped without PRIVACY_CHECK_NO_ALLOW" 0 $?

# each leak fixture must trip its own rule
declare -A RULE=([home]=home-path [email]=email [mac]=mac [uuid]=uuid [ipv4]=ipv4
                 [ipv6]=ipv6 [cmdline]=cmdline-id [diskid]=disk-id)
for k in "${!RULE[@]}"; do
  out=$(PRIVACY_CHECK_NO_ALLOW=1 "$CHECK" --static-only --files "$HERE/leak-$k.txt" 2>&1)
  if grep -q ": ${RULE[$k]}:" <<<"$out"; then ok "leak-$k reports rule ${RULE[$k]}"
  else bad "leak-$k reports rule ${RULE[$k]}"; echo "$out"; fi
done

# --- local denylist: hostname must be flagged and never printed ---
HN=$(hostname 2>/dev/null)
if [[ ${#HN} -ge 4 ]]; then
  printf 'something %s something\n' "$HN" > "$TMPD/hostfile.txt"
  out=$("$CHECK" --files "$TMPD/hostfile.txt" 2>&1); rc=$?
  expect "local denylist flags hostname" 1 $rc
  if grep -qiF -- "$HN" <<<"$out"; then bad "local denylist output leaks the hostname"
  else ok "local denylist output does not contain the hostname"; fi
  grep -q 'local-denylist:hostname' <<<"$out" && ok "rule named local-denylist:hostname" \
    || bad "rule named local-denylist:hostname"
  "$CHECK" --static-only --files "$TMPD/hostfile.txt" >/dev/null 2>&1
  expect "--static-only ignores the hostname" 0 $?
else
  echo "SKIP  hostname shorter than 4 chars"
fi

# --- commit-scan tests in a throwaway repo ---
R="$TMPD/repo"
mkdir -p "$R/tools" && cd "$R" || exit 2
git init -q -b main . 
cp "$ROOT/tools/privacy-check.sh" "$ROOT/tools/privacy-allow.txt" tools/
git config user.name "Test Contributor"
git config user.email "1234+tester@users.noreply.github.com"
git config commit.gpgsign false
echo base > base.txt && git add base.txt && git commit -q -m "base"
BASE=$(git rev-parse HEAD)

git checkout -q -b t1
echo a > a.txt && git add a.txt
git commit -q -m "fix thing, reported by someone@gmail.com"
tools/privacy-check.sh --static-only "$BASE..HEAD" >/dev/null 2>&1
expect "commit message with personal e-mail fails" 1 $?

git checkout -q main && git checkout -q -b t2
echo b > b.txt && git add b.txt
GIT_AUTHOR_EMAIL="someone@gmail.com" GIT_AUTHOR_NAME="Someone" git commit -q -m "clean message"
tools/privacy-check.sh --static-only "$BASE..HEAD" >/dev/null 2>&1
expect "non-noreply author e-mail fails" 1 $?

git checkout -q main && git checkout -q -b t3
echo c > c.txt && git add c.txt
git commit -q -m "add c"
tools/privacy-check.sh --static-only "$BASE..HEAD" >/dev/null 2>&1
expect "clean commit with noreply author passes" 0 $?

# leak only in an intermediate commit (deleted again before HEAD) must fail
git checkout -q main && git checkout -q -b t4
echo "path=/home/jdoe42/x" > leak.txt && git add leak.txt && git commit -q -m "add file"
git rm -q leak.txt && git commit -q -m "remove file"
tools/privacy-check.sh --static-only "$BASE..HEAD" >/dev/null 2>&1
expect "leak in intermediate commit (deleted later) fails" 1 $?

# new-branch form: all-zero base resolves via merge-base with main
tools/privacy-check.sh --static-only "0000000000000000000000000000000000000000..HEAD" >/dev/null 2>&1
expect "all-zero base falls back to merge-base and still fails" 1 $?
git checkout -q t3
tools/privacy-check.sh --static-only "0000000000000000000000000000000000000000..HEAD" >/dev/null 2>&1
expect "all-zero base on clean branch passes" 0 $?

# "dlline:" lets one exact string through the LOCAL denylist but still checks the rest of the line.
ME=$(id -un)
if [[ ${#ME} -ge 3 && $ME != root ]]; then
  printf '\ndlline: LICENSE :: Copyright (c) 2026 %s\n' "$ME" >> tools/privacy-allow.txt
  printf 'Copyright (c) 2026 %s\n' "$ME" > LICENSE
  tools/privacy-check.sh --files LICENSE >/dev/null 2>&1
  expect "dlline: allowed string passes the local denylist" 0 $?
  printf 'Copyright (c) 2026 %s and also %s\n' "$ME" "$ME" > LICENSE
  tools/privacy-check.sh --files LICENSE >/dev/null 2>&1
  expect "dlline: the rest of the line is still checked" 1 $?
  printf 'Copyright (c) 2026 %s\n' "$ME" > OTHER.md
  tools/privacy-check.sh --files OTHER.md >/dev/null 2>&1
  expect "dlline: does not apply to other paths" 1 $?
fi

cd "$ROOT" || exit 2
echo
if [[ $FAILS -eq 0 ]]; then echo "all privacy tests passed"; exit 0; fi
echo "$FAILS privacy test(s) FAILED"; exit 1
