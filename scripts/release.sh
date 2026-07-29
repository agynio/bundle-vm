#!/usr/bin/env bash
set -euo pipefail

# Builds, packages and publishes one architecture of the platform image.
#
# This is the whole release for an arch, in one command, so that the amd64 build
# running in GitHub Actions and the arm64 build running on someone's laptop are
# the same sequence of steps rather than two similar ones that drift. Until
# there is an arm64 runner with KVM, that laptop is the only place arm64 can be
# built — which makes it exactly the place where remembering four commands in
# the right order is a bad plan.
#
# Every precondition is checked before the build starts. A missing credential
# should fail in the first second, not after a 40-minute bake.
#
#   scripts/release.sh arm64 0.2.0 --latest
#   scripts/release.sh amd64 0.2.0 --no-publish     # build and package only

usage() {
	cat >&2 <<'EOF'
usage: scripts/release.sh ARCH VERSION [--latest] [--no-publish] [--skip-build]

  ARCH          amd64 | arm64
  VERSION       release version (e.g. 0.2.0), or "dev" for a local build
  --latest      point the CDN's latest.json at this version
  --no-publish  build and package only; do not upload anywhere
  --skip-build  reuse packer/output (for re-publishing an existing build)
EOF
	exit 64
}

arch="${1:-}"
version="${2:-}"
[ -n "${arch}" ] && [ -n "${version}" ] || usage
shift 2

publish=true
skip_build=false
latest_args=()
for arg in "$@"; do
	case "${arg}" in
	--latest) latest_args=(--latest) ;;
	--no-publish) publish=false ;;
	--skip-build) skip_build=true ;;
	*) usage ;;
	esac
done

case "${arch}" in
amd64 | arm64) ;;
*) usage ;;
esac

version="$(scripts/validate-version.sh "${version}")"

log() { printf '\n[release] %s\n' "$*"; }
fail() {
	printf '[release] %s\n' "$*" >&2
	exit 1
}

# --- Preflight ------------------------------------------------------------

log "preflight for ${arch} ${version}"

for tool in packer qemu-img xz; do
	command -v "${tool}" >/dev/null 2>&1 || fail "missing ${tool}"
done
if [ "${publish}" = true ]; then
	for tool in oras s5cmd; do
		command -v "${tool}" >/dev/null 2>&1 || fail "missing ${tool} (needed to publish; pass --no-publish to skip)"
	done
	for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT_URL; do
		[ -n "${!var:-}" ] || fail "missing ${var} (needed to publish; pass --no-publish to skip)"
	done
fi

# The bake boots a VM. Without hardware acceleration QEMU falls back to
# emulation, where this build takes hours instead of minutes — slow enough that
# it reads as a hang. Refuse rather than let someone discover that overnight.
accelerator="$(scripts/select-qemu-accelerator.sh)"
if [ "${accelerator}" = "none" ] && [ "${AGYN_ALLOW_SLOW_BUILD:-}" != "1" ]; then
	fail "no hardware acceleration (no /dev/kvm, not macOS): the build would take hours.
Set AGYN_ALLOW_SLOW_BUILD=1 to proceed anyway."
fi
echo "  accelerator: ${accelerator}"

# The disk is 32G sparse; a bake plus its xz copy needs well over 20G free.
case "$(uname -s)" in
Darwin) free_gb="$(df -g . | awk 'NR==2 {print $4}')" ;;
*) free_gb="$(df -BG --output=avail . | awk 'NR==2 {gsub("G",""); print $1}')" ;;
esac
echo "  free disk: ${free_gb}G"
if [ "${free_gb}" -lt 25 ]; then
	fail "need at least 25G free, have ${free_gb}G"
fi

# --- Build ----------------------------------------------------------------

if [ "${skip_build}" = true ]; then
	log "skipping build (--skip-build)"
else
	# An explicit BASE_IMAGE wins, so a base that is not published yet can still
	# be built against — which is the only way to bootstrap a new architecture,
	# and how you test a base change before releasing it.
	if [ -n "${BASE_IMAGE:-}" ]; then
		log "using BASE_IMAGE from the environment"
		[ -r "${BASE_IMAGE}" ] || fail "BASE_IMAGE is not readable: ${BASE_IMAGE}"
	else
		log "fetching base image"
		BASE_IMAGE="$(scripts/fetch-base.sh "${arch}")"
		export BASE_IMAGE
	fi
	echo "  ${BASE_IMAGE}"

	log "building ${arch}"
	rm -rf "packer/output/${arch}"
	scripts/build.sh "${arch}"
fi

log "packaging ${arch} ${version}"
scripts/package.sh "${arch}" "${version}"

# --- Publish --------------------------------------------------------------

if [ "${publish}" = false ]; then
	log "built and packaged; not publishing (--no-publish)"
	ls -lh "artifacts/${arch}"
	exit 0
fi

log "publishing to GHCR"
scripts/publish.sh "${arch}" "${version}" "${PLATFORM_IMAGE:-ghcr.io/agynio/bundle-vm}"

log "publishing to CDN"
scripts/publish-cdn.sh "${arch}" "${version}" ${latest_args[@]+"${latest_args[@]}"}

log "released ${arch} ${version}"
