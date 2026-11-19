# Agent contract

This repository sets up a Windows 11 VM with GPU and USB passthrough on Linux. The long-term goal is that
it works on every Linux machine; each person who runs it on new hardware or a new distro helps by sending
back a verified report and the fixes their machine needed. You are the coding agent doing that with a human.
`CLAUDE.md` is a symlink to this file.

## Read in this order

1. This file (the rules).
2. `HANDOFF.local.md`, which you create in step 2 below. It describes this machine and names the folders
   that match it.
3. The `README.md` of every folder `HANDOFF.local.md` points to (`distros/`, `desktops/`, `hardware/`).
4. `FOR_AGENT.md` (the step-by-step runbook) and `LESSONS.md` (known failures, tagged by axis).

## Start

1. `git config core.hooksPath .githooks` so the privacy check runs before every push.
2. `git config user.email` must be your GitHub noreply address (`<id>+<name>@users.noreply.github.com`).
   Ask the human for it if it is not set; never guess. Prefer a handle over a real name in `user.name`.
3. `./handoff.sh` writes `HANDOFF.local.md` (gitignored). Read it.
4. Work on a branch (`git switch -c report/<short-name>`). Never commit on `main`.

## Rules (they apply at every step)

- **Ask before anything that changes the machine.** Root goes through `pkexec`, announced first; never `sudo`.
  Ask before logging the human out, deleting anything, starting or stopping the VM, or plugging or
  unplugging USB devices. `FOR_AGENT.md` section 1 has the full list.
- **Never record secrets** (Windows password or key, tokens) anywhere.
- **NO-GO from `./detect.sh` means stop.** Explain the blocker. A report that says NO-GO is still a useful PR.
- **Other machines' values** from examples are never copied into the real config; every value comes from
  `./detect.sh` or the human.

## Test in tiers

`./verify.sh` checks the machine in cumulative tiers. It only inspects; you do the work, then verify.

| Tier | Covers | Needs |
|---|---|---|
| T0 | read-only facts: hardware, IOMMU, distro folder, script syntax | nothing: run `./verify.sh` |
| T1 | host install: packages, libvirt, `install.sh --check` | the human's yes, then `./verify.sh --yes-tier 1` |
| T2 | the VM and Windows | the human's yes (and a separate yes to start the VM) |
| T3 | GPU handover, USB, Looking Glass | the human's yes (and a separate yes to plug in a device) |

A tier cannot run until the one before it passed. Checks only a human can see (the Windows desktop, a
device appearing) are recorded with `./verify.sh --record KEY=pass|fail`. If the VM already existed, pass
`--existing-vm`: T2 is recorded as `pass (existing)`. Stopping at T0 or at the tier where something failed
is fine: the report states what was reached, never more.

## Folders and gaps

`HANDOFF.local.md` resolves your machine to one folder per axis. A missing folder is a **gap**: copy that
axis's `_template/` to the named folder inside your PR and fill it in (what differs, status, known
issues). Only describe what you actually saw.

## Privacy

The repository is public. Nothing personal may be committed, pushed or written in a PR or commit message:
host or user names, home paths, serials, UUIDs, MACs, IPs, Wi-Fi names, personal e-mail, kernel command-line
identifiers (`root=`, `cryptdevice=`). `detect.sh --profile` already leaves them out. Before pushing run
`tools/privacy-check.sh <base>..HEAD`; the pre-push hook runs it on exactly what is pushed, and CI runs it
again. If it flags something, fix the commit; do not edit `tools/privacy-allow.txt` to get past it (the
owner reviews that file).

## Send it back

1. `tools/report.sh` (after `./verify.sh`) writes `reports/<date>_<distro>_<desktop>_<hardware>_<form>.md`
   and refreshes `COMPATIBILITY.md`. Add `--note` text and fill in the report's Known issues if needed.
2. Commit with a clear message. Run `tools/privacy-check.sh origin/main..HEAD`.
3. **Show the human the diff and get their OK.**
4. `git push -u origin <branch>` (or push to the human's fork), then open a PR with the template.
5. Only the repository owner's approval counts, and only the owner merges. Never push to `main`, never
   merge, never use `--no-verify`.
