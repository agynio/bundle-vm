#!/usr/bin/env bash
set -euo pipefail

# Uploads a packaged image to the CDN bucket consumers download from, and
# optionally repoints `latest`.
#
# GHCR (scripts/publish.sh) is where the platform build finds its inputs; this
# is where `agyn local start` finds its image. Both have to happen for a release
# to exist, which is why release.sh runs them together rather than leaving the
# second one to whoever remembers the s5cmd invocation from the README.
#
# Credentials come from the environment (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
# / R2_ENDPOINT_URL), so this is identical in CI and on a laptop.

arch="${1:?usage: $0 ARCH VERSION [--latest]}"
version="${2:?usage: $0 ARCH VERSION [--latest]}"
shift 2

mark_latest=false
for arg in "$@"; do
	case "${arg}" in
	--latest) mark_latest=true ;;
	*)
		echo "unknown argument: ${arg}" >&2
		exit 64
		;;
	esac
done

version="$(scripts/validate-version.sh "${version}")"

bucket="${R2_BUCKET:-downloads}"
prefix="${R2_PREFIX:-bundle-vm}"
artifact_dir="artifacts/${arch}"

log() { printf '[publish-cdn] %s\n' "$*"; }

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT_URL; do
	if [ -z "${!var:-}" ]; then
		echo "missing ${var}" >&2
		exit 64
	fi
done

if ! command -v s5cmd >/dev/null 2>&1; then
	echo "missing s5cmd; install with: brew install peak/tap/s5cmd" >&2
	exit 69
fi

if [ ! -d "${artifact_dir}" ]; then
	echo "missing artifact directory: ${artifact_dir} (run scripts/package.sh first)" >&2
	exit 66
fi

# The disk is published compressed; the decompressed copy package.sh leaves
# behind is a local build artifact and must not be uploaded — it is 5x the size
# and nothing reads it.
for required in "bundle-vm-platform-${arch}.qcow2.xz" checksums.sha256 metadata.json lima.yaml; do
	if [ ! -f "${artifact_dir}/${required}" ]; then
		echo "missing ${artifact_dir}/${required}" >&2
		exit 66
	fi
done

export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
s5cmd_run() { s5cmd --endpoint-url "${R2_ENDPOINT_URL}" "$@"; }

dest="s3://${bucket}/${prefix}/${version}/${arch}/"
log "uploading to ${dest}"
for file in "bundle-vm-platform-${arch}.qcow2.xz" checksums.sha256 metadata.json lima.yaml; do
	s5cmd_run cp "${artifact_dir}/${file}" "${dest}"
done

if [ "${mark_latest}" = true ]; then
	# latest.json maps the moving `latest` name onto a concrete version. It is
	# written last: until it points at this version, nothing resolves to a
	# half-uploaded directory.
	tmp="$(mktemp -d)"
	trap 'rm -rf "${tmp}"' EXIT
	printf '{"version":"%s"}\n' "${version}" >"${tmp}/latest.json"
	log "pointing latest at ${version}"
	s5cmd_run cp "${tmp}/latest.json" "s3://${bucket}/${prefix}/latest.json"
fi

log "done"
