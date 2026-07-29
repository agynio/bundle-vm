#!/usr/bin/env bash
set -euo pipefail

# Points the browser-facing URLs at the port this host actually forwards.
#
# The image bakes a default (2496), but the host port is the user's choice —
# 2496 may already be taken, and nothing stops them picking 2498. Almost
# nothing in the VM cares: in-cluster traffic reaches services through cluster
# DNS, and the OpenZiti advertised host:port is a separate internal constant
# (see install-platform.sh). What does care is every URL a browser is handed
# back, because the browser connects from the host:
#
#   chat-app        OIDC_REDIRECT_URI, OIDC_POST_LOGOUT_REDIRECT_URI, MEDIA_PROXY_URL
#   media-proxy     CORS_ALLOWED_ORIGIN
#   terminal-proxy  TERMINAL_PROXY_WEBSOCKET_URL
#
# A wrong port here fails visibly: the OIDC provider redirects to a dead port
# after login, the browser blocks media on a CORS origin mismatch, and
# `agyn sandbox connect` is handed a ticket for a WebSocket nobody is serving.
#
# Idempotent: re-running with the port already in place changes nothing.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PORT="${1:-${AGYN_INGRESS_HOST_PORT:-}}"
NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-platform}"
BASE_DOMAIN="${AGYN_BASE_DOMAIN:-agyn.dev}"

log() { printf '[set-ingress-port] %s\n' "$*"; }

if [ -z "${PORT}" ]; then
	log "no port supplied; leaving the image default in place"
	exit 0
fi
case "${PORT}" in
*[!0-9]* | '')
	log "not a port number: ${PORT}"
	exit 1
	;;
esac

until kubectl get --raw=/readyz >/dev/null 2>&1; do
	log "waiting for the API server"
	sleep 5
done

chat_origin="https://chat.${BASE_DOMAIN}:${PORT}"
media_origin="https://media.${BASE_DOMAIN}:${PORT}"
terminal_url="wss://terminal.${BASE_DOMAIN}:${PORT}/terminal"

current="$(kubectl get deployment chat-app -n "${NAMESPACE}" \
	-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_POST_LOGOUT_REDIRECT_URI")].value}' 2>/dev/null || true)"
if [ "${current}" = "${chat_origin}" ]; then
	log "already serving on port ${PORT}"
	exit 0
fi

log "pointing browser-facing URLs at port ${PORT}"
kubectl set env deployment/chat-app -n "${NAMESPACE}" \
	"OIDC_REDIRECT_URI=${chat_origin}/callback" \
	"OIDC_POST_LOGOUT_REDIRECT_URI=${chat_origin}" \
	"MEDIA_PROXY_URL=${media_origin}" >/dev/null
kubectl set env deployment/media-proxy -n "${NAMESPACE}" \
	"CORS_ALLOWED_ORIGIN=${chat_origin}" >/dev/null
kubectl set env deployment/terminal-proxy -n "${NAMESPACE}" \
	"TERMINAL_PROXY_WEBSOCKET_URL=${terminal_url}" >/dev/null

kubectl rollout status deployment/chat-app -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/media-proxy -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/terminal-proxy -n "${NAMESPACE}" --timeout=300s
log "done"
