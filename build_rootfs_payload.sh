#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

TRUTHDB_REPO="${TRUTHDB_REPO:-Truthdb/truthdb}"
TRUTHDB_BIN="${TRUTHDB_BIN:-}"
TRUTHDB_SERVICE="${TRUTHDB_SERVICE:-}"
TRUTHDB_SOURCE="${TRUTHDB_SOURCE:-auto}"  # auto|local|release
PAYLOAD_NAME="${PAYLOAD_NAME:-debian-minbase-amd64-bookworm.tar.zst}"
ROOTFS_DIR="${ROOTFS_DIR:-${PWD}/debian-rootfs}"
PAYLOAD_PATH="${PAYLOAD_PATH:-${PWD}/${PAYLOAD_NAME}}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
KEEP_ROOTFS_DIR="${KEEP_ROOTFS_DIR:-0}"

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  sudo "$@"
}

curl_args=(-fsSL -H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

use_local_truthdb=0
have_local_truthdb=0
if [[ -n "${TRUTHDB_BIN}" && -n "${TRUTHDB_SERVICE}" && -f "${TRUTHDB_BIN}" && -f "${TRUTHDB_SERVICE}" ]]; then
  if file "${TRUTHDB_BIN}" | grep -q 'ELF 64-bit'; then
    have_local_truthdb=1
  else
    echo "WARN: TRUTHDB_BIN is not an ELF Linux binary" >&2
  fi
fi

case "${TRUTHDB_SOURCE}" in
  auto)
    use_local_truthdb="${have_local_truthdb}"
    ;;
  local)
    if [[ "${have_local_truthdb}" != "1" ]]; then
      echo "ERROR: TRUTHDB_SOURCE=local requires a Linux ELF truthdb binary and truthdb.service" >&2
      exit 1
    fi
    use_local_truthdb=1
    ;;
  release)
    use_local_truthdb=0
    ;;
  *)
    echo "ERROR: unsupported TRUTHDB_SOURCE: ${TRUTHDB_SOURCE}" >&2
    exit 1
    ;;
esac

echo "==> Building Debian rootfs payload"
run_as_root rm -rf "${ROOTFS_DIR}" "${PAYLOAD_PATH}" truthdb-dist

run_as_root debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --include=systemd-sysv,systemd-resolved,linux-image-amd64,initramfs-tools,ca-certificates,sudo,passwd,iproute2,dbus \
  bookworm \
  "${ROOTFS_DIR}" \
  "${DEBIAN_MIRROR}"

mkdir -p truthdb-dist

if [[ "${use_local_truthdb}" = "1" ]]; then
  echo "==> Using local truthdb build"
  cp "${TRUTHDB_BIN}" truthdb-dist/truthdb
  cp "${TRUTHDB_SERVICE}" truthdb-dist/truthdb.service
else
  echo "==> Resolving latest truthdb release"
  release="$(curl "${curl_args[@]}" "https://api.github.com/repos/${TRUTHDB_REPO}/releases/latest")"

  download_url="$(echo "${release}" | jq -r '.assets // [] | .[] | select(.name | endswith("-x86_64-linux-gnu.tar.gz")) | .browser_download_url' | head -n 1)"
  checksum_url="$(echo "${release}" | jq -r '.assets // [] | .[] | select(.name | endswith("-x86_64-linux-gnu.sha256")) | .browser_download_url' | head -n 1)"

  [[ -n "${download_url}" && "${download_url}" != "null" ]] || {
    echo "ERROR: No truthdb binary archive found in latest release" >&2
    exit 1
  }
  [[ -n "${checksum_url}" && "${checksum_url}" != "null" ]] || {
    echo "ERROR: No truthdb checksum found in latest release" >&2
    exit 1
  }

  curl -fsSL -o truthdb-dist/truthdb.tar.gz "${download_url}"
  curl -fsSL -o truthdb-dist/truthdb.sha256 "${checksum_url}"
  tar xzf truthdb-dist/truthdb.tar.gz -C truthdb-dist

  expected_truthdb_sha="$(awk 'NR==1 {print $1}' truthdb-dist/truthdb.sha256)"
  actual_truthdb_sha="$(sha256sum truthdb-dist/truthdb | awk '{print $1}')"
  if [[ -z "${expected_truthdb_sha}" || "${expected_truthdb_sha}" != "${actual_truthdb_sha}" ]]; then
    echo "ERROR: truthdb checksum verification failed" >&2
    echo "Expected: ${expected_truthdb_sha:-<empty>}" >&2
    echo "Actual:   ${actual_truthdb_sha}" >&2
    exit 1
  fi
fi

test -x truthdb-dist/truthdb
test -f truthdb-dist/truthdb.service

run_as_root install -d \
  "${ROOTFS_DIR}/usr/local/bin" \
  "${ROOTFS_DIR}/lib/systemd/system" \
  "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
run_as_root install -m 0755 truthdb-dist/truthdb "${ROOTFS_DIR}/usr/local/bin/truthdb"
run_as_root install -m 0644 truthdb-dist/truthdb.service "${ROOTFS_DIR}/lib/systemd/system/truthdb.service"
run_as_root ln -sf /lib/systemd/system/truthdb.service \
  "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/truthdb.service"

test -x "${ROOTFS_DIR}/usr/local/bin/truthdb"
test -f "${ROOTFS_DIR}/lib/systemd/system/truthdb.service"
test -L "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/truthdb.service"

run_as_root rm -rf "${ROOTFS_DIR}/var/lib/apt/lists/"* || true
run_as_root rm -rf "${ROOTFS_DIR}/var/cache/apt/archives/"*.deb || true
run_as_root rm -rf "${ROOTFS_DIR}/usr/share/doc" || true
run_as_root rm -rf "${ROOTFS_DIR}/usr/share/man" || true
run_as_root rm -rf "${ROOTFS_DIR}/usr/share/info" || true
run_as_root rm -rf "${ROOTFS_DIR}/usr/share/locale" || true

run_as_root tar --numeric-owner -C "${ROOTFS_DIR}" -cpf - . \
  | zstd -19 -T0 -o "${PAYLOAD_PATH}"

if [[ "${KEEP_ROOTFS_DIR}" != "1" ]]; then
  run_as_root rm -rf "${ROOTFS_DIR}"
fi

rm -rf truthdb-dist

echo "Payload ready: ${PAYLOAD_PATH}"
ls -lh "${PAYLOAD_PATH}"
