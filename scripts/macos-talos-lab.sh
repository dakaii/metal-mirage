#!/usr/bin/env bash
# Local Talos lab on macOS / Mac Mini via QEMU (Apple Hypervisor).
# Thin wrapper around upstream talosctl — not a metal-mirage L1 provisioner.
#
# Usage:
#   ./scripts/macos-talos-lab.sh create
#   ./scripts/macos-talos-lab.sh show
#   ./scripts/macos-talos-lab.sh kubeconfig   # write .secrets/macos-talos.kubeconfig
#   ./scripts/macos-talos-lab.sh destroy
#
# Docs: docs/MACOS-TALOS-LAB.md
# Upstream: https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/local-platforms/qemu
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

CMD="${1:-}"
NAME="${TALOS_CLUSTER_NAME:-metal-mirage-macos}"
CPUS="${TALOS_QEMU_CPUS:-2}"
MEMORY="${TALOS_QEMU_MEMORY:-2048}"
WORKERS="${TALOS_QEMU_WORKERS:-1}"
CONTROLPLANES="${TALOS_QEMU_CONTROLPLANES:-1}"

usage() {
  cat <<'EOF' >&2
usage: ./scripts/macos-talos-lab.sh create|show|kubeconfig|destroy

  create      talosctl cluster create qemu (needs sudo / vmnet)
  show        talosctl cluster show --provisioner qemu
  kubeconfig  write .secrets/macos-talos.kubeconfig
  destroy     talosctl cluster destroy --provisioner qemu

Env: TALOS_CLUSTER_NAME (default metal-mirage-macos)
     TALOS_QEMU_CPUS / TALOS_QEMU_MEMORY / TALOS_QEMU_WORKERS / TALOS_QEMU_CONTROLPLANES

This is a local VM lab on macOS — not provisioner: bare-metal. See docs/MACOS-TALOS-LAB.md.
EOF
  exit 1
}

need_darwin() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: macos-talos-lab.sh is for macOS (Darwin). On Linux use: talosctl cluster create qemu" >&2
    echo "  Or Azure metal-sim / real bare-metal — docs/METAL-PRIMARY.md" >&2
    exit 1
  fi
}

need_tools() {
  need talosctl "brew install siderolabs/tap/talosctl"
  if ! command -v qemu-system-aarch64 >/dev/null 2>&1 && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "missing required tool: qemu-system-aarch64 or qemu-system-x86_64" >&2
    echo "  brew install qemu" >&2
    exit 1
  fi
}

case "${CMD}" in
  create)
    need_darwin
    need_tools
    mkdir -p "${HOME}/.talos/clusters"
    echo "==> creating Talos QEMU cluster name=${NAME} (cp=${CONTROLPLANES} workers=${WORKERS} cpus=${CPUS} mem=${MEMORY})"
    echo "    This uses Apple Hypervisor (HVF). See docs/MACOS-TALOS-LAB.md"
    # shellcheck disable=SC2086
    sudo --preserve-env=HOME talosctl cluster create qemu \
      --name "${NAME}" \
      --controlplanes "${CONTROLPLANES}" \
      --workers "${WORKERS}" \
      --cpus "${CPUS}" \
      --memory "${MEMORY}"
    echo "==> done. Try: ./scripts/macos-talos-lab.sh show"
    echo "    kubeconfig: ./scripts/macos-talos-lab.sh kubeconfig"
    ;;
  show)
    need_tools
    sudo --preserve-env=HOME talosctl cluster show --provisioner qemu --name "${NAME}" 2>/dev/null \
      || talosctl cluster show --provisioner qemu
    ;;
  kubeconfig)
    need_tools
    mkdir -p "${ROOT}/.secrets"
    out="${ROOT}/.secrets/macos-talos.kubeconfig"
    talosctl kubeconfig "${out}" --force -n "${NAME}" 2>/dev/null \
      || talosctl kubeconfig "${out}" --force
    chmod 600 "${out}" 2>/dev/null || true
    echo "==> wrote ${out}"
    echo "    export KUBECONFIG=${out}"
    ;;
  destroy)
    need_darwin
    need_tools
    echo "==> destroying Talos QEMU cluster name=${NAME}"
    sudo --preserve-env=HOME talosctl cluster destroy --provisioner qemu --name "${NAME}" 2>/dev/null \
      || sudo --preserve-env=HOME talosctl cluster destroy --provisioner qemu
    echo "==> done. If host rebooted mid-lab, also: rm -rf ~/.talos/clusters/${NAME}"
    ;;
  -h | --help | "")
    usage
    ;;
  *)
    echo "unknown command: ${CMD}" >&2
    usage
    ;;
esac
