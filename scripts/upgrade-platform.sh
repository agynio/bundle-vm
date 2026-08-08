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
# token. Re-rendering would silently revert it.
#
# Reusing values does NOT preserve the browser-facing port, because
# set-ingress-port.sh wrote that with `kubectl set env` rather than through the
# release. Helm rewrites those Deployments from chart values, so the port is
# re-applied at the end of this script.
#
# --values overlays a file on top of the reused values, for settings the image
# cannot know: an external OIDC issuer instead of the bundled Keycloak, say. It
# is an overlay, not a replacement — anything it does not name keeps the value
# the bake or `agyn local start` gave it.
#
# What this does NOT do: upgrade k3s, Istio, cert-manager, OpenZiti, or Postgres.
# Those come from the image, and moving them is what a new image is for.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-platform}"
PLATFORM_CHART="${AGYN_PLATFORM_CHART:-oci://ghcr.io/agynio/charts/agyn-platform}"
APPS_CHART="${AGYN_APPS_CHART:-oci://ghcr.io/agynio/charts/agyn-apps}"
HELM_TIMEOUT="${AGYN_HELM_TIMEOUT:-15m}"

# Named rather than positional: a values path and a chart version are easy to
# transpose, and the failure would be a silent no-op or a wrong chart.
platform_version=""
apps_version=""
extra_values=""
while [ "$#" -gt 0 ]; do
	case "${1}" in
	--values)
		extra_values="${2:-}"
		shift 2
		;;
	--platform-version)
		platform_version="${2:-}"
		shift 2
		;;
	--apps-version)
		apps_version="${2:-}"
		shift 2
		;;
	*)
		echo "unknown argument: ${1}" >&2
		exit 64
		;;
	esac
done

if [ -n "${extra_values}" ] && [ ! -r "${extra_values}" ]; then
	echo "values file not readable: ${extra_values}" >&2
	exit 66
fi

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

	# --reuse-values would carry the old values forward but ignore defaults the
	# newer chart introduces, so a subchart added since the last release starts
	# on its own empty defaults: keycloak arrived this way and looked for its
	# database on localhost. Resetting first takes the new chart's defaults and
	# then reapplies what the release actually set.
	set -- upgrade "${release}" "${chart}" -n "${NAMESPACE}" \
		--reset-then-reuse-values --wait --timeout "${HELM_TIMEOUT}"
	# Overlaid on top of the reused values, so the caller's file changes only
	# what it names and everything the bake configured survives.
	if [ -n "${extra_values}" ]; then
		set -- "$@" -f "${extra_values}"
	fi
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

# Helm rewrites every Deployment it owns back to what the chart says, and the
# browser-facing URLs are not in the chart: set-ingress-port.sh wrote them with
# `kubectl set env` when the host chose a port. An upgrade reverts them to the
# chart's default port, which now includes the OIDC issuer — leaving the Gateway
# fetching discovery from a port the ingress no longer publishes, and every
# login broken.
#
# The port itself survives, because it lives on the istio-ingressgateway
# Service and no chart owns that. So it is read back from there and re-applied.
# Idempotent: on a VM still using the default port this changes nothing.
host_port="$(kubectl -n istio-gateway get svc istio-ingressgateway \
	-o jsonpath='{.spec.ports[?(@.name=="https-hostport")].port}' 2>/dev/null || true)"
if [ -n "${host_port}" ] && [ -x /opt/agyn/set-ingress-port.sh ]; then
	log "re-applying the ingress host port ${host_port}"
	/opt/agyn/set-ingress-port.sh "${host_port}"
elif [ -n "${host_port}" ]; then
	log "WARNING: host port ${host_port} is in use but /opt/agyn/set-ingress-port.sh is missing;"
	log "         browser-facing URLs now point at the chart's default port"
fi

log "releases:"
helm list -n "${NAMESPACE}"
log "done"
