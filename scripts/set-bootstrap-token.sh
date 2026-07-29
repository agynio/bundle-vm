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

log() { printf '[set-bootstrap-token] %s\n' "$*"; }

if [ -z "${TOKEN}" ]; then
	log "no token supplied; leaving the image placeholder in place"
	exit 0
fi

until kubectl get --raw=/readyz >/dev/null 2>&1; do
	log "waiting for the API server"
	sleep 5
done

# The Gateway chart renders CLUSTER_ADMIN_TOKEN from a literal helm value, so
# the token lives in the Deployment spec and this is where it has to be
# replaced. `kubectl set env` also rolls the pods, which is required either
# way: the Gateway reads the token once, at container start.
current="$(kubectl get deployment gateway -n "${NAMESPACE}" \
	-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLUSTER_ADMIN_TOKEN")].value}' 2>/dev/null || true)"
if [ "${current}" = "${TOKEN}" ]; then
	log "token already current"
	exit 0
fi

kubectl set env deployment/gateway -n "${NAMESPACE}" "CLUSTER_ADMIN_TOKEN=${TOKEN}" >/dev/null
kubectl rollout status deployment/gateway -n "${NAMESPACE}" --timeout=300s
log "done"
