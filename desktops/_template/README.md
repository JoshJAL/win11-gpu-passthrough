# Desktop: <compositor> (template)

Copy this folder to `desktops/<name>/`, where `<name>` is the lowercase first word of
`XDG_CURRENT_DESKTOP` as `./handoff.sh` prints it (for example `gnome`, `kde`, `sway`). Fill in the
sections, delete this line, and keep personal data out (no user names, home paths, hostnames, serials).

**Status:** untested | partly tested (tier N) | tested. Tested reports: see `COMPATIBILITY.md`.

## What differs on <compositor>

Why this desktop needs anything special at all. The core question: does the compositor open the
passthrough GPU, and what stops it from doing so while the VM owns the GPU? If nothing is needed, say so
and say how you checked (`winvm-gpu on` succeeds without "Close these first").

## Steps that differ

Numbered steps, each one an action. Config snippets that must be merged into the human's own files go in
this folder, with a header explaining how to merge them (see `desktops/hyprland/` for an example).

## Known issues

Symptoms seen on this desktop, with the cause if known. Link a `reports/` file for each one.
