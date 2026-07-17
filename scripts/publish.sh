#!/usr/bin/env bash
set -euo pipefail

arch="${1:?usage: $0 ARCH VERSION IMAGE [extra-tags...] }"
version="${2:?usage: $0 ARCH VERSION IMAGE [extra-tags...] }"
image="${3:?usage: $0 ARCH VERSION IMAGE [extra-tags...] }"
shift 3

version="$(scripts/validate-version.sh "${version}")"

artifact_dir="artifacts/${arch}"
ref="${image}:${version}-${arch}"

if [ ! -d "${artifact_dir}" ]; then
	echo "missing artifact directory: ${artifact_dir}" >&2
	exit 66
fi

oras push "${ref}" \
	--artifact-type application/vnd.agyn.bundle-vm-platform.v1 \
	"${artifact_dir}/bundle-vm-platform-${arch}.qcow2.xz:application/vnd.agyn.bundle-vm-platform.disk.qcow2+xz" \
	"${artifact_dir}/metadata.json:application/vnd.agyn.bundle-vm-platform.metadata+json" \
	"${artifact_dir}/checksums.sha256:text/plain" \
	"${artifact_dir}/lima.yaml:application/x-yaml"

for tag in "$@"; do
	scripts/validate-version.sh "${tag}" >/dev/null
	oras tag "${ref}" "${tag}-${arch}"
done
