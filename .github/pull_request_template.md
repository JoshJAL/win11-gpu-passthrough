## What this PR is

<!-- One or two sentences: a report from new hardware, a new distro/desktop/hardware folder, a fix, ... -->

## Machine and tier reached (reports)

- Distro / desktop / hardware key:
- Highest tier passed (T0 to T3, or "none: T0 failed"):
- The VM already existed (T2 recorded as `pass (existing)`): yes / no

## Checklist

- [ ] `tools/privacy-check.sh origin/main..HEAD` passes locally (hostnames, user names, home paths, serials, UUIDs, MACs, IPs, personal e-mail stay out).
- [ ] Commits use a GitHub noreply address.
- [ ] No secrets (Windows password or key, tokens) anywhere in the diff, notes or logs.
- [ ] New distro/desktop/hardware folders were copied from `_template/` and say what was and was not tested.
- [ ] `tools/report.sh --check` passes (when a report is included).
- [ ] I am not claiming a tier the report does not show as passed.

<!-- Only the repository owner's approval counts, and only the owner merges. -->
