#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The one-shot wrapper should produce an ISO from a clean macOS/Linux host
# without requiring a prebuilt installer binary or a containerized QEMU run.
INPUT_MODE="${INPUT_MODE:-dev}"
case "${INPUT_MODE}" in
  dev)
    BUILD_INSTALLER="${BUILD_INSTALLER:-1}"
    BUILD_TRUTHDB="${BUILD_TRUTHDB:-1}"
    TRUTHDB_SOURCE="${TRUTHDB_SOURCE:-local}"
    ;;
  release)
    BUILD_INSTALLER="${BUILD_INSTALLER:-0}"
    BUILD_TRUTHDB="${BUILD_TRUTHDB:-0}"
    TRUTHDB_SOURCE="${TRUTHDB_SOURCE:-release}"
    ;;
  *)
    echo "ERROR: unsupported INPUT_MODE: ${INPUT_MODE}" >&2
    exit 1
    ;;
esac
BUILD_ROOTFS_PAYLOAD="${BUILD_ROOTFS_PAYLOAD:-1}"
BOOT_TEST="${BOOT_TEST:-0}"

translate_workspace_path() {
  local value="$1"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if [[ "$value" == "${WORKSPACE_ROOT}"/* ]]; then
    printf '/work%s' "${value#"${WORKSPACE_ROOT}"}"
    return 0
  fi
  printf '%s' "$value"
}

docker_args=(
  run
  --rm
  -it
  --platform=linux/amd64
  -v "${WORKSPACE_ROOT}:/work"
  -w /work/installer-iso
)

for name in \
  KERNEL_SRC \
  INSTALLER_BIN \
  ROOTFS_PAYLOAD \
  INPUT_MODE \
  KERNEL_TAG \
  KERNEL_REPO \
  INSTALLER_REPO \
  TRUTHDB_REPO \
  ISO_NAME \
  BUILD_INSTALLER \
  BUILD_TRUTHDB \
  BUILD_ROOTFS_PAYLOAD \
  TRUTHDB_SOURCE \
  BOOT_TEST \
  BOOT_FIRMWARE
do
  if [[ -n "${!name:-}" ]]; then
    value="${!name}"
    case "$name" in
      KERNEL_SRC|INSTALLER_BIN|ROOTFS_PAYLOAD)
        value="$(translate_workspace_path "$value")"
        ;;
    esac
    docker_args+=(-e "${name}=${value}")
  fi
done

docker_args+=(
  -e "INPUT_MODE=${INPUT_MODE}"
  -e "BUILD_INSTALLER=${BUILD_INSTALLER}"
  -e "BUILD_TRUTHDB=${BUILD_TRUTHDB}"
  -e "BUILD_ROOTFS_PAYLOAD=${BUILD_ROOTFS_PAYLOAD}"
  -e "TRUTHDB_SOURCE=${TRUTHDB_SOURCE}"
  -e "BOOT_TEST=${BOOT_TEST}"
  ubuntu:24.04
  bash
  -lc
  "./build_and_run.sh"
)

exec docker "${docker_args[@]}"
