# Hardware: Intel iGPU host, NVIDIA GPU passed through

Key: `intel-host_nvidia-pt`. The Linux desktop runs on the Intel iGPU; the NVIDIA GPU (laptop or desktop) goes
to the Windows VM and is handed back to Linux when the VM stops.

**Status:** the combination the bundle was built on (an Intel 13th-gen laptop with an NVIDIA RTX 4070 Laptop
GPU). Tested reports: see `COMPATIBILITY.md` (rows with this hardware key).

## What is specific to this combination

- **The IOMMU can be narrower than the CPU.** Intel client parts often report 39 address bits (MGAW) on
  the IOMMU while the CPU has 42 to 46. QEMU then dies with `vfio: DMA mapping failed`. `detect.sh`
  reads the width and proposes `IOMMU_LIMIT`; `enable-gpu.sh` writes `<maxphysaddr mode='passthrough'
  limit='39'/>`. See `LESSONS.md`, "The IOMMU is narrower than the CPU".
- **NVIDIA "Code 43" in the guest.** The driver detects the hypervisor. `enable-gpu.sh` hides KVM and sets
  a Hyper-V vendor id. See `LESSONS.md`, "The NVIDIA driver refuses to start in a VM".
- **A laptop dGPU has no display output**, so Looking Glass has nothing to capture until a virtual
  monitor exists: the Virtual Display Driver, bound to the passthrough GPU (`guest/install-vdd.ps1`).
  See `LESSONS.md`, "Looking Glass has nothing to capture", and `guest/GUEST-STEPS.md`.
- **The host must not use the NVIDIA GPU** while the VM owns it: no EGL/Vulkan/CUDA clients, compositor
  started without it. See `LESSONS.md`, "The host will not release the GPU", and your desktop's folder.
- **Monitors:** every monitor the human still needs must be on the Intel GPU (or another device), because the
  NVIDIA GPU's outputs go dark while the VM has it. `detect.sh` reports this.

## Known issues

- Laptops with the external ports wired to the NVIDIA GPU cannot keep an external monitor while the GPU is
  passed through (`detect.sh` says NO-GO if that leaves no display).
