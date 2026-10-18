#!/usr/bin/env bash
# Installs an installer ISO onto a blank disk in QEMU and checks the result:
# the install itself, the TruthDB service over its native port, and the
# accounts on the installed system.
#
# Usage: tests/e2e/run.sh ISO TRUTHDB_CLI [OUT_DIR]
# Needs: qemu-system-x86, qemu-utils, ovmf, mtools, fdisk, python3.
set -euo pipefail

ISO="$(realpath "$1")"
TRUTHDB_CLI="$(realpath "$2")"
OUT_DIR="${3:-${PWD}/e2e-out}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${OUT_DIR}"
OUT_DIR="$(realpath "${OUT_DIR}")"
DISK="${OUT_DIR}/disk.qcow2"
rm -f "${DISK}"
qemu-img create -q -f qcow2 "${DISK}" 16G

python3 -u "${HERE}/drive.py" install "${OUT_DIR}" "${ISO}" "${DISK}"
python3 -u "${HERE}/drive.py" service "${OUT_DIR}" "${DISK}" "${TRUTHDB_CLI}"

# The installed boot entry has no serial console, so boot the installed kernel
# directly with the entry's own options plus console=ttyS0 to log in.
qemu-img convert -O raw "${DISK}" "${OUT_DIR}/disk.raw"
esp_start="$(sfdisk -d "${OUT_DIR}/disk.raw" | awk -F'start=' '/disk.raw1/ { split($2, a, ","); gsub(/ /, "", a[1]); print a[1] }')"
esp="${OUT_DIR}/disk.raw@@$((esp_start * 512))"
mcopy -o -i "${esp}" ::/EFI/debian/vmlinuz "${OUT_DIR}/vmlinuz"
mcopy -o -i "${esp}" ::/EFI/debian/initrd.img "${OUT_DIR}/initrd.img"
mcopy -o -i "${esp}" ::/loader/entries/debian.conf "${OUT_DIR}/debian.conf"
rm -f "${OUT_DIR}/disk.raw"
cmdline="$(sed -n 's/^options[[:space:]]*//p' "${OUT_DIR}/debian.conf")"

python3 -u "${HERE}/drive.py" login "${OUT_DIR}" "${DISK}" "${OUT_DIR}/vmlinuz" "${OUT_DIR}/initrd.img" "${cmdline}"

rm -f "${DISK}" "${OUT_DIR}/vmlinuz" "${OUT_DIR}/initrd.img" "${OUT_DIR}/vars.fd"
echo "E2E PASS"
