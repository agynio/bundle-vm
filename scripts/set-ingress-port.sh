#!/usr/bin/env bash
set -euo pipefail

# Points the browser-facing URLs at the port this host actually forwards.
#
# The image bakes a default (2496), but the host port is the user's choice —
# 2496 may already be taken, and nothing stops them picking 2498. Most of the VM
# does not care: in-cluster traffic reaches services through cluster DNS. What
# cares is anything the host dials, starting with every URL a browser is handed
# back:
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
# The OpenZiti overlay moves too, for the same reason: a tunneler on the host
# dials the address an enrolment JWT names, so an overlay advertising a port the
# host does not forward cannot be reached from the only place devices enrol.
# See move_ziti_port for what that drags along.
#
# A wrong port here fails visibly: the OIDC provider redirects to a dead port
# after login, the browser blocks media on a CORS origin mismatch, and
# `agyn sandbox connect` is handed a ticket for a WebSocket nobody is serving.
#
# Idempotent: re-running with the port already in place changes nothing. The
# guards check every moving part rather than one, because a run that failed part
# way is exactly the state a single check reports as done.

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

# The OpenZiti client API Service port doubles as the advertised port, so it is
# what says whether the overlay has been moved yet.
ziti_port() {
	kubectl -n ziti get svc ziti-controller-client \
		-o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true
}

# Where the passthrough route sends it, which moves separately from the Service
# and so can be left behind by a run that failed part way.
ziti_route_port() {
	kubectl -n istio-gateway get virtualservice ziti-controller \
		-o jsonpath='{.spec.tls[0].route[0].destination.port.number}' 2>/dev/null || true
}

# Where the router caches the controller endpoints it last reached. Empty when
# the PVC has not been bound or the router has never connected.
router_endpoints_file() {
	local claim pv path
	claim="$(kubectl -n ziti get deploy ziti-router \
		-o jsonpath='{.spec.template.spec.volumes[?(@.name=="config-data")].persistentVolumeClaim.claimName}' 2>/dev/null || true)"
	[ -z "${claim}" ] && return 0
	pv="$(kubectl -n ziti get pvc "${claim}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
	[ -z "${pv}" ] && return 0
	path="$(kubectl get pv "${pv}" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"
	[ -n "${path}" ] && [ -f "${path}/endpoints.yml" ] && printf '%s' "${path}/endpoints.yml"
}

# Four things move independently, so "the overlay is on this port" is only true
# when all four say so. Checking one is how a half-moved VM reports itself done.
ziti_settled() {
	local cache
	[ "$(ziti_port)" = "${PORT}" ] || return 1
	[ "$(ziti_route_port)" = "${PORT}" ] || return 1
	[ "$(deployment_env ziti-management ZITI_CONTROLLER_URL)" = \
		"https://ziti-mgmt.${BASE_DOMAIN}:${PORT}/edge/management/v1" ] || return 1
	# Settled when the cache names no port other than this one.
	cache="$(router_endpoints_file)"
	[ -z "${cache}" ] && return 0
	! grep -oE "tls:ziti\.${BASE_DOMAIN}:[0-9]+" "${cache}" 2>/dev/null |
		grep -qv ":${PORT}\$"
}

# All three are checked: any one alone would call it done on a VM that moved
# only part way -- apps but not the issuer leaves login broken, and everything
# but the overlay leaves a device unable to enrol.
if [ "$(deployment_env chat-app OIDC_POST_LOGOUT_REDIRECT_URI)" = "${chat_origin}" ] &&
	[ "$(deployment_env gateway OIDC_ISSUER_URL)" = "${issuer}" ] &&
	ziti_settled; then
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

# The overlay advertises a host:port, and a tunneler on the host dials exactly
# what the enrolment JWT names -- so the advertised port has to be the one the
# host forwards, not an internal constant. Moving it moves four things that have
# to agree: the Service port (which the chart derives from advertisedPort), the
# address the controller advertises, the router's link to it, and the port the
# passthrough VirtualServices route to.
#
# Identities already enrolled carry the old address in their own ztAPI field.
# It is a plain URL beside the client certificate rather than part of what the
# certificate attests, so it is rewritten in place; the alternative is
# re-enrolling, and the one-time token that would take was spent at bake time.
move_ziti_port() {
	local current
	current="$(ziti_port)"
	if [ -z "${current}" ]; then
		log "no OpenZiti controller Service; skipping the overlay move"
		return 0
	fi
	if ziti_settled; then
		log "the overlay already advertises port ${PORT}"
		return 0
	fi

	# Skipped when only the routes are behind, which is where a run that failed
	# part way leaves things -- the charts are already where they should be and
	# upgrading them again would restart the controller for nothing.
	if [ "${current}" != "${PORT}" ]; then
		log "moving the OpenZiti overlay from port ${current} to ${PORT}"
		helm upgrade ziti-controller openziti/ziti-controller -n ziti --reuse-values \
			--set "clientApi.advertisedPort=${PORT}" \
			--set "managementApi.advertisedPort=${PORT}" --wait --timeout 5m >/dev/null
		helm upgrade ziti-router openziti/ziti-router -n ziti --reuse-values \
			--set "edge.advertisedPort=${PORT}" \
			--set "ctrl.endpoint=ziti.${BASE_DOMAIN}:${PORT}" --wait --timeout 5m >/dev/null
	fi

	# The passthrough routes carry the host's traffic to those Services, so they
	# move with the Service port or the hostname stops resolving to anything.
	# They match on SNI and hand the connection over untouched, which puts them
	# under tls rather than tcp.
	local vs
	for vs in ziti-controller ziti-controller-mgmt ziti-router; do
		kubectl -n istio-gateway patch virtualservice "${vs}" --type=json \
			-p "[{\"op\":\"replace\",\"path\":\"/spec/tls/0/route/0/destination/port/number\",\"value\":${PORT}}]" \
			>/dev/null 2>&1 ||
			log "  virtualservice ${vs} not patched; check its route shape"
	done

	# The one platform service that dials the overlay's management API by URL
	# rather than reaching it through an identity.
	if kubectl -n "${NAMESPACE}" get deployment ziti-management >/dev/null 2>&1; then
		log "  re-pointing ziti-management at port ${PORT}"
		kubectl set env "deployment/ziti-management" -n "${NAMESPACE}" \
			"ZITI_CONTROLLER_URL=https://ziti-mgmt.${BASE_DOMAIN}:${PORT}/edge/management/v1" >/dev/null
	fi

	# The provisioning Job's script logs in by URL too. It has already run, so
	# this changes nothing today -- but it is what a later re-run would read,
	# and a re-run that hangs on an unreachable port is a bad way to find out.
	if kubectl -n ziti get cm ziti-provision-script >/dev/null 2>&1; then
		kubectl -n ziti get cm ziti-provision-script -o yaml |
			sed "s|\(ziti-mgmt\.${BASE_DOMAIN}\):${current}|\1:${PORT}|g" |
			kubectl apply -f - >/dev/null
	fi

	repoint_router_endpoints
	rewrite_enrolled_identities "${current}"
	restart_ziti_consumers
}

# Everything that dials the overlay learned the controller's address when it
# started and holds it for the life of the process, so a moved port leaves them
# retrying one that no longer answers -- visible as services losing their
# terminators and staying unbound. Selected by carrying a ZITI_ variable rather
# than by name, so a release that adds another service is covered by default.
restart_ziti_consumers() {
	local names
	names="$(kubectl -n "${NAMESPACE}" get deployments -o json 2>/dev/null |
		python3 -c '
import json,sys
try: items = json.load(sys.stdin)["items"]
except Exception: sys.exit(0)
for i in items:
    env = [e["name"] for c in i["spec"]["template"]["spec"]["containers"] for e in (c.get("env") or [])]
    if any(n.startswith("ZITI_") for n in env):
        print(i["metadata"]["name"])
' 2>/dev/null || true)"
	[ -z "${names}" ] && return 0

	# ziti-management first and on its own: it is what mints the identities the
	# others authenticate with, so restarting them alongside it only has them
	# retry against a service that is itself still starting.
	if printf '%s\n' "${names}" | grep -qx ziti-management; then
		log "  restarting ziti-management"
		kubectl -n "${NAMESPACE}" rollout restart deployment/ziti-management >/dev/null 2>&1 || true
		kubectl -n "${NAMESPACE}" rollout status deployment/ziti-management --timeout=180s >/dev/null 2>&1 || true
	fi

	local name
	for name in ${names}; do
		[ "${name}" = "ziti-management" ] && continue
		log "  restarting ${name}"
		kubectl -n "${NAMESPACE}" rollout restart "deployment/${name}" >/dev/null 2>&1 || true
	done
}

# The router caches the controller endpoints it last connected to and prefers
# that file over its config, so setting ctrl.endpoint alone leaves it dialling
# the old port until it gives up ("unable to connect to any controllers before
# timeout"). The file lives on its PVC, which the local-path provisioner backs
# with a directory on this node.
repoint_router_endpoints() {
	local cache
	cache="$(router_endpoints_file)"
	[ -z "${cache}" ] && return 0
	grep -q "tls:ziti\.${BASE_DOMAIN}:${PORT}\$" "${cache}" 2>/dev/null &&
		! grep -oE "tls:ziti\.${BASE_DOMAIN}:[0-9]+" "${cache}" | grep -qv ":${PORT}\$" &&
		return 0

	log "  re-pointing the router's cached controller endpoints at port ${PORT}"
	sed -i -E "s|(tls:ziti\.${BASE_DOMAIN}):[0-9]+|\1:${PORT}|g" "${cache}"
	kubectl -n ziti rollout restart deployment/ziti-router >/dev/null 2>&1 || true
}

restart_mounters() {
	local ns="${1}" secret="${2}" deployment
	for deployment in $(kubectl -n "${ns}" get deployments \
		-o jsonpath="{range .items[?(@.spec.template.spec.volumes[*].secret.secretName=='${secret}')]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null); do
		log "    restarting ${ns}/${deployment}"
		kubectl -n "${ns}" rollout restart "deployment/${deployment}" >/dev/null 2>&1 || true
	done
}

# Every Secret holding an enrolled identity.json, wherever it lives: the set
# differs by which first-party apps a release ships.
rewrite_enrolled_identities() {
	local from="${1}" ns name payload updated
	while read -r ns name; do
		[ -z "${ns}" ] && continue
		payload="$(kubectl -n "${ns}" get secret "${name}" \
			-o jsonpath='{.data.identity\.json}' 2>/dev/null | base64 -d || true)"
		case "${payload}" in
		*":${from}/edge/"*) ;;
		*) continue ;;
		esac
		updated="$(printf '%s' "${payload}" | sed "s|:${from}/edge/|:${PORT}/edge/|g")"
		log "  re-pointing ${ns}/${name} at port ${PORT}"
		kubectl -n "${ns}" patch secret "${name}" --type=json \
			-p "[{\"op\":\"replace\",\"path\":\"/data/identity.json\",\"value\":\"$(printf '%s' "${updated}" | base64 | tr -d '\n')\"}]" \
			>/dev/null
		# The identity is read at start, so whoever mounts it has to restart.
		# Found by what references the Secret rather than by name: a chart is
		# free to prefix its release onto the Deployment and not the Secret.
		restart_mounters "${ns}" "${name}"
	done <<-EOF
		$(kubectl get secrets --all-namespaces \
			-o jsonpath='{range .items[?(@.data.identity\.json)]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)
	EOF
}

log "pointing browser-facing URLs at port ${PORT}"
patch_ingress_hostport
move_ziti_port

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
