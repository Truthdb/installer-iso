#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ================= CONFIG =================
KERNEL_SRC="${KERNEL_SRC:-/work/installer-iso/BOOTX64.EFI}"  # must be a Linux kernel image (bzImage/vmlinuz)
INSTALLER_BIN="${INSTALLER_BIN:-/work/installer/target/x86_64-unknown-linux-musl/release/truthdb-installer}"

ISO_NAME="${ISO_NAME:-truthdb-installer.iso}"
UKI_NAME="${UKI_NAME:-TruthDBInstaller.efi}"
EFI_IMG_NAME="${EFI_IMG_NAME:-efi.img}"

BUILD_INSTALLER="${BUILD_INSTALLER:-0}"  # 1=yes, 0=no
BOOT_TEST="${BOOT_TEST:-1}"              # 1=yes, 0=no

# ================= SANITY =================
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: container arch must be x86_64 (use --platform=linux/amd64)"
  exit 1
fi

# ================= DEPS =================
apt-get update
apt-get install -y \
  ca-certificates curl git \
  build-essential pkg-config \
  cpio zstd \
  busybox-static \
  python3 \
  systemd-ukify \
  systemd-boot-efi \
  ovmf qemu-system-x86 \
  file \
  xorriso \
  dosfstools mtools \
  musl-tools >/dev/null

# ================= RUST (optional) =================
if [[ "$BUILD_INSTALLER" == "1" ]]; then
  if [[ ! -f "$HOME/.cargo/env" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090
  . "$HOME/.cargo/env"
  rustup target add x86_64-unknown-linux-musl >/dev/null

  pushd /work/installer >/dev/null
  cargo build --release --target x86_64-unknown-linux-musl
  popd >/dev/null
fi

[[ -f "$KERNEL_SRC" ]] || { echo "ERROR: KERNEL_SRC does not exist: $KERNEL_SRC"; exit 1; }
[[ -x "$INSTALLER_BIN" ]] || { echo "ERROR: installer binary not found: $INSTALLER_BIN"; exit 1; }

# ================= WORKDIR =================
cd /work/installer-iso

# ================= INITRAMFS =================
rm -rf rootfs
mkdir -p rootfs/{bin,sbin,etc,proc,sys,dev,run,tmp}

cp /bin/busybox rootfs/bin/busybox
chmod +x rootfs/bin/busybox
ln -sf /bin/busybox rootfs/sbin/init
ln -sf /bin/busybox rootfs/bin/sh

cp "$INSTALLER_BIN" rootfs/bin/truthdb-installer
chmod +x rootfs/bin/truthdb-installer

cat > rootfs/etc/inittab <<'EOF'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t sysfs sysfs /sys
::sysinit:/bin/busybox mount -t devtmpfs devtmpfs /dev
::respawn:/bin/truthdb-installer
::restart:/bin/busybox reboot -f
EOF

rm -f initramfs.cpio initramfs.cpio.zst
( cd rootfs && find . -print0 | cpio --null -ov --format=newc ) > initramfs.cpio
zstd -19 -T0 initramfs.cpio -o initramfs.cpio.zst

# ================= CMDLINE =================
#cat > cmdline.txt <<'EOF'
#console=ttyS0 earlyprintk=serial loglevel=7 rdinit=/sbin/init
#EOF
cat > cmdline.txt <<'EOF'
console=tty0 console=ttyS0,115200 earlycon=efi loglevel=7 rdinit=/sbin/init
EOF

# ================= UKI =================
cp "$KERNEL_SRC" ./vmlinuz

ukify build \
  --linux ./vmlinuz \
  --initrd ./initramfs.cpio.zst \
  --cmdline @./cmdline.txt \
  --output "./$UKI_NAME"

file "./$UKI_NAME"

# ================= EFI IMG (FAT, El Torito boot image) =================
rm -f "./$EFI_IMG_NAME"
dd if=/dev/zero of="./$EFI_IMG_NAME" bs=1M count=128
mkfs.vfat -F 32 "./$EFI_IMG_NAME"

mmd   -i "./$EFI_IMG_NAME" ::/EFI
mmd   -i "./$EFI_IMG_NAME" ::/EFI/BOOT
mcopy -i "./$EFI_IMG_NAME" "./$UKI_NAME" ::/EFI/BOOT/BOOTX64.EFI

# ================= ISO =================
rm -f "$ISO_NAME"

xorriso -as mkisofs \
  -R -J \
  -o "$ISO_NAME" \
  -eltorito-alt-boot \
  -e "$EFI_IMG_NAME" \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -graft-points "$EFI_IMG_NAME"="$EFI_IMG_NAME"

echo "ISO ready: $ISO_NAME"

# ================= BOOT TEST (QEMU) =================
if [[ "$BOOT_TEST" == "1" ]]; then
  cp /usr/share/OVMF/OVMF_CODE_4M.fd ./OVMF_CODE.fd
  cp /usr/share/OVMF/OVMF_VARS_4M.fd ./OVMF_VARS.fd

  # exec qemu-system-x86_64 \
  #   -m 2048 \
  #   -machine q35 \
  #   -accel tcg \
  #   -nographic \
  #   -serial mon:stdio \
  #   -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
  #   -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
  #   -drive file="$ISO_NAME",media=cdrom,readonly=on \
  #   -boot order=d,menu=off \
  #   -net none

  exec qemu-system-x86_64 \
    -m 2048 \
    -machine q35 \
    -accel tcg \
    -serial stdio \
    -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
    -drive file="$ISO_NAME",media=cdrom,readonly=on \
    -boot order=d,menu=off \
    -net none
fi
