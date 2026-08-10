#!/usr/bin/env bash
set -euo pipefail

# Installs the Agyn platform on top of a booted bundle-vm-base guest with plain
# Helm. The base image provides k3s + cert-manager + helm; the ingress layer is
# installed by install-ingress.sh. Chart versions are pinned here; values live
# in deploy/values/ with {{BASE_DOMAIN}}/{{INGRESS_PORT}}/{{INGRESS_HOST_PORT}}
# substituted at install time.
#
# The two ports are not the same thing:
#
#   INGRESS_PORT       What OpenZiti advertises, enrollment JWTs embed, and the
#                      ziti VirtualServices route to. It follows the host port
#                      rather than standing as its own constant: a tunneler on
#                      the host dials exactly the address a JWT names, so an
#                      overlay advertising a port the host does not forward is
#                      unreachable from the only place that enrols devices.
#
#   INGRESS_HOST_PORT  What the host forwards onto the ingress NodePort, and so
#                      the port everything else derives from. The value baked
#                      here is a default the host is free to override:
#                      set-ingress-port.sh moves both sets on first boot.
#
# They are the same number. The split above is which traffic each describes,
# not two independently chosen ports.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive

DEPLOY_DIR=/tmp/deploy
BASE_DOMAIN="${BASE_DOMAIN:-agyn.dev}"
INGRESS_HOST_PORT="${INGRESS_HOST_PORT:-2496}"
INGRESS_PORT="${INGRESS_HOST_PORT}"
HELM_TIMEOUT=15m

TRUST_MANAGER_VERSION=v0.22.0
ZITI_CONTROLLER_VERSION=3.2.0-pre6
ZITI_ROUTER_VERSION=3.0.0-pre5
AGYN_PLATFORM_VERSION=0.42.1

log() { printf '[install-platform] %s\n' "$*"; }

render() {
	sed -e "s/{{BASE_DOMAIN}}/${BASE_DOMAIN}/g" \
		-e "s/{{INGRESS_PORT}}/${INGRESS_PORT}/g" \
		-e "s/{{INGRESS_HOST_PORT}}/${INGRESS_HOST_PORT}/g" "${1}"
}

values() {
	render "${DEPLOY_DIR}/values/${1}.yaml" >"/tmp/values-${1}.yaml"
	printf '/tmp/values-%s.yaml' "${1}"
}

# 1) Supporting manifests: namespaces, secrets, shared Postgres, CoreDNS
#    rewrites, Istio routing, the ziti-provision Job.
log "applying manifests under ${DEPLOY_DIR}/manifests"
while IFS= read -r -d '' manifest; do
	log "  apply ${manifest}"
	render "${manifest}" | kubectl apply --validate=false -f -
done < <(find "${DEPLOY_DIR}/manifests" -maxdepth 1 -name '*.yaml' -print0 | sort -z)

# 2) Chart repositories.
log "adding helm repositories"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add openziti https://openziti.io/helm-charts >/dev/null
helm repo update jetstack openziti >/dev/null

# 3) trust-manager (distributes the ziti controller trust bundle).
log "trust-manager ${TRUST_MANAGER_VERSION}"
# The chart creates its own Bundle alongside the webhook that validates one, and
# the webhook's caBundle is patched by cert-manager's CA injector a moment after
# the ValidatingWebhookConfiguration appears. Installing into that window fails
# with "x509: certificate signed by unknown authority" -- a race that resolves
# on its own, so it is retried rather than waited out from the outside.
trust_manager_attempts=6
for attempt in $(seq 1 "${trust_manager_attempts}"); do
	if helm upgrade --install trust-manager jetstack/trust-manager \
		--version "${TRUST_MANAGER_VERSION}" -n cert-manager \
		--wait --timeout "${HELM_TIMEOUT}" -f "$(values trust-manager)"; then
		break
	fi
	if [ "${attempt}" -eq "${trust_manager_attempts}" ]; then
		echo "[install-platform] trust-manager install failed after ${trust_manager_attempts} attempts" >&2
		kubectl get validatingwebhookconfiguration -o wide >&2 || true
		kubectl get pods -n cert-manager -o wide >&2 || true
		exit 1
	fi
	log "trust-manager install failed (attempt ${attempt}); the webhook CA may not be injected yet, retrying"
	sleep 10
done

# --wait returns when the Deployment reports Ready, which is a step short of the
# API server being able to *admit* a Bundle. The ziti-controller chart below
# creates one, and admitting it calls trust-manager's validating webhook.
#
# Waiting for the webhook Service's endpoints is not enough: they were already
# registered every time this failed, and the call still came back "x509:
# certificate signed by unknown authority" -- the webhook is served with a
# cert-manager certificate, and the API server cannot verify it until
# ca-injector has written the CA into the ValidatingWebhookConfiguration.
#
# So probe the thing itself with a server-side dry run. Any answer from the
# webhook, admitting the probe or rejecting it, proves it is reachable and
# trusted; only a call that never got there is retried.
probe_file="$(mktemp)"
cat >"${probe_file}" <<'PROBE'
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: trust-manager-webhook-probe
spec:
  sources:
    - useDefaultCAs: true
  target:
    configMap:
      key: probe.pem
PROBE
log "waiting for the trust-manager webhook"
for attempt in $(seq 1 60); do
	probe_out="$(kubectl create --dry-run=server -f "${probe_file}" 2>&1)" && break
	case "${probe_out}" in
	*"failed calling webhook"*)
		if [ "${attempt}" -eq 60 ]; then
			echo "[install-platform] trust-manager webhook never answered: ${probe_out}" >&2
			kubectl get validatingwebhookconfiguration trust-manager -o yaml >&2 || true
			kubectl get pods -n cert-manager -o wide >&2 || true
			exit 1
		fi
		sleep 5
		;;
	*) break ;;
	esac
done
rm -f "${probe_file}"

# 4) OpenZiti controller, then the provision Job (which needs the controller
#    API), then the router (which needs the Job's enrollment secret).
log "ziti-controller ${ZITI_CONTROLLER_VERSION}"
helm upgrade --install ziti-controller openziti/ziti-controller \
	--version "${ZITI_CONTROLLER_VERSION}" -n ziti \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values ziti-controller)"

log "waiting for ziti-provision job"
kubectl -n ziti wait --for=condition=complete job/ziti-provision --timeout=15m

log "ziti-router ${ZITI_ROUTER_VERSION}"
helm upgrade --install ziti-router openziti/ziti-router \
	--version "${ZITI_ROUTER_VERSION}" -n ziti \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values ziti-router)"

# The data layer is not installed here. OpenFGA, its database and MinIO are
# subcharts of the umbrella, so the release that needs them deploys them --
# standing up copies beside it left two owners for one dependency and a
# connection string in this file to keep in step with both.

# metering used to be its own release, from before the umbrella carried it. An
# image built then still has that release, and Helm refuses to adopt resources
# another release owns — so it is removed here before the umbrella renders its
# own copy. Nothing is lost: the data lives in Postgres, not the release.
if helm status metering -n agyn-platform >/dev/null 2>&1; then
	log "removing the standalone metering release; the umbrella owns it now"
	helm uninstall metering -n agyn-platform --wait
fi

# The runner and the apps used to be their own release. An image built then
# still has it, and Helm refuses to adopt resources another release owns -- the
# collision is real and immediate: agyn-apps owns the k8s-runner workload and
# its agent-workload-egress NetworkPolicy, both of which the umbrella now
# renders. Removed here for the same reason metering was, and nothing is lost:
# the runner and the apps are re-registered from the declarations, and their
# service tokens live in Secrets the controller wrote, not in the release.
if helm status agyn-apps -n agyn-platform >/dev/null 2>&1; then
	log "removing the standalone agyn-apps release; the umbrella owns it now"
	helm uninstall agyn-apps -n agyn-platform --wait
fi

# 6) The platform umbrella. No --wait: migrations and self-enrollment retry on
#    their own schedules; prepull-and-wait.sh watches overall convergence.
log "agyn-platform ${AGYN_PLATFORM_VERSION}"
# --timeout, but still no --wait: the release's own hooks are the only thing
# waited on, and one of them now migrates against a datastore this release also
# brings. Five minutes is Helm's default and is shorter than Postgres and
# OpenFGA starting from cold.
helm upgrade --install agyn-platform oci://ghcr.io/agynio/charts/agyn-platform \
	--version "${AGYN_PLATFORM_VERSION}" -n agyn-platform \
	--timeout "${HELM_TIMEOUT}" \
	-f "$(values agyn-platform)"

# 7) The authorization model every workload checks against.
# This step waits on things the whole platform has to be up for, and a bare
# timeout says nothing about which workload never came up — the build's VM is
# gone by the time anyone reads the log — so dump the cluster's own account of
# it before failing.
diagnose() { # what
	log "$1 did not converge; cluster state follows"
	kubectl -n agyn-platform get pods -o wide || true
	kubectl -n agyn-platform logs deployment/gateway --tail=100 --all-containers || true
	# Whatever is not up is usually the reason, and its own logs say why far
	# better than the event list does. Guessing from events cost several
	# 24-minute builds.
	for pod in $(kubectl -n agyn-platform get pods --no-headers |
		awk '$2 != "READY" && $3 != "Completed" { print $1 }' ); do
		ready="$(kubectl -n agyn-platform get pod "${pod}" -o jsonpath='{.status.containerStatuses[*].ready}')"
		case "${ready}" in
		*false*) ;;
		*) continue ;;
		esac
		log "--- describe ${pod}"
		kubectl -n agyn-platform describe pod "${pod}" | tail -30 || true
		log "--- logs ${pod}"
		kubectl -n agyn-platform logs "${pod}" --tail=60 --all-containers || true
		kubectl -n agyn-platform logs "${pod}" --tail=60 --all-containers --previous 2>/dev/null || true
	done
	kubectl -n agyn-platform get events --sort-by=.lastTimestamp | tail -40 || true

	# What the release declared and how far provisioning got with it. Without
	# this the failure reads as two workloads stuck on a missing Secret, which
	# says nothing about the declaration that never produced it.
	echo "[install-platform] --- declarations"
	kubectl -n agyn-platform get organizations,clusteradmins,images,runners,apps,overlaypolicies 2>/dev/null || true
	kubectl -n agyn-platform describe organizations,runners,apps 2>/dev/null | grep -E "^Name:|Reason:|Message:|Status:" | head -40 || true
	kubectl -n agyn-platform logs deployment/platform-controller --tail=60 2>/dev/null || true
}

# Verify the authorization model.
#
# The authorization-openfga Secret names an OpenFGA store and model; every
# authz check resolves against them. An image whose Secret names a model OpenFGA
# does not have is comprehensively broken but boots looking healthy: pods go
# Ready, the Gateway serves, and the failure only appears as
# "authorization_model_not_found" the first time anything checks a permission —
# which then crashloops the k8s-runner, because runner enrollment is an authz
# call. This has shipped once already.
#
# The migration is idempotent and reuses an identical model, so re-running it is
# a no-op when the Secret is right and repairs it when it drifted.
log "verifying the authorization model"
store="$(kubectl -n agyn-platform get secret authorization-openfga -o jsonpath='{.data.OPENFGA_STORE_ID}' | base64 -d)"
model="$(kubectl -n agyn-platform get secret authorization-openfga -o jsonpath='{.data.OPENFGA_MODEL_ID}' | base64 -d)"
if kubectl -n agyn-platform exec deploy/authorization -- \
	wget -q -O /dev/null "http://openfga:8080/stores/${store}/authorization-models/${model}"; then
	log "  model ${model} present"
else
	log "  model ${model} missing from store ${store}; re-running the migration"
	# Same job, run again. A completed Job is immutable, so it is deleted and
	# recreated from its own spec under its own name — the selector and pod
	# labels are Job-controller state, not something to carry across.
	kubectl -n agyn-platform get job authorization-migrate -o json |
		python3 -c 'import json,sys; j=json.load(sys.stdin); j["metadata"]={"name":"authorization-migrate","namespace":"agyn-platform"}; j["spec"].pop("selector",None); j["spec"]["template"]["metadata"].pop("labels",None); j.pop("status",None); print(json.dumps(j))' \
			>/tmp/authorization-migrate.json
	kubectl -n agyn-platform delete job authorization-migrate --wait
	kubectl apply -f /tmp/authorization-migrate.json
	rm -f /tmp/authorization-migrate.json
	kubectl -n agyn-platform wait --for=condition=complete job/authorization-migrate --timeout=5m
	kubectl -n agyn-platform logs job/authorization-migrate
	kubectl -n agyn-platform rollout restart deploy/authorization
	kubectl -n agyn-platform rollout status deploy/authorization --timeout=5m
fi

# The runner and the apps ship inside the umbrella and are declared by it, so
# there is no second release and nothing to register by hand between them. Both
# mount a service token the provisioning controller writes, and may start before
# it exists and retry until it does -- which needs no action here.

log "helm releases:"
helm list -A
