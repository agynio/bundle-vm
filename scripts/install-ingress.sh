#!/usr/bin/env bash
set -euo pipefail

# Installs the ingress layer on top of the bundle-vm-base guest: Istio (base +
# istiod + ingressgateway as NodePort), the istio IngressClass, and the local CA
# with the wildcard TLS certificate (issued in-cluster by the base image's
# cert-manager).
#
# This mirrors what bootstrap stacks/system does with Terraform. Long-term this
# layer belongs in bundle-vm-base ("dependencies that don't change often"); it
# lives here until the base image bakes it.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive

ISTIO_VERSION="${ISTIO_VERSION:-1.21.0}"
BASE_DOMAIN="${BASE_DOMAIN:-agyn.dev}"
INGRESS_NODEPORT="${INGRESS_NODEPORT:-32443}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.${BASE_DOMAIN}}"

log() { printf '[install-ingress] %s\n' "$*"; }

# `helm --wait` reports only "context deadline exceeded" when a release never
# becomes ready, and the build's VM is discarded before anyone can look. Dump
# what the cluster knows about the namespace before giving up.
die_with_state() {
	log "$1 did not become ready; cluster state follows"
	kubectl -n "$2" get pods -o wide || true
	kubectl -n "$2" describe pods || true
	kubectl -n "$2" get events --sort-by=.lastTimestamp | tail -40 || true
	exit 1
}

log "waiting for k3s node"
systemctl enable --now k3s
until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "helm repo"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo update istio >/dev/null

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace istio-gateway --dry-run=client -o yaml | kubectl apply -f -

log "istio IngressClass"
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF

log "istio-base ${ISTIO_VERSION}"
helm upgrade --install istio-base istio/base --version "${ISTIO_VERSION}" \
	-n istio-system --wait --timeout 15m ||
	die_with_state istio-base istio-system

log "istiod ${ISTIO_VERSION}"
# The chart reserves 500m/2Gi for pilot by default, sized for a large mesh.
# This VM runs a single node, where that reservation alone is a quarter of the
# schedulable memory while pilot actually uses well under 100Mi.
helm upgrade --install istiod istio/istiod --version "${ISTIO_VERSION}" \
	-n istio-system --wait --timeout 15m \
	--set meshConfig.ingressControllerMode=STRICT \
	--set meshConfig.ingressClass=istio \
	--set meshConfig.ingressService=istio-ingressgateway \
	--set meshConfig.ingressServiceNamespace=istio-gateway \
	--set pilot.traceSampling=1.0 \
	--set pilot.resources.requests.cpu=50m \
	--set pilot.resources.requests.memory=96Mi ||
	die_with_state istiod istio-system

log "istio ingress gateway ${ISTIO_VERSION} (NodePort ${INGRESS_NODEPORT})"
cat >/tmp/gw-values.yaml <<EOF
name: istio-ingressgateway
service:
  type: NodePort
  ports:
    - name: status-port
      port: 15021
      protocol: TCP
      targetPort: 15021
      nodePort: 31021
    - name: http2
      port: 80
      protocol: TCP
      targetPort: 80
      nodePort: 30080
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
      nodePort: ${INGRESS_NODEPORT}
EOF
helm upgrade --install istio-gateway istio/gateway --version "${ISTIO_VERSION}" \
	-n istio-gateway --wait --timeout 15m -f /tmp/gw-values.yaml ||
	die_with_state istio-ingressgateway istio-gateway
rm -f /tmp/gw-values.yaml

log "wait for cert-manager webhook"
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s

log "local CA + wildcard *.${BASE_DOMAIN} certificate"
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agyn-dev-ca
  namespace: istio-gateway
spec:
  isCA: true
  commonName: Agyn Local CA
  secretName: agyn-dev-ca
  duration: 87600h
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: agyn-dev-ca
  namespace: istio-gateway
spec:
  ca:
    secretName: agyn-dev-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-agyn-dev-tls
  namespace: istio-gateway
spec:
  secretName: wildcard-agyn-dev-tls
  duration: 8760h
  dnsNames:
    - ${BASE_DOMAIN}
    - "*.${BASE_DOMAIN}"
  issuerRef:
    name: agyn-dev-ca
    kind: Issuer
EOF
kubectl -n istio-gateway wait --for=condition=Ready certificate/wildcard-agyn-dev-tls --timeout=300s

# The image proxy is pulled from by the node's container runtime, which is
# outside every pod's network namespace and uses the host trust store. In
# production the proxy carries a publicly-trusted certificate and nothing is
# configured on the node; here it is signed by the CA above, so that CA has to
# be trusted by the host.
log "trusting the local CA on the host (for image pulls by containerd)"
install -d /usr/local/share/ca-certificates
kubectl -n istio-gateway get secret agyn-dev-ca -o jsonpath='{.data.tls\.crt}' |
	base64 -d >/usr/local/share/ca-certificates/agyn-local-ca.crt
update-ca-certificates >/dev/null

# Production serves the registry on 443, so a production reference carries no
# port. Here the ingress is a NodePort, and a reference naming that port would
# be a different image than the same content in production: containerd keys its
# store by the reference it pulled with, so a layer baked under one name is
# re-pulled under the other. The mirror keeps the port out of every reference —
# the endpoint is named rather than an address so TLS still sees the hostname
# the certificate was issued for.
log "mirroring ${REGISTRY_HOST} to the ingress NodePort"
cat >/etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  ${REGISTRY_HOST}:
    endpoint:
      - "https://${REGISTRY_HOST}:${INGRESS_NODEPORT}"
EOF
# The node resolves the registry hostname to itself: the pull leaves containerd,
# reaches the ingress on loopback and comes back to the proxy pod. Production
# resolves the same name through DNS to the real ingress.
grep -q "${REGISTRY_HOST}" /etc/hosts || printf '127.0.0.1 %s\n' "${REGISTRY_HOST}" >>/etc/hosts

# containerd reads the trust store and the registry config at startup, so it has
# to be restarted for either to apply.
systemctl restart k3s
until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done

log "done"
