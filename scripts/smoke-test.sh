#!/usr/bin/env bash
set -euo pipefail

# Checks that the platform the image ships can actually serve what the Gateway
# advertises.
#
# prepull-and-wait.sh already proves every deployed workload is Running. What it
# cannot see is a service the Gateway is configured to dial that was never
# deployed at all: nothing crashes, nothing is unready, and the failure only
# surfaces when a user clicks the feature and the call dies with
#
#   name resolver error: produced zero addresses
#
# That is how private networks shipped broken. This closes that gap by walking
# the Gateway's own upstream list and requiring each target to resolve to a
# Service with ready endpoints.

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-platform}"

log() { printf '[smoke-test] %s\n' "$*"; }

# Upstreams the Gateway advertises but this image deliberately does not deploy.
# Listing one here is a statement that the feature is knowingly unavailable —
# not that it works. Anything reachable from the console should not be here.
#
#   expose       — expose.enabled=false; no e2e covers port exposure
#   agent-state  — no such service exists in any chart; the Gateway carries a
#                  target for one that was never built
SKIP_TARGETS="expose agent-state"

failures=0
checked=0

targets="$(kubectl get deploy gateway -n "${NAMESPACE}" \
	-o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null |
	grep -E '_GRPC_TARGET=' || true)"

if [ -z "${targets}" ]; then
	log "could not read the Gateway's upstream targets; is it deployed?"
	exit 1
fi

while IFS= read -r line; do
	[ -n "${line}" ] || continue
	name="${line%%=*}"
	value="${line#*=}"
	host="${value%%:*}"
	[ -n "${host}" ] || continue

	skip=0
	for skipped in ${SKIP_TARGETS}; do
		if [ "${host}" = "${skipped}" ]; then
			log "skipping ${name} -> ${host} (knowingly not deployed)"
			skip=1
			break
		fi
	done
	[ "${skip}" -eq 1 ] && continue

	checked=$((checked + 1))
	endpoints="$(kubectl get endpoints "${host}" -n "${NAMESPACE}" \
		-o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
	if [ -z "${endpoints}" ]; then
		log "FAIL ${name} -> ${host}: no ready endpoints"
		failures=$((failures + 1))
	fi
done <<EOF
${targets}
EOF

if [ "${failures}" -gt 0 ]; then
	log "${failures} of ${checked} Gateway upstreams have no endpoints"
	kubectl get pods -n "${NAMESPACE}" || true
	exit 1
fi

log "all ${checked} Gateway upstreams resolve to ready endpoints"
