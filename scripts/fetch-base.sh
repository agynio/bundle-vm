#!/usr/bin/env bash
set -euo pipefail

# Fetches the bundle-vm-base disk this platform image is built on top of and
# prints the path to the decompressed qcow2.
#
# scripts/build.sh otherwise expects a sibling bundle-vm-base checkout that has
# already been built locally. That is fine on the machine that built both, and
# impossible anywhere else — CI has no sibling checkout, and "whatever qcow2 is
# lying around next door" is not a reproducible input. Base images are published
# to GHCR as OCI artifacts for exactly this reason, so pull the pinned version.
#
# The result is cached under .cache/base/<version>/<arch>, so repeated builds on
# one machine download once.

arch="${1:?usage: $0 ARCH [VERSION]}"
version="${2:-${BASE_IMAGE_VERSION:-}}"

case "${arch}" in
amd64 | arm64) ;;
*)
	echo "usage: $0 [amd64|arm64] [version]" >&2
	exit 64
	;;
esac

set -a
# shellcheck source=versions.env
source versions.env
set +a

version="${version:-${BASE_IMAGE_VERSION:-}}"
if [ -z "${version}" ]; then
	echo "no base image version: set BASE_IMAGE_VERSION in versions.env or pass it as \$2" >&2
	exit 64
fi

image="${BASE_IMAGE_REGISTRY:-ghcr.io/agynio/bundle-vm-base}"
ref="${image}:${version}-${arch}"

cache_dir=".cache/base/${version}/${arch}"
disk="${cache_dir}/bundle-vm-base-${arch}.qcow2"

log() { printf '[fetch-base] %s\n' "$*" >&2; }

if [ -f "${disk}" ]; then
	log "using cached ${disk}"
	printf '%s\n' "$(cd "$(dirname "${disk}")" && pwd)/$(basename "${disk}")"
	exit 0
fi

if ! command -v oras >/dev/null 2>&1; then
	echo "missing oras; install with: brew install oras" >&2
	exit 69
fi

mkdir -p "${cache_dir}"
log "pulling ${ref}"
if ! oras pull "${ref}" --output "${cache_dir}"; then
	cat >&2 <<EOF
[fetch-base] could not pull ${ref}

Release that base version first, from the bundle-vm-base repository:

    scripts/release.sh ${arch} ${version}

then make sure BASE_IMAGE_VERSION in versions.env names it. To build against a
base that is not published yet, point BASE_IMAGE at a local qcow2 instead:

    BASE_IMAGE=/abs/path/to/bundle-vm-base-${arch}.qcow2 scripts/release.sh ${arch} VERSION
EOF
	exit 66
fi

compressed="${disk}.xz"
if [ ! -f "${compressed}" ]; then
	echo "artifact ${ref} contains no ${compressed##*/}" >&2
	exit 65
fi

# Verify before spending minutes decompressing a truncated download.
if [ -f "${cache_dir}/checksums.sha256" ]; then
	log "verifying checksum"
	(cd "${cache_dir}" && grep "$(basename "${compressed}")" checksums.sha256 | shasum -a 256 -c -) >&2
fi

log "decompressing"
xz --decompress --keep --force "${compressed}"
rm -f "${compressed}"

printf '%s\n' "$(cd "$(dirname "${disk}")" && pwd)/$(basename "${disk}")"
