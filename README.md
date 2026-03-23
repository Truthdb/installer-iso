# installer-iso

Build tooling and CI for producing the TruthDB installer ISO.

## Overview

The ISO boots through `GRUB` and loads a normal Linux kernel plus installer initramfs. The initramfs then launches the `truthdb-installer` binary on the active console by default, with a separate GRUB entry available for dedicated-VT testing.

There are two relevant build paths:

- **Local/dev script**: `build_and_run.sh` builds the GRUB-based installer ISO locally and can boot-test it in QEMU.
- **Release workflow**: GitHub Actions builds the same GRUB-based ISO, but also embeds an offline Debian rootfs payload and copies required install tools into initramfs.

## Local Development (Docker)

Start a clean Ubuntu build container:

`./run_container.sh`

Then (inside the container) run:

`./build_and_run.sh`

If you want the whole local container build in one step instead of entering a shell first:

`./build_in_container.sh`

By default this runs in local development mode (`INPUT_MODE=dev`).

This will:

- Install dependencies (GRUB, xorriso, qemu/ovmf, etc.)
- Build `truthdb-installer` from the sibling `installer/` repo by default
- Build `truthdb` from the sibling `truthdb/` repo by default for the embedded Debian payload
- Build and embed the Debian rootfs payload by default
- Download the installer kernel from the latest `installer-kernel` release (or a specified tag)
- Build a GRUB-based installer ISO
- Skip the QEMU boot test by default so the wrapper can be used from macOS hosts without container GUI setup

### Useful Environment Variables (build_and_run.sh)

- `INPUT_MODE`: `dev` or `release`. `dev` builds local workspace binaries by default; `release` uses published release artifacts by default.
- `KERNEL_SRC`: path to a Linux kernel image. If unset, downloads the current `BOOTX64.EFI` kernel release asset and uses it as the installer kernel.
- `KERNEL_TAG`: if set (e.g. `v1.2.3`), downloads that exact `installer-kernel` release asset.
- `KERNEL_REPO`: GitHub repo to query for installer-kernel releases.
- `INSTALLER_REPO`: GitHub repo to query for installer releases.
- `TRUTHDB_REPO`: GitHub repo to query for truthdb releases.
- `INSTALLER_BIN`: path to `truthdb-installer` (defaults to a sibling repo build output).
- `BUILD_INSTALLER`: `1` to build the installer inside the container.
- `BUILD_TRUTHDB`: `1` to build `truthdb` inside the container for payload embedding.
- `BUILD_ROOTFS_PAYLOAD`: `1` to build and embed the Debian payload locally.
- `ROOTFS_PAYLOAD`: path to a prebuilt Debian payload tarball to embed instead of building one.
- `TRUTHDB_SOURCE`: `local`, `release`, or `auto` for payload embedding.
- `BOOT_TEST`: `1` to boot the ISO in QEMU after building.
- `BOOT_FIRMWARE`: `uefi` or `bios` for the local QEMU boot test.
- `ISO_NAME`: output ISO name.

These variables can also be set in front of `./build_in_container.sh`, for example:

`ISO_NAME=truthdb-dev.iso ./build_in_container.sh`

To build locally but use the latest published `truthdb` / `installer` / `installer-kernel` release artifacts instead of local workspace binaries:

`INPUT_MODE=release ./build_in_container.sh`

To force a QEMU boot test from inside the container:

`BOOT_TEST=1 ./build_in_container.sh`

If `KERNEL_SRC` or `INSTALLER_BIN` point at files inside this workspace on the host, `build_in_container.sh` rewrites those paths for the container automatically.

Mode summary:

- `INPUT_MODE=dev`: builds local `truthdb` and `installer`, builds the Debian payload locally, downloads `installer-kernel` unless `KERNEL_SRC` is set
- `INPUT_MODE=release`: downloads published `truthdb`, `installer`, and `installer-kernel` artifacts and builds the Debian payload from the published `truthdb` release assets

Implementation note:

- The release workflow and local `INPUT_MODE=release` path both use `build_rootfs_payload.sh` plus `build_iso.sh`
- Local `INPUT_MODE=dev` uses the same scripts, but feeds them local workspace artifacts by default

## Releases

On tag pushes (`v*`), the release workflow:

- Builds a Debian (bookworm/amd64) minbase payload via `debootstrap`
- Uses the shared `build_rootfs_payload.sh` implementation in `TRUTHDB_SOURCE=release` mode
- Downloads the current latest released `truthdb`, `installer`, and `installer-kernel` artifacts and verifies their published checksums
- Embeds the payload at `/payload/debian-minbase-amd64-bookworm.tar.zst` in initramfs
- Copies required external tools (partitioning, filesystems, tar/zstd, chroot, efibootmgr, systemd-boot EFI bits) into initramfs
- Builds a GRUB boot menu with normal, safe-graphics, debug, serial-console, and rescue entries
- Produces `truthdb-installer-vX.Y.Z.iso` + `truthdb-installer-vX.Y.Z.iso.sha256`

The workflow does not version-lock dependency artifacts. To control what gets embedded, publish the desired `truthdb`, `installer`, and `installer-kernel` releases before tagging `installer-iso`.

## License

MIT. See LICENSE.
