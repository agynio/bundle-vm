#!/usr/bin/env bash
set -euo pipefail

# Upgrades the platform Helm releases in place, without touching the VM.
#
# The alternative — replacing the whole disk image — throws away everything the
# user has in the VM: databases, threads, agents, workloads. That is a fine way
# to get a clean machine (`agyn local delete` then `agyn local start`) but a
# poor way to pick up a new platform release, because it is not reversible and
# not what "upgrade" sounds like it does.
#
# Values are reused from the installed release rather than re-rendered. The bake
# configured this cluster (OpenZiti addresses, OIDC, the in-cluster MinIO and
# OpenFGA endpoints), and `agyn local start` has since rewritten the bootstrap
# token and the browser-facing ports. Re-rendering would silently revert both.
#
# What this does NOT do: upgrade k3s, Istio, cert-manager, OpenZiti, or Postgres.
# Those come from the image, and moving them is what a new image is for.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-platform}"
PLATFORM_CHART="${AGYN_PLATFORM_CHART:-oci://ghcr.io/agynio/charts/agyn-platform}"
APPS_CHART="${AGYN_APPS_CHART:-oci://ghcr.io/agynio/charts/agyn-apps}"
HELM_TIMEOUT="${AGYN_HELM_TIMEOUT:-15m}"

# Empty means "whatever the registry says is newest".
platform_version="${1:-}"
apps_version="${2:-}"

log() { printf '[upgrade-platform] %s\n' "$*"; }

until kubectl get --raw=/readyz >/dev/null 2>&1; do
	log "waiting for the API server"
	sleep 5
done

# Helm rewrites every Deployment it owns back to what the chart says. Anything
# running from source under `devspace dev` is one of those, so an upgrade ends
# those sessions — worth saying out loud, because the symptom is a service that
# quietly stops reflecting the code someone is editing.
if kubectl -n "${NAMESPACE}" get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null |
	grep -q 'devcontainer'; then
	log "note: services running from source (devspace) will be reset to their chart images"
fi

installed_version() {
	helm list -n "${NAMESPACE}" --filter "^${1}\$" -o json 2>/dev/null |
		sed -n 's/.*"chart":"[^"]*-\([0-9][^"]*\)".*/\1/p' | head -1
}

upgrade() {
	release="${1}"
	chart="${2}"
	want="${3}"

	if ! helm status "${release}" -n "${NAMESPACE}" >/dev/null 2>&1; then
		log "${release} is not installed; skipping"
		return 0
	fi

	before="$(installed_version "${release}")"

	set -- upgrade "${release}" "${chart}" -n "${NAMESPACE}" \
		--reuse-values --wait --timeout "${HELM_TIMEOUT}"
	if [ -n "${want}" ]; then
		set -- "$@" --version "${want}"
		log "${release}: ${before:-unknown} -> ${want}"
	else
		log "${release}: ${before:-unknown} -> latest"
	fi

	helm "$@"

	after="$(installed_version "${release}")"
	log "${release} now at ${after:-unknown}"
	if [ -n "${before}" ] && [ "${before}" = "${after}" ]; then
		log "${release} was already up to date"
	fi
}

upgrade agyn-platform "${PLATFORM_CHART}" "${platform_version}"
upgrade agyn-apps "${APPS_CHART}" "${apps_version}"

log "releases:"
helm list -n "${NAMESPACE}"
log "done"
