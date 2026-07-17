#!/usr/bin/env bash
set -euo pipefail

# Download the Agyn platform VM image from the CDN and boot it with Lima.
#
# Usage:
#   ./get-agyn.sh                 # latest defaults (version 0.1.0, arch auto)
#   AGYN_VERSION=0.1.0 AGYN_PORT=2497 AGYN_NAME=agyn ./get-agyn.sh
#
# The VM serves the platform on https://*.agyn.dev:<AGYN_PORT> once ready
# (*.agyn.dev resolves to 127.0.0.1 publicly).

BASE_URL="${AGYN_BASE_URL:-https://downloads.agyn.cloud/bundle-vm}"
VERSION="${AGYN_VERSION:-0.1.0}"
NAME="${AGYN_NAME:-agyn}"
PORT="${AGYN_PORT:-2496}"
WORK_DIR="${AGYN_DIR:-${HOME}/.agyn/bundle-vm/${VERSION}}"

case "$(uname -m)" in
arm64 | aarch64) ARCH=arm64 ;;
x86_64 | amd64) ARCH=amd64 ;;
*)
	echo "unsupported architecture: $(uname -m)" >&2
	exit 1
	;;
esac

for cmd in curl limactl xz shasum; do
	command -v "${cmd}" >/dev/null || {
		echo "missing required tool: ${cmd}" >&2
		[ "${cmd}" = "limactl" ] && echo "install with: brew install lima" >&2
		exit 1
	}
done

if limactl list --quiet 2>/dev/null | grep -qx "${NAME}"; then
	echo "Lima instance '${NAME}' already exists."
	echo "Start it with:  limactl start ${NAME}"
	echo "Or remove it:   limactl delete -f ${NAME}"
	exit 1
fi

url="${BASE_URL}/${VERSION}/${ARCH}"
disk_xz="bundle-vm-platform-${ARCH}.qcow2.xz"
disk="bundle-vm-platform-${ARCH}.qcow2"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

echo "==> Downloading Agyn platform VM ${VERSION} (${ARCH}) to ${WORK_DIR}"
curl -fL --progress-bar -C - -o "${disk_xz}" "${url}/${disk_xz}"
curl -fsSL -o checksums.sha256 "${url}/checksums.sha256"
curl -fsSL -o lima.yaml "${url}/lima.yaml"

echo "==> Verifying checksum"
shasum -a 256 -c checksums.sha256 --ignore-missing

if [ ! -f "${disk}" ]; then
	echo "==> Decompressing (893 MB -> ~4.6 GB)"
	xz -dk "${disk_xz}"
fi

if [ "${PORT}" != "2496" ]; then
	echo "==> Using ingress host port ${PORT}"
	sed -i.bak "s/hostPort: 2496/hostPort: ${PORT}/" lima.yaml && rm -f lima.yaml.bak
fi

echo "==> Starting VM '${NAME}' (first boot ~30s)"
limactl start --name "${NAME}" lima.yaml

cat <<EOF

Agyn platform is up:

  Console:  https://console.agyn.dev:${PORT}
  Chat:     https://chat.agyn.dev:${PORT}
  Tracing:  https://tracing.agyn.dev:${PORT}

The TLS certificate is signed by the image's local CA. Trust it once:
  limactl shell ${NAME} -- sudo kubectl -n istio-gateway \\
    get secret agyn-dev-ca -o jsonpath='{.data.tls\\.crt}' | base64 -d > agyn-local-ca.pem
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain agyn-local-ca.pem

Manage the VM:
  limactl stop ${NAME}      # stop (restart takes ~30s)
  limactl start ${NAME}     # start again
  limactl delete -f ${NAME} # remove entirely
EOF
