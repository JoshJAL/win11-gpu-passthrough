# Desktop: Hyprland

**Status:** the only desktop this bundle has been run on. Tested reports: see `COMPATIBILITY.md`
(rows with desktop `hyprland`).

## What differs on Hyprland

A GPU can only go to the VM when nothing on the host has it open. Hyprland (and Xwayland, and the NVIDIA
EGL/Vulkan libraries) open every GPU they can find, so while the VM owns the GPU, Hyprland has to start
without it. `hyprland-snippet.lua` in this folder does that whenever the flag file
`~/.config/hypr/gpu-vm-mode` exists, and does nothing otherwise. The flag path is the same on every
desktop for now (`winvm-gpu` and the launcher create it); a second desktop may need its own mechanism, which
is a good first PR for that desktop.

## Steps that differ: merge the snippet

`hyprland-snippet.lua` is machine-specific and must be **merged** into the human's
`~/.config/hypr/hyprland.lua`, not pasted blindly. (Coding agents: this is a change to a file that may be
tracked in the human's dotfiles; show the diff and get approval before writing, and do not commit it.)

1. Open the snippet and the human's `hyprland.lua`. If the config already sets `AQ_DRM_DEVICES`,
   `__EGL_VENDOR_LIBRARY_FILENAMES`, `__GLX_VENDOR_LIBRARY_NAME` or `VK_DRIVER_FILES`, merge the logic
   instead of adding a second `hl.env()` for the same name (the last call for a name wins).
2. Set `PASSTHROUGH_PCI` to the first address in `GPU_PCI` (in `/etc/win11-vm.conf`), and
   `HOST_VULKAN_ICD` to the host GPU's ICD (`ls /usr/share/vulkan/icd.d/`).
3. Parse-check it (the `hl` global is not defined at parse time, which is fine):
   `luajit -bl ~/.config/hypr/hyprland.lua > /dev/null`.
4. Show the diff and get approval before writing.

The change has no effect until the next login (Hyprland reads its config at start; `hyprctl reload` is not
enough), and the snippet does nothing while the flag is absent.

## Known issues

- Hyprland's udev hotplug ignores `AQ_DRM_DEVICES` and grabs a GPU that is handed back to Linux. The
  generated `/etc/udev/rules.d/72-winvm-gpu-seat.rules` takes the card off the seat while the flag exists
  (see `LESSONS.md`, "Also learned").
- Only Omarchy 4 (Lua config) has been tested. A classic `hyprland.conf` needs the same logic written in
  that syntax.
