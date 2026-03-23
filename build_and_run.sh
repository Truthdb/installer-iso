#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ================= CONFIG =================
INPUT_MODE="${INPUT_MODE:-dev}"  # dev|release
KERNEL_SRC="${KERNEL_SRC:-}"     # must be a Linux kernel image (bzImage/vmlinuz)
INSTALLER_BIN="${INSTALLER_BIN:-}"
INSTALLER_BIN_WAS_EXPLICIT=0
if [[ -n "${INSTALLER_BIN}" ]]; then
  INSTALLER_BIN_WAS_EXPLICIT=1
else
  INSTALLER_BIN=/work/installer/target/x86_64-unknown-linux-musl/release/truthdb-installer
fi

# If KERNEL_SRC is not provided, fetch the installer-kernel release asset.
# The published asset is historically named BOOTX64.EFI, but it is the Linux
# kernel image we want GRUB to boot.
# - If KERNEL_TAG is set (e.g. v1.2.3), fetch that exact release.
# - Otherwise, fetch the latest release.
KERNEL_TAG="${KERNEL_TAG:-}"
KERNEL_REPO="${KERNEL_REPO:-Truthdb/installer-kernel}"
INSTALLER_REPO="${INSTALLER_REPO:-Truthdb/installer}"
TRUTHDB_REPO="${TRUTHDB_REPO:-Truthdb/truthdb}"

ISO_NAME="${ISO_NAME:-truthdb-installer.iso}"
ROOTFS_PAYLOAD="${ROOTFS_PAYLOAD:-}"

case "${INPUT_MODE}" in
  dev)
    default_build_installer=1
    default_build_truthdb=1
    default_truthdb_source=local
    ;;
  release)
    default_build_installer=0
    default_build_truthdb=0
    default_truthdb_source=release
    ;;
  *)
    echo "ERROR: unsupported INPUT_MODE: ${INPUT_MODE}" >&2
    exit 1
    ;;
esac

BUILD_INSTALLER="${BUILD_INSTALLER:-$default_build_installer}"  # 1=yes, 0=no
BUILD_TRUTHDB="${BUILD_TRUTHDB:-$default_build_truthdb}"      # 1=yes, 0=no
BUILD_ROOTFS_PAYLOAD="${BUILD_ROOTFS_PAYLOAD:-1}"  # 1=yes, 0=no
TRUTHDB_SOURCE="${TRUTHDB_SOURCE:-$default_truthdb_source}"  # auto|local|release
BOOT_TEST="${BOOT_TEST:-1}"              # 1=yes, 0=no
BOOT_FIRMWARE="${BOOT_FIRMWARE:-uefi}"   # uefi|bios

GENERATED_ROOTFS_PAYLOAD=0

cleanup_generated_payload() {
  if [[ "${GENERATED_ROOTFS_PAYLOAD}" != "1" ]]; then
    return 0
  fi
  rm -rf /tmp/truthdb-installer-rootfs /tmp/debian-minbase-amd64-bookworm.tar.zst
}

trap cleanup_generated_payload EXIT

curl_args=(-fsSL -H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

download_release_installer() {
  local release download_url checksum_url expected_sha actual_sha

  echo "INSTALLER_BIN not set; downloading installer from latest release of ${INSTALLER_REPO}"
  release="$(curl "${curl_args[@]}" "https://api.github.com/repos/${INSTALLER_REPO}/releases/latest")"

  download_url="$(echo "${release}" | jq -r '.assets // [] | .[] | select(.name | contains("truthdb-installer")) | select(.name | endswith(".tar.gz")) | .browser_download_url' | head -n 1)"
  checksum_url="$(echo "${release}" | jq -r '.assets // [] | .[] | select(.name | contains("truthdb-installer")) | select(.name | endswith(".sha256")) | .browser_download_url' | head -n 1)"

  [[ -n "${download_url}" && "${download_url}" != "null" ]] || {
    echo "ERROR: could not find installer archive asset in latest ${INSTALLER_REPO} release" >&2
    exit 1
  }
  [[ -n "${checksum_url}" && "${checksum_url}" != "null" ]] || {
    echo "ERROR: could not find installer checksum asset in latest ${INSTALLER_REPO} release" >&2
    exit 1
  }

  mkdir -p /work/installer-iso/installer-bin
  curl -fsSL -o /work/installer-iso/installer-bin/installer.tar.gz "${download_url}"
  curl -fsSL -o /work/installer-iso/installer-bin/truthdb-installer.sha256 "${checksum_url}"
  tar xzf /work/installer-iso/installer-bin/installer.tar.gz -C /work/installer-iso/installer-bin

  expected_sha="$(awk 'NR==1 {print $1}' /work/installer-iso/installer-bin/truthdb-installer.sha256)"
  actual_sha="$(sha256sum /work/installer-iso/installer-bin/truthdb-installer | awk '{print $1}')"
  if [[ -z "${expected_sha}" || "${expected_sha}" != "${actual_sha}" ]]; then
    echo "ERROR: installer checksum verification failed" >&2
    echo "Expected: ${expected_sha:-<empty>}" >&2
    echo "Actual:   ${actual_sha}" >&2
    exit 1
  fi

  chmod +x /work/installer-iso/installer-bin/truthdb-installer
  INSTALLER_BIN=/work/installer-iso/installer-bin/truthdb-installer
}

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
  util-linux \
  fdisk \
  parted \
  e2fsprogs \
  efibootmgr \
  debootstrap debian-archive-keyring \
  python3 \
  systemd \
  systemd-boot-efi \
  grub-common \
  grub-pc-bin \
  grub-efi-amd64-bin \
  ovmf qemu-system-x86 \
  file \
  xorriso \
  dosfstools mtools \
  jq \
  musl-tools >/dev/null

# ================= RUST (optional) =================
if [[ "$BUILD_INSTALLER" == "1" || "$BUILD_TRUTHDB" == "1" ]]; then
  if [[ ! -f "$HOME/.cargo/env" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090,SC1091
  . "$HOME/.cargo/env"
  rustup target add x86_64-unknown-linux-musl >/dev/null
fi

if [[ "$BUILD_INSTALLER" == "1" ]]; then
  pushd /work/installer >/dev/null
  cargo build --release --target x86_64-unknown-linux-musl
  popd >/dev/null
fi

if [[ "$BUILD_TRUTHDB" == "1" ]]; then
  pushd /work/truthdb >/dev/null
  cargo build --release
  popd >/dev/null
fi

if [[ "${INPUT_MODE}" = "release" && "${INSTALLER_BIN_WAS_EXPLICIT}" != "1" && "${BUILD_INSTALLER}" != "1" ]]; then
  download_release_installer
fi

if [[ -z "$KERNEL_SRC" ]]; then
  mkdir -p /work/installer-iso/kernel-bin
  if [[ -n "$KERNEL_TAG" ]]; then
    echo "KERNEL_SRC not set; downloading kernel from $KERNEL_REPO tag $KERNEL_TAG"
    release="$(curl "${curl_args[@]}" "https://api.github.com/repos/${KERNEL_REPO}/releases/tags/${KERNEL_TAG}")"
  else
    echo "KERNEL_SRC not set; downloading kernel from latest release of $KERNEL_REPO"
    release="$(curl "${curl_args[@]}" "https://api.github.com/repos/${KERNEL_REPO}/releases/latest")"
  fi

  url="$(echo "$release" | jq -r '.assets // [] | .[] | select(.name == "BOOTX64.EFI") | .browser_download_url' | head -n 1)"
  checksum_url="$(echo "$release" | jq -r '.assets // [] | .[] | select(.name == "BOOTX64.EFI.sha256") | .browser_download_url' | head -n 1)"
  [[ -n "$url" && "$url" != "null" ]] || { echo "ERROR: could not find BOOTX64.EFI asset in release"; exit 1; }
  [[ -n "$checksum_url" && "$checksum_url" != "null" ]] || { echo "ERROR: could not find BOOTX64.EFI.sha256 asset in release"; exit 1; }

  curl -fsSL -o /work/installer-iso/kernel-bin/BOOTX64.EFI "$url"
  curl -fsSL -o /work/installer-iso/kernel-bin/BOOTX64.EFI.sha256 "$checksum_url"
  (
    cd /work/installer-iso/kernel-bin
    sha256sum -c BOOTX64.EFI.sha256
  )
  KERNEL_SRC=/work/installer-iso/kernel-bin/BOOTX64.EFI
fi

[[ -f "$KERNEL_SRC" ]] || { echo "ERROR: KERNEL_SRC does not exist: $KERNEL_SRC"; exit 1; }
if [[ ! -x "$INSTALLER_BIN" ]]; then
  if [[ "${INPUT_MODE}" = "release" && "${INSTALLER_BIN_WAS_EXPLICIT}" != "1" ]]; then
    download_release_installer
  fi
fi
[[ -x "$INSTALLER_BIN" ]] || { echo "ERROR: installer binary not found: $INSTALLER_BIN"; exit 1; }

# ================= WORKDIR =================
cd /work/installer-iso

if [[ -z "$ROOTFS_PAYLOAD" && "$BUILD_ROOTFS_PAYLOAD" == "1" ]]; then
  echo "ROOTFS_PAYLOAD not set; building Debian rootfs payload locally"
  chmod +x ./build_rootfs_payload.sh
  export TRUTHDB_BIN=/work/truthdb/target/release/truthdb
  export TRUTHDB_SERVICE=/work/truthdb/truthdb.service
  export TRUTHDB_REPO
  export TRUTHDB_SOURCE
  ROOTFS_DIR=/tmp/truthdb-installer-rootfs \
  PAYLOAD_PATH=/tmp/debian-minbase-amd64-bookworm.tar.zst \
    ./build_rootfs_payload.sh
  ROOTFS_PAYLOAD=/tmp/debian-minbase-amd64-bookworm.tar.zst
  GENERATED_ROOTFS_PAYLOAD=1
fi

# ================= ISO =================
export KERNEL_SRC INSTALLER_BIN ISO_NAME ROOTFS_PAYLOAD
chmod +x ./build_iso.sh
./build_iso.sh

# ================= BOOT TEST (QEMU) =================
if [[ "$BOOT_TEST" == "1" ]]; then
  if [[ "$BOOT_FIRMWARE" == "bios" ]]; then
    exec qemu-system-x86_64 \
      -m 2048 \
      -machine q35 \
      -accel tcg \
      -serial stdio \
      -drive file="$ISO_NAME",media=cdrom,readonly=on \
      -boot order=d,menu=on \
      -net none
  fi

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
