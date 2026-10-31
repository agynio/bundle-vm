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
# re-applied as soon as Helm has applied the release, and only then is the
# rollout waited for: on any port but the baked one, the services that dial the
# overlay cannot come up until it is.
#
# --values overlays a file on top of the reused values, for settings the image
# cannot know: an external OIDC issuer instead of the bundled Keycloak, say. It
# is an overlay, not a replacement — anything it does not name keeps the value
# the bake or `agyn local start` gave it.
#
# What this does NOT do: upgrade k3s, Istio, cert-manager, OpenZiti, or Postgres.
# Those come from the image, and moving them is what a new image is for.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-agyn-platform}"
PLATFORM_CHART="${AGYN_PLATFORM_CHART:-oci://ghcr.io/agynio/charts/agyn-platform}"
HELM_TIMEOUT="${AGYN_HELM_TIMEOUT:-15m}"

# Named rather than positional: a values path and a chart version are easy to
# transpose, and the failure would be a silent no-op or a wrong chart.
platform_version=""
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

# The timeout in seconds, for the rollout this script waits for itself. Go's
# duration syntax in the units a timeout is written in (15m, 1h30m, 900s), and
# read here so a value it cannot use stops the upgrade before it starts.
rollout_timeout=0
rest="${HELM_TIMEOUT}"
while [[ "${rest}" =~ ^([0-9]+)([hms])(.*)$ ]]; do
	case "${BASH_REMATCH[2]}" in
	h) rollout_timeout=$((rollout_timeout + 10#${BASH_REMATCH[1]} * 3600)) ;;
	m) rollout_timeout=$((rollout_timeout + 10#${BASH_REMATCH[1]} * 60)) ;;
	s) rollout_timeout=$((rollout_timeout + 10#${BASH_REMATCH[1]})) ;;
	esac
	rest="${BASH_REMATCH[3]}"
done
if [ -n "${rest}" ] || [ "${rollout_timeout}" -eq 0 ]; then
	echo "not a timeout: ${HELM_TIMEOUT}" >&2
	exit 64
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
	#
	# No --wait. The upgrade puts the baked port back into every Deployment that
	# names it, and on a VM forwarding any other port ziti-management and every
	# service that dials the overlay crash-loop on a port nothing serves, until
	# set-ingress-port.sh points them back -- which cannot run while Helm waits
	# for them, so the wait ran out the timeout. --timeout still bounds the
	# chart's hooks, which Helm waits for regardless; the rollout is waited for
	# once the port is back.
	set -- upgrade "${release}" "${chart}" -n "${NAMESPACE}" \
		--reset-then-reuse-values --timeout "${HELM_TIMEOUT}"
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

	# Returned rather than left to `set -e`, which does not apply inside a
	# function its caller tests: a failed upgrade still has the port put back.
	if ! helm "$@"; then
		log "${release}: upgrade failed"
		return 1
	fi

	after="$(installed_version "${release}")"
	log "${release} now at ${after:-unknown}"
	if [ -n "${before}" ] && [ "${before}" = "${after}" ]; then
		log "${release} was already up to date"
	fi
}

# What --wait used to wait for, once nothing has to wait on the port: every
# workload the release owns finishing its rollout. Found by the annotation Helm
# puts on what it manages, so a workload a newer chart adds is waited for, and
# one another release or a person put in the namespace is not. OnDelete ones
# are skipped, as --wait skipped them: nothing rolls those out until their pods
# are deleted.
#
# Polled until the timeout, as --wait polled, rather than settled by kubectl's
# first answer: kubectl gives up on a Deployment past its progress deadline,
# and one that crash-looped until the port came back can be past it and still
# come up on its next restart.
wait_for_rollout() {
	release="${1}"
	workloads="$(kubectl -n "${NAMESPACE}" get deployments,statefulsets,daemonsets \
		-o jsonpath="{range .items[?(@.metadata.annotations.meta\.helm\.sh/release-name=='${release}')]}{.kind}/{.metadata.name} {.spec.updateStrategy.type}{\"\n\"}{end}")"
	log "waiting for ${release} to roll out"
	SECONDS=0
	while read -r workload strategy; do
		if [ -z "${workload}" ] || [ "${strategy}" = OnDelete ]; then
			continue
		fi
		until kubectl -n "${NAMESPACE}" rollout status "${workload}" \
			--timeout "$((rollout_timeout > SECONDS ? rollout_timeout - SECONDS : 1))s" 2>/dev/null; do
			if [ "${SECONDS}" -ge "${rollout_timeout}" ]; then
				log "${workload} did not finish rolling out in ${HELM_TIMEOUT}"
				return 1
			fi
			sleep 10
		done
	done <<<"${workloads}"
}

# The runner and the apps used to be their own release, and Helm refuses to
# adopt resources another release owns. A VM built before the fold still has
# agyn-apps, so it goes first -- otherwise the upgrade fails on the k8s-runner
# workload and its NetworkPolicy. Nothing is lost: both are re-registered from
# the declarations, and their service tokens live in Secrets, not the release.
if helm status agyn-apps -n "${NAMESPACE}" >/dev/null 2>&1; then
	log "removing the standalone agyn-apps release; the umbrella owns it now"
	helm uninstall agyn-apps -n "${NAMESPACE}" --wait
fi

# The port this host forwards, read before the upgrade rather than after it.
# set-ingress-port.sh keeps it on the istio-ingressgateway Service, but the
# bundled OIDC provider's chart publishes that Service port too: its wiring hook
# sets it from the release's values, which still name the port the image was
# baked with, and runs before the upgrade applies anything. Read afterwards it
# is the baked port, and re-applying that moves the VM off the port its host
# forwards.
host_port="$(kubectl -n istio-gateway get svc istio-ingressgateway \
	-o jsonpath='{.spec.ports[?(@.name=="https-hostport")].port}' 2>/dev/null || true)"

# One release. The runner and the apps ship inside the umbrella, so there is no
# second chart to keep in step with it.
upgrade_failed=0
upgrade agyn-platform "${PLATFORM_CHART}" "${platform_version}" || upgrade_failed=1

# Helm rewrites every Deployment it owns back to what the chart says, and the
# browser-facing URLs are not in the chart: set-ingress-port.sh wrote them with
# `kubectl set env` when the host chose a port. An upgrade reverts them to the
# chart's default port, which now includes the OIDC issuer — leaving the Gateway
# fetching discovery from a port the ingress no longer publishes, and every
# login broken. The overlay's address goes back the same way, and every service
# that dials it crash-loops until it is put back.
#
# Put back even when the upgrade failed: the hook may have moved the Service
# already, and the next attempt reads the port from there.
# Idempotent: on a VM still using the default port this changes nothing.
if [ -n "${host_port}" ] && [ -x /opt/agyn/set-ingress-port.sh ]; then
	log "re-applying the ingress host port ${host_port}"
	/opt/agyn/set-ingress-port.sh "${host_port}"
elif [ -n "${host_port}" ]; then
	log "WARNING: host port ${host_port} is in use but /opt/agyn/set-ingress-port.sh is missing;"
	log "         browser-facing URLs now point at the chart's default port"
fi

if [ "${upgrade_failed}" -ne 0 ]; then
	exit 1
fi
wait_for_rollout agyn-platform

log "releases:"
helm list -n "${NAMESPACE}"
log "done"
