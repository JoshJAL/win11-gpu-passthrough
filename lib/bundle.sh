# Shared helpers for detect.sh, install.sh and handoff.sh. Sourced, never executed.
# Read-only: nothing here writes a file or changes the machine.
#
# Bundle layout it resolves (three axes, each has a _template/ to copy for a missing entry):
#   distros/<os-release ID>/distro.sh      package install, firewall rules, bootloader hint
#   desktops/<compositor>/                 desktop-specific steps and files
#   hardware/<host-gpu>-host_<pt-gpu>-pt/  notes for one host/passthrough GPU vendor pair
# An id is tried as ID first, then each ID_LIKE word in order (omarchy -> arch).

# os_release_val <KEY>: value from os-release without sourcing it. OS_RELEASE overrides the
# file (tests, "what would a Debian box resolve to"); when it is set, no other file is used.
os_release_val() {
  local f line v
  if [[ -n ${OS_RELEASE:-} ]]; then f=$OS_RELEASE
  elif [[ -r /etc/os-release ]]; then f=/etc/os-release
  else f=/usr/lib/os-release; fi
  [[ -r $f ]] || return 0
  line=$(grep -m1 "^$1=" "$f" 2>/dev/null) || return 0
  v=${line#*=}
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  printf '%s' "$v"
}

# valid_id <id>: the only shape accepted for a folder name taken from os-release or a flag.
valid_id() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }

# distro_chain: ID, then each ID_LIKE word, in order, valid ids only, one per line.
distro_chain() {
  local w
  for w in "$(os_release_val ID)" $(os_release_val ID_LIKE); do
    valid_id "$w" && printf '%s\n' "$w"
  done
  return 0
}

# bundle_dir <bundle> <axis> <id>: prints the folder's real path when <id> is a valid id, the folder
# exists, and its real path stays inside <bundle>/<axis>. Fails (no output) otherwise.
# For axis "distros" the folder must also hold a distro.sh.
bundle_dir() {
  local b=$1 axis=$2 id=$3 root dir
  valid_id "$id" || return 1
  root=$(realpath -e "$b/$axis" 2>/dev/null) || return 1
  dir=$(realpath -e "$root/$id" 2>/dev/null) || return 1
  [[ -d $dir && $dir == "$root"/* ]] || return 1
  if [[ $axis == distros ]]; then
    [[ -f $dir/distro.sh && $(realpath -e "$dir/distro.sh") == "$dir"/* ]] || return 1
  fi
  printf '%s' "$dir"
}

# pick_distro <bundle>: first id in distro_chain that has a distros/<id>/distro.sh.
pick_distro() {
  local id
  while IFS= read -r id; do
    if bundle_dir "$1" distros "$id" >/dev/null; then printf '%s' "$id"; return 0; fi
  done < <(distro_chain)
  return 1
}

# load_distro <bundle> <id>: source distros/<id>/distro.sh after the checks in bundle_dir.
load_distro() {
  local d
  d=$(bundle_dir "$1" distros "$2") || return 1
  # shellcheck source=/dev/null
  . "$d/distro.sh"
}
