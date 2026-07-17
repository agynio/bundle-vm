#!/usr/bin/env bash
set -euo pipefail

arch="${1:-arm64}"
version="${2:-dev}"

case "${arch}" in
amd64 | arm64) ;;
*)
	echo "usage: $0 [amd64|arm64] [version]" >&2
	exit 64
	;;
esac

version="$(scripts/validate-version.sh "${version}")"

case "${arch}" in
amd64) lima_arch="x86_64" ;;
arm64) lima_arch="aarch64" ;;
esac

set -a
# shellcheck source=versions.env
source versions.env
set +a

disk="packer/output/${arch}/bundle-vm-platform-${arch}.qcow2"
artifact_dir="artifacts/${arch}"

if [ ! -f "${disk}" ]; then
	echo "missing disk: ${disk}" >&2
	exit 66
fi

rm -rf "${artifact_dir}"
install -d -m 0755 "${artifact_dir}"

cp "${disk}" "${artifact_dir}/bundle-vm-platform-${arch}.qcow2"
xz -T0 -9 --keep --force "${artifact_dir}/bundle-vm-platform-${arch}.qcow2"

jq -n \
	--arg version "${version}" \
	--arg architecture "${arch}" \
	--arg lima_arch "${lima_arch}" \
	--arg disk_size "${DISK_SIZE}" \
	--arg disk_file "bundle-vm-platform-${arch}.qcow2.xz" \
	--arg base_domain "${BASE_DOMAIN}" \
	--arg ingress_host_port "${INGRESS_HOST_PORT}" \
	--arg ingress_nodeport "${INGRESS_NODEPORT}" \
	'{
    name: "bundle-vm-platform",
    version: $version,
    architecture: $architecture,
    limaArchitecture: $lima_arch,
    disk: {
      format: "qcow2",
      compression: "xz",
      size: $disk_size,
      file: $disk_file
    },
    ingress: {
      baseDomain: $base_domain,
      hostPort: ($ingress_host_port | tonumber),
      nodePort: ($ingress_nodeport | tonumber)
    }
  }' >"${artifact_dir}/metadata.json"

sed \
	-e "s/{{ARCH}}/${arch}/g" \
	-e "s/{{LIMA_ARCH}}/${lima_arch}/g" \
	-e "s/{{VERSION}}/${version}/g" \
	-e "s/{{BASE_DOMAIN}}/${BASE_DOMAIN}/g" \
	-e "s/{{INGRESS_HOST_PORT}}/${INGRESS_HOST_PORT}/g" \
	-e "s/{{INGRESS_NODEPORT}}/${INGRESS_NODEPORT}/g" \
	examples/lima.yaml.tpl >"${artifact_dir}/lima.yaml"

(
	cd "${artifact_dir}"
	sha256sum "bundle-vm-platform-${arch}.qcow2.xz" metadata.json lima.yaml >checksums.sha256
)
