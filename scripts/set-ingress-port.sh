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
# The OIDC issuer is the awkward one, because it is a single URL used from two
# sides. The browser is redirected to it, and the Gateway and Media Proxy fetch
# discovery, JWKS and userinfo from it from inside the cluster — and zitadel/oidc
# rejects a discovery document whose issuer differs from the URL it came from,
# so both sides have to name the same host AND the same port. Moving the port
# therefore also moves:
#
#   istio-ingressgateway  the Service port in-cluster clients dial
#   keycloak              KC_HOSTNAME, the issuer it advertises
#   gateway, media-proxy  OIDC_ISSUER_URL
#   the four apps         OIDC_AUTHORITY
#   keycloak's realm      each client's redirectUris and webOrigins
#
# The realm ones cannot be re-imported: --import-realm is create-once, so they
# are updated through the Admin API instead.
#
# A wrong port here fails visibly: the OIDC provider redirects to a dead port
# after login, the browser blocks media on a CORS origin mismatch, and
# `agyn sandbox connect` is handed a ticket for a WebSocket nobody is serving.
#
# Idempotent: re-running with the port already in place changes nothing.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PORT="${1:-${AGYN_INGRESS_HOST_PORT:-}}"
NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-agyn-platform}"
BASE_DOMAIN="${AGYN_BASE_DOMAIN:-agyn.dev}"
REALM="${AGYN_KEYCLOAK_REALM:-agyn}"

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
auth_origin="https://auth.${BASE_DOMAIN}:${PORT}"
issuer="${auth_origin}/realms/${REALM}"

deployment_env() {
	kubectl get deployment "${1}" -n "${NAMESPACE}" \
		-o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${2}')].value}" 2>/dev/null || true
}

# Both are checked: the chat origin alone would call it done on a VM whose apps
# were moved but whose issuer was not, which is precisely the state that leaves
# login broken.
if [ "$(deployment_env chat-app OIDC_POST_LOGOUT_REDIRECT_URI)" = "${chat_origin}" ] &&
	[ "$(deployment_env gateway OIDC_ISSUER_URL)" = "${issuer}" ]; then
	log "already serving on port ${PORT}"
	exit 0
fi

# The Service port in-cluster clients dial for the issuer. 443, 80 and 15021 are
# already published by this Service, so a separate entry would be a duplicate.
patch_ingress_hostport() {
	case "${PORT}" in
	443 | 80 | 15021)
		log "host port ${PORT} is already published by the ingress Service"
		return 0
		;;
	esac

	local line index
	line="$(kubectl -n istio-gateway get svc istio-ingressgateway \
		-o jsonpath='{range .spec.ports[*]}{.name}{"\n"}{end}' 2>/dev/null |
		grep -n '^https-hostport$' | cut -d: -f1 || true)"

	if [ -n "${line}" ]; then
		index=$((line - 1))
		log "moving the ingress Service host port to ${PORT}"
		kubectl -n istio-gateway patch svc istio-ingressgateway --type=json \
			-p "[{\"op\":\"replace\",\"path\":\"/spec/ports/${index}/port\",\"value\":${PORT}}]" >/dev/null
	else
		log "adding the ingress Service host port ${PORT}"
		kubectl -n istio-gateway patch svc istio-ingressgateway --type=json \
			-p "[{\"op\":\"add\",\"path\":\"/spec/ports/-\",\"value\":{\"name\":\"https-hostport\",\"port\":${PORT},\"protocol\":\"TCP\",\"targetPort\":443}}]" >/dev/null
	fi
}

# Redirect URIs live in Keycloak's database, and the realm import will not
# revisit them, so they are rewritten in place.
update_keycloak_clients() {
	local password kcadm client id origin
	password="$(kubectl -n "${NAMESPACE}" get secret keycloak-auth \
		-o jsonpath='{.data.bootstrap-admin-password}' 2>/dev/null | base64 -d || true)"
	if [ -z "${password}" ]; then
		log "keycloak-auth secret not found; skipping the realm client update"
		return 0
	fi

	kcadm="kubectl -n ${NAMESPACE} exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh"
	if ! ${kcadm} config credentials --server http://localhost:8080 \
		--realm master --user admin --password "${password}" >/dev/null 2>&1; then
		log "keycloak is not answering; skipping the realm client update"
		return 0
	fi

	for client in console chat tracing sandboxes; do
		origin="https://${client}.${BASE_DOMAIN}:${PORT}"
		id="$(${kcadm} get clients -r "${REALM}" -q "clientId=agyn-${client}" \
			--fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)"
		if [ -z "${id}" ]; then
			log "  client agyn-${client} is not in the realm; skipped"
			continue
		fi
		log "  agyn-${client} -> ${origin}"
		${kcadm} update "clients/${id}" -r "${REALM}" \
			-s "redirectUris=[\"${origin}/*\"]" \
			-s "webOrigins=[\"${origin}\"]" \
			-s "attributes.\"post.logout.redirect.uris\"=\"${origin}/*\"" >/dev/null
	done
}

log "pointing browser-facing URLs at port ${PORT}"
patch_ingress_hostport

kubectl set env deployment/chat-app -n "${NAMESPACE}" \
	"OIDC_AUTHORITY=${issuer}" \
	"OIDC_REDIRECT_URI=${chat_origin}/callback" \
	"OIDC_POST_LOGOUT_REDIRECT_URI=${chat_origin}" \
	"MEDIA_PROXY_URL=${media_origin}" >/dev/null
kubectl set env deployment/console-app -n "${NAMESPACE}" \
	"OIDC_AUTHORITY=${issuer}" >/dev/null
kubectl set env deployment/tracing-app -n "${NAMESPACE}" \
	"OIDC_AUTHORITY=${issuer}" >/dev/null
kubectl set env deployment/sandboxes-app -n "${NAMESPACE}" \
	"OIDC_AUTHORITY=${issuer}" >/dev/null
kubectl set env deployment/media-proxy -n "${NAMESPACE}" \
	"OIDC_ISSUER_URL=${issuer}" \
	"CORS_ALLOWED_ORIGIN=${chat_origin}" >/dev/null
kubectl set env deployment/gateway -n "${NAMESPACE}" \
	"OIDC_ISSUER_URL=${issuer}" >/dev/null
kubectl set env deployment/terminal-proxy -n "${NAMESPACE}" \
	"TERMINAL_PROXY_WEBSOCKET_URL=${terminal_url}" >/dev/null
kubectl set env deployment/keycloak -n "${NAMESPACE}" \
	"KC_HOSTNAME=${auth_origin}" >/dev/null

# Keycloak first: the Gateway fetches discovery on start, and it has to be the
# new issuer that answers or the Gateway comes up rejecting every token.
kubectl rollout status deployment/keycloak -n "${NAMESPACE}" --timeout=300s
update_keycloak_clients

for deployment in chat-app console-app tracing-app sandboxes-app media-proxy gateway terminal-proxy; do
	kubectl rollout status "deployment/${deployment}" -n "${NAMESPACE}" --timeout=300s
done
log "done"
