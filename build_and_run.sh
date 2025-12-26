#!/usr/bin/env bash
set -euo pipefail

# ---- config you must set ----
KERNEL_SRC="${KERNEL_SRC:-/work/installer-iso/BOOTX64.EFI}"
INSTALLER_BIN="/work/installer/target/x86_64-unknown-linux-musl/release/truthdb-installer"

# ---- sanity ----
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: container arch must be x86_64 (use --platform=linux/amd64)"
  exit 1
fi

# ---- deps ----
apt-get update
apt-get install -y \
  ca-certificates curl git \
  build-essential pkg-config \
  cpio zstd \
  busybox-static \
  python3 \
  systemd-ukify \
  ovmf qemu-system-x86 \
  file \
  systemd-boot systemd-boot-efi \
  musl-tools >/dev/null

# ---- rustup (idempotent-ish) ----
if [[ ! -f "$HOME/.cargo/env" ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck disable=SC1090
. "$HOME/.cargo/env"
rustup target add x86_64-unknown-linux-musl >/dev/null

# ---- build installer ----
pushd /work/installer >/dev/null
cargo build --release --target x86_64-unknown-linux-musl
popd >/dev/null

if [[ ! -x "$INSTALLER_BIN" ]]; then
  echo "ERROR: installer binary not found at: $INSTALLER_BIN"
  exit 1
fi

# ---- prepare working dir ----
cd /work/installer-iso

# ---- initramfs rootfs ----
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

# ---- kernel ----
if [[ ! -f "$KERNEL_SRC" ]]; then
  echo "ERROR: KERNEL_SRC does not exist: $KERNEL_SRC"
  exit 1
fi
cp "$KERNEL_SRC" ./vmlinuz

# ---- cmdline ----
cat > cmdline.txt <<'EOF'
console=ttyS0 earlyprintk=serial loglevel=7 rdinit=/sbin/init
EOF

# ---- build UKI ----
ukify build \
  --linux ./vmlinuz \
  --initrd ./initramfs.cpio.zst \
  --cmdline @./cmdline.txt \
  --output ./TruthDBInstaller.efi

file TruthDBInstaller.efi

# ---- esp dir ----
rm -rf espdir
mkdir -p espdir/EFI/BOOT
cp TruthDBInstaller.efi espdir/EFI/BOOT/BOOTX64.EFI

# ---- OVMF ----
if [[ ! -f /usr/share/OVMF/OVMF_CODE_4M.fd || ! -f /usr/share/OVMF/OVMF_VARS_4M.fd ]]; then
  echo "ERROR: Expected OVMF 4M firmware files in /usr/share/OVMF/"
  exit 1
fi
cp /usr/share/OVMF/OVMF_CODE_4M.fd ./OVMF_CODE.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd ./OVMF_VARS.fd

# ---- boot ----
exec qemu-system-x86_64 \
  -m 2048 \
  -machine q35 \
  -accel tcg \
  -nographic \
  -serial mon:stdio \
  -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
  -drive format=raw,file=fat:rw:espdir \
  -boot order=c,menu=off \
  -net none
