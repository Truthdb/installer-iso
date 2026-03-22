# installer-iso

Build tooling and CI for producing the TruthDB installer ISO.

## Overview

The ISO boots via UEFI and contains a UKI (Unified Kernel Image) built with `ukify`. The UKI includes an initramfs that runs the `truthdb-installer` binary.

There are two relevant build paths:

- **Local/dev script**: `build_and_run.sh` builds a minimal initramfs (BusyBox + installer) and can boot-test it in QEMU.
- **Release workflow**: GitHub Actions builds an ISO that also embeds an offline Debian rootfs payload and copies required install tools into initramfs.

## Local Development (Docker)

Start a clean Ubuntu build container:

`./run_container.sh`

Then (inside the container) run:

`./build_and_run.sh`

This will:

- Install dependencies (ukify, xorriso, qemu/ovmf, etc.)
- Optionally build `truthdb-installer` from the sibling `installer/` repo (see `BUILD_INSTALLER`)
- Download a kernel EFI binary from the latest `installer-kernel` release (or a specified tag)
- Build a UKI and package it into an ISO
- Optionally boot-test in QEMU (enabled by default)

### Useful Environment Variables (build_and_run.sh)

- `KERNEL_SRC`: path to a kernel image/EFI payload. If unset, downloads `BOOTX64.EFI` from releases.
- `KERNEL_TAG`: if set (e.g. `v1.2.3`), downloads that exact `installer-kernel` release asset.
- `INSTALLER_BIN`: path to `truthdb-installer` (defaults to a sibling repo build output).
- `BUILD_INSTALLER`: `1` to build the installer inside the container.
- `BOOT_TEST`: `1` to boot the ISO in QEMU after building.
- `ISO_NAME`, `UKI_NAME`, `EFI_IMG_NAME`: output naming.

## Releases

On tag pushes (`v*`), the release workflow:

- Builds a Debian (bookworm/amd64) minbase payload via `debootstrap`
- Downloads the current latest released `truthdb`, `installer`, and `installer-kernel` artifacts
- Embeds the payload at `/payload/debian-minbase-amd64-bookworm.tar.zst` in initramfs
- Copies required external tools (partitioning, filesystems, tar/zstd, chroot, efibootmgr, systemd-boot EFI bits) into initramfs
- Produces `truthdb-installer-vX.Y.Z.iso` + `truthdb-installer-vX.Y.Z.iso.sha256`

The workflow does not version-lock dependency artifacts. To control what gets embedded, publish the desired `truthdb`, `installer`, and `installer-kernel` releases before tagging `installer-iso`.

## License

MIT. See LICENSE.
