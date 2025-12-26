#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ================= CONFIG =================
KERNEL_SRC="${KERNEL_SRC:-/work/installer-iso/BOOTX64.EFI}"
INSTALLER_BIN="${INSTALLER_BIN:-/work/installer/target/x86_64-unknown-linux-musl/release/truthdb-installer}"

ISO_NAME="${ISO_NAME:-truthdb-installer.iso}"
UKI_NAME="${UKI_NAME:-TruthDBInstaller.efi}"

BUILD_INSTALLER="${BUILD_INSTALLER:-0}"  # 1 = cargo build installer, 0 = assume INSTALLER_BIN already exists
BOOT_TEST="${BOOT_TEST:-1}"              # 1 = run QEMU boot test of ISO, 0 = just produce ISO

# ================= SANITY =================
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: must run in linux/amd64 container"
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
  xorriso \
  ovmf qemu-system-x86 \
  file \
  systemd-boot systemd-boot-efi \
  musl-tools >/dev/null

# ================= RUST (only needed if BUILD_INSTALLER=1) =================
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

[[ -f "$KERNEL_SRC" ]] || { echo "ERROR: kernel not found: $KERNEL_SRC"; exit 1; }
[[ -x "$INSTALLER_BIN" ]] || { echo "ERROR: installer binary not found: $INSTALLER_BIN"; exit 1; }

# ================= WORKDIR =================
cd /work/installer-iso

# ================= INITRAMFS =================
rm -rf rootfs
mkdir -p rootfs/{bin,sbin,etc,proc,sys,dev,run,tmp}

cp /bin/busybox rootfs/bin/busybox
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
cat > cmdline.txt <<'EOF'
console=ttyS0 earlyprintk=serial loglevel=7 rdinit=/sbin/init
EOF

# ================= UKI =================
cp "$KERNEL_SRC" ./vmlinuz

ukify build \
  --linux ./vmlinuz \
  --initrd ./initramfs.cpio.zst \
  --cmdline @./cmdline.txt \
  --output "./$UKI_NAME"

file "$UKI_NAME"

# ================= ISO =================
rm -rf iso
mkdir -p iso/EFI/BOOT
cp "$UKI_NAME" iso/EFI/BOOT/BOOTX64.EFI

xorriso -as mkisofs \
  -R -J \
  -o "$ISO_NAME" \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  iso

echo "ISO ready: $ISO_NAME"

# ================= BOOT TEST (QEMU) =================
if [[ "$BOOT_TEST" == "1" ]]; then
  cp /usr/share/OVMF/OVMF_CODE_4M.fd ./OVMF_CODE.fd
  cp /usr/share/OVMF/OVMF_VARS_4M.fd ./OVMF_VARS.fd

exec qemu-system-x86_64 \
  -m 2048 \
  -machine q35 \
  -accel tcg \
  -nographic \
  -serial mon:stdio \
  -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
  -drive file=truthdb-installer.iso,media=cdrom,if=ide \
  -boot order=d,menu=off \
  -net none
fi

