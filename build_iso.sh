#!/usr/bin/env bash
set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-}"
INSTALLER_BIN="${INSTALLER_BIN:-}"
ISO_NAME="${ISO_NAME:-truthdb-installer.iso}"
ROOTFS_PAYLOAD="${ROOTFS_PAYLOAD:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_TEMPLATE="${SCRIPT_DIR}/initramfs/init"
GRUB_CFG_TEMPLATE="${SCRIPT_DIR}/grub/grub.cfg"

[[ -n "${KERNEL_SRC}" ]] || { echo "ERROR: KERNEL_SRC is required"; exit 1; }
[[ -f "${KERNEL_SRC}" ]] || { echo "ERROR: KERNEL_SRC does not exist: ${KERNEL_SRC}"; exit 1; }
[[ -n "${INSTALLER_BIN}" ]] || { echo "ERROR: INSTALLER_BIN is required"; exit 1; }
[[ -x "${INSTALLER_BIN}" ]] || { echo "ERROR: INSTALLER_BIN is not executable: ${INSTALLER_BIN}"; exit 1; }
[[ -f "${INIT_TEMPLATE}" ]] || { echo "ERROR: missing init template: ${INIT_TEMPLATE}"; exit 1; }
[[ -f "${GRUB_CFG_TEMPLATE}" ]] || { echo "ERROR: missing GRUB config template: ${GRUB_CFG_TEMPLATE}"; exit 1; }

copy_bin_with_libs() {
  local src="$1"
  if [[ ! -x "$src" ]]; then
    echo "ERROR: required tool not found or not executable: $src" >&2
    exit 1
  fi

  mkdir -p "rootfs$(dirname "$src")"
  cp -L "$src" "rootfs$src"

  ldd "$src" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }' \
    | while read -r dep; do
        mkdir -p "rootfs$(dirname "$dep")"
        cp -L "$dep" "rootfs$dep"
      done
}

copy_required_cmd() {
  local cmd="$1"
  local path
  path="$(command -v "$cmd" || true)"
  [[ -n "$path" ]] || {
    echo "ERROR: required tool not found in PATH: $cmd" >&2
    exit 1
  }
  copy_bin_with_libs "$path"
}

rm -rf rootfs iso-root
mkdir -p rootfs/{bin,sbin,etc,proc,sys,dev,run,tmp,dev/pts}

cp /bin/busybox rootfs/bin/busybox
chmod +x rootfs/bin/busybox
ln -sf /bin/busybox rootfs/bin/sh

cp "${INIT_TEMPLATE}" rootfs/init
chmod +x rootfs/init

cp "${INSTALLER_BIN}" rootfs/bin/truthdb-installer
chmod +x rootfs/bin/truthdb-installer

if [[ -n "${ROOTFS_PAYLOAD}" ]]; then
  [[ -f "${ROOTFS_PAYLOAD}" ]] || { echo "ERROR: ROOTFS_PAYLOAD does not exist: ${ROOTFS_PAYLOAD}"; exit 1; }
  mkdir -p rootfs/payload
  cp "${ROOTFS_PAYLOAD}" rootfs/payload/debian-minbase-amd64-bookworm.tar.zst
fi

# Required external tools for destructive install steps.
copy_required_cmd wipefs
copy_required_cmd sfdisk
copy_required_cmd partprobe
copy_required_cmd blkid
copy_required_cmd mkfs.vfat
copy_required_cmd mkfs.ext4
copy_required_cmd mount
copy_required_cmd umount
copy_required_cmd tar
copy_required_cmd zstd

chroot_path="$(command -v chroot || true)"
[[ -n "${chroot_path}" ]] || { echo "ERROR: chroot not found in PATH"; exit 1; }
copy_bin_with_libs "${chroot_path}"

efibootmgr_path="$(command -v efibootmgr || true)"
[[ -n "${efibootmgr_path}" ]] || { echo "ERROR: efibootmgr not found in PATH"; exit 1; }
copy_bin_with_libs "${efibootmgr_path}"

bootctl_path="$(command -v bootctl || true)"
if [[ -n "${bootctl_path}" ]]; then
  copy_bin_with_libs "${bootctl_path}"
fi

if [[ -d /usr/lib/systemd/boot/efi ]]; then
  mkdir -p rootfs/usr/lib/systemd/boot
  cp -a /usr/lib/systemd/boot/efi rootfs/usr/lib/systemd/boot/
else
  echo "ERROR: /usr/lib/systemd/boot/efi not found (need systemd-boot EFI binaries)" >&2
  exit 1
fi

rm -f initrd.img
( cd rootfs && find . -print0 | cpio --null -ov --format=newc ) \
  | zstd -19 -T0 -o initrd.img

mkdir -p iso-root/boot/grub iso-root/boot/truthdb
cp "${GRUB_CFG_TEMPLATE}" iso-root/boot/grub/grub.cfg
cp "${KERNEL_SRC}" iso-root/boot/truthdb/vmlinuz
cp initrd.img iso-root/boot/truthdb/initrd.img

rm -f "${ISO_NAME}"
grub-mkrescue -o "${ISO_NAME}" iso-root

echo "ISO ready: ${ISO_NAME}"
ls -lh "${ISO_NAME}"
