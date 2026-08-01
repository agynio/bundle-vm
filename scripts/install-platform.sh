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
#   INGRESS_PORT       An internal constant. OpenZiti advertises it, enrollment
#                      JWTs embed it, the ziti VirtualServices route to it. All
#                      of that traffic stays inside the VM (coredns-custom
#                      rewrites point the ziti hostnames at ClusterIPs), so it
#                      is fixed at bake time and never reconfigured.
#
#   INGRESS_HOST_PORT  What the host forwards onto the ingress NodePort. Only
#                      browser-facing URLs contain it, and a user is free to
#                      pick any port, so the value baked here is just a default:
#                      set-ingress-port.sh rewrites those URLs on first boot
#                      when the host chose something else.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive

DEPLOY_DIR=/tmp/deploy
BASE_DOMAIN="${BASE_DOMAIN:-agyn.dev}"
INGRESS_PORT=2496
INGRESS_HOST_PORT="${INGRESS_HOST_PORT:-2496}"
HELM_TIMEOUT=15m

TRUST_MANAGER_VERSION=v0.22.0
ZITI_CONTROLLER_VERSION=3.2.0-pre6
ZITI_ROUTER_VERSION=3.0.0-pre5
POSTGRES_HELM_VERSION=0.1.1
OPENFGA_VERSION=0.2.56
MINIO_VERSION=5.4.0
AGYN_PLATFORM_VERSION=0.9.9
AGYN_APPS_VERSION=0.1.0

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
helm repo add minio https://charts.min.io >/dev/null
helm repo add openfga https://openfga.github.io/helm-charts >/dev/null
helm repo update jetstack openziti minio openfga >/dev/null

# 3) trust-manager (distributes the ziti controller trust bundle).
log "trust-manager ${TRUST_MANAGER_VERSION}"
helm upgrade --install trust-manager jetstack/trust-manager \
	--version "${TRUST_MANAGER_VERSION}" -n cert-manager \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values trust-manager)"

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

# 5) Data layer.
log "openfga-db (postgres-helm ${POSTGRES_HELM_VERSION})"
helm upgrade --install openfga-db oci://ghcr.io/agynio/charts/postgres-helm \
	--version "${POSTGRES_HELM_VERSION}" -n openfga \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values openfga-db)"

log "openfga ${OPENFGA_VERSION}"
helm upgrade --install openfga openfga/openfga \
	--version "${OPENFGA_VERSION}" -n openfga \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values openfga)"

log "minio ${MINIO_VERSION}"
helm upgrade --install minio minio/minio \
	--version "${MINIO_VERSION}" -n minio \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values minio)"

# metering used to be its own release, from before the umbrella carried it. An
# image built then still has that release, and Helm refuses to adopt resources
# another release owns — so it is removed here before the umbrella renders its
# own copy. Nothing is lost: the data lives in Postgres, not the release.
if helm status metering -n platform >/dev/null 2>&1; then
	log "removing the standalone metering release; the umbrella owns it now"
	helm uninstall metering -n platform --wait
fi

# 6) The platform umbrella. No --wait: migrations and self-enrollment retry on
#    their own schedules; prepull-and-wait.sh watches overall convergence.
log "agyn-platform ${AGYN_PLATFORM_VERSION}"
helm upgrade --install agyn-platform oci://ghcr.io/agynio/charts/agyn-platform \
	--version "${AGYN_PLATFORM_VERSION}" -n platform \
	-f "$(values agyn-platform)"

# 7) Apps layer: wait for the apps-provision Job (admin tuple + k8s-runner
#    registration + service-token secret, ported from bootstrap stacks/apps),
#    then the agyn-apps umbrella (default k8s-runner).
# apps-provision talks to the Gateway, so it waits on the whole platform being
# up. A bare `wait` timeout says nothing about which workload never came up —
# and the build's VM is gone by the time anyone reads the log — so dump the
# cluster's own account of it before failing.
diagnose_apps_provision() {
	log "apps-provision did not complete; cluster state follows"
	kubectl -n platform get pods -o wide || true
	kubectl -n platform describe job/apps-provision || true
	kubectl -n platform logs job/apps-provision --tail=100 || true
	kubectl -n platform logs deployment/gateway --tail=100 --all-containers || true
	# Whatever is not up is usually the reason, and its own logs say why far
	# better than the event list does. Guessing from events cost several
	# 24-minute builds.
	for pod in $(kubectl -n platform get pods --no-headers |
		awk '$3 != "Running" && $3 != "Completed" { print $1 }'); do
		log "--- logs ${pod}"
		kubectl -n platform logs "${pod}" --tail=50 --all-containers || true
		kubectl -n platform logs "${pod}" --tail=50 --all-containers --previous 2>/dev/null || true
	done
	kubectl -n platform get events --sort-by=.lastTimestamp | tail -40 || true
}

log "waiting for apps-provision job"
kubectl -n platform wait --for=condition=complete job/apps-provision --timeout=20m ||
	{ diagnose_apps_provision; exit 1; }

log "agyn-apps ${AGYN_APPS_VERSION}"
helm upgrade --install agyn-apps oci://ghcr.io/agynio/charts/agyn-apps \
	--version "${AGYN_APPS_VERSION}" -n platform \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values agyn-apps)"

# 8) Verify the authorization model the image is about to ship actually exists.
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
store="$(kubectl -n platform get secret authorization-openfga -o jsonpath='{.data.OPENFGA_STORE_ID}' | base64 -d)"
model="$(kubectl -n platform get secret authorization-openfga -o jsonpath='{.data.OPENFGA_MODEL_ID}' | base64 -d)"
if kubectl -n platform exec deploy/authorization -- \
	wget -q -O /dev/null "http://openfga.openfga.svc.cluster.local:8080/stores/${store}/authorization-models/${model}"; then
	log "  model ${model} present"
else
	log "  model ${model} missing from store ${store}; re-running the migration"
	# Same job, run again. A completed Job is immutable, so it is deleted and
	# recreated from its own spec under its own name — the selector and pod
	# labels are Job-controller state, not something to carry across.
	kubectl -n platform get job authorization-migrate -o json |
		python3 -c 'import json,sys; j=json.load(sys.stdin); j["metadata"]={"name":"authorization-migrate","namespace":"platform"}; j["spec"].pop("selector",None); j["spec"]["template"]["metadata"].pop("labels",None); j.pop("status",None); print(json.dumps(j))' \
			>/tmp/authorization-migrate.json
	kubectl -n platform delete job authorization-migrate --wait
	kubectl apply -f /tmp/authorization-migrate.json
	rm -f /tmp/authorization-migrate.json
	kubectl -n platform wait --for=condition=complete job/authorization-migrate --timeout=5m
	kubectl -n platform logs job/authorization-migrate
	kubectl -n platform rollout restart deploy/authorization
	kubectl -n platform rollout status deploy/authorization --timeout=5m
fi

log "helm releases:"
helm list -A
