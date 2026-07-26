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
SECRET_NAME="${AGYN_BOOTSTRAP_TOKEN_SECRET:-gateway-bootstrap-token}"

log() { printf '[set-bootstrap-token] %s\n' "$*"; }

if [ -z "${TOKEN}" ]; then
	log "no token supplied; leaving the image placeholder in place"
	exit 0
fi

until kubectl get --raw=/readyz >/dev/null 2>&1; do
	log "waiting for the API server"
	sleep 5
done

current="$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
	-o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ "${current}" = "${TOKEN}" ]; then
	log "token already current"
	exit 0
fi

kubectl create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
	--from-literal=token="${TOKEN}" \
	--dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "token stored in secret ${SECRET_NAME}"

# The Gateway reads the token from its environment at container start, so a
# running pod holds the old value until it is replaced.
if kubectl get deployment gateway -n "${NAMESPACE}" >/dev/null 2>&1; then
	kubectl rollout restart deployment/gateway -n "${NAMESPACE}" >/dev/null
	kubectl rollout status deployment/gateway -n "${NAMESPACE}" --timeout=300s
fi
log "done"
