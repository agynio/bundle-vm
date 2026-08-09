#!/usr/bin/env bash
set -euo pipefail

# Installs the Gateway bootstrap token this machine was given.
#
# The platform is installed while the image is built, so whatever token the
# build used would otherwise ship inside every copy of that image: identical on
# every machine running a given published version, present on the CDN, and not
# rotatable without a rebuild. The host generates a token per install and hands
# it here, so the published image carries nothing usable against a running VM.
#
# Idempotent: re-running with the same token changes nothing.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

TOKEN="${1:-${AGYN_BOOTSTRAP_TOKEN:-}}"
NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-platform}"
SECRET="${AGYN_BOOTSTRAP_TOKEN_SECRET:-gateway-bootstrap-token}"
KEY="${AGYN_BOOTSTRAP_TOKEN_KEY:-token}"

log() { printf '[set-bootstrap-token] %s\n' "$*"; }

if [ -z "${TOKEN}" ]; then
	log "no token supplied; leaving the image placeholder in place"
	exit 0
fi

until kubectl get --raw=/readyz >/dev/null 2>&1; do
	log "waiting for the API server"
	sleep 5
done

# The chart generates the Secret on install and reuses whatever it finds on
# upgrade, so writing here is what makes the host's token survive an upgrade
# without a step that puts it back afterwards.
until kubectl get secret "${SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; do
	log "waiting for secret ${SECRET}"
	sleep 5
done

current="$(kubectl get secret "${SECRET}" -n "${NAMESPACE}" \
	-o jsonpath="{.data.${KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ "${current}" = "${TOKEN}" ]; then
	log "token already current"
	exit 0
fi

kubectl patch secret "${SECRET}" -n "${NAMESPACE}" \
	--type merge -p "{\"stringData\":{\"${KEY}\":\"${TOKEN}\"}}" >/dev/null

# The Gateway reads CLUSTER_ADMIN_TOKEN once, at container start, so a changed
# Secret only takes effect on a restart.
kubectl rollout restart deployment/gateway -n "${NAMESPACE}" >/dev/null
kubectl rollout status deployment/gateway -n "${NAMESPACE}" --timeout=300s
log "done"
