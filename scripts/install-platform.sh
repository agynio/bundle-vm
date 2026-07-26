#!/usr/bin/env bash
set -euo pipefail

# Installs the Agyn platform on top of a booted bundle-vm-base guest with plain
# Helm. The base image provides k3s + cert-manager + helm; the ingress layer is
# installed by install-ingress.sh. Chart versions are pinned here; values live
# in deploy/values/ with {{BASE_DOMAIN}}/{{INGRESS_HOST_PORT}} substituted at
# install time.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive

DEPLOY_DIR=/tmp/deploy
BASE_DOMAIN="${BASE_DOMAIN:-agyn.dev}"
INGRESS_HOST_PORT="${INGRESS_HOST_PORT:-2496}"
HELM_TIMEOUT=15m

TRUST_MANAGER_VERSION=v0.22.0
ZITI_CONTROLLER_VERSION=3.2.0-pre6
ZITI_ROUTER_VERSION=3.0.0-pre5
POSTGRES_HELM_VERSION=0.1.1
OPENFGA_VERSION=0.2.56
MINIO_VERSION=5.4.0
METERING_VERSION=0.1.3
AGYN_PLATFORM_VERSION=0.5.10
AGYN_APPS_VERSION=0.1.0

log() { printf '[install-platform] %s\n' "$*"; }

render() {
	sed -e "s/{{BASE_DOMAIN}}/${BASE_DOMAIN}/g" \
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

# metering: its own release (not in the umbrella chart), on the shared Postgres.
log "metering ${METERING_VERSION}"
helm upgrade --install metering oci://ghcr.io/agynio/charts/metering \
	--version "${METERING_VERSION}" -n platform \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values metering)"

# 6) The platform umbrella. No --wait: migrations and self-enrollment retry on
#    their own schedules; prepull-and-wait.sh watches overall convergence.
log "agyn-platform ${AGYN_PLATFORM_VERSION}"
helm upgrade --install agyn-platform oci://ghcr.io/agynio/charts/agyn-platform \
	--version "${AGYN_PLATFORM_VERSION}" -n platform \
	-f "$(values agyn-platform)"

# 7) Apps layer: wait for the apps-provision Job (admin tuple + k8s-runner
#    registration + service-token secret, ported from bootstrap stacks/apps),
#    then the agyn-apps umbrella (default k8s-runner).
log "waiting for apps-provision job"
kubectl -n platform wait --for=condition=complete job/apps-provision --timeout=20m

log "agyn-apps ${AGYN_APPS_VERSION}"
helm upgrade --install agyn-apps oci://ghcr.io/agynio/charts/agyn-apps \
	--version "${AGYN_APPS_VERSION}" -n platform \
	--wait --timeout "${HELM_TIMEOUT}" -f "$(values agyn-apps)"

log "helm releases:"
helm list -A
