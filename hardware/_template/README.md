# Hardware: <host-gpu>-host_<passthrough-gpu>-pt (template)

Copy this folder to `hardware/<host>-host_<pt>-pt/`, where the name is exactly the `HW_KEY` that
`./handoff.sh` prints for this machine (vendors are `intel`, `amd`, `nvidia`, `other`). Form factor and
model go in the report name, not in the folder name. Fill in the sections, delete this line, and keep
personal data out.

**Status:** untested | partly tested (tier N) | tested. Tested reports: see `COMPATIBILITY.md`.

## What is specific to this combination

Things that go wrong or need extra steps because of these two GPU vendors (reset bugs, driver checks that
detect virtualization, address-width limits, ACS/IOMMU grouping, display wiring). Each point: symptom,
cause, which script handles it or what the human must do, and a link to a `LESSONS.md` entry or a
`reports/` file.

## Known issues

Symptoms seen on this combination that are not solved yet.
