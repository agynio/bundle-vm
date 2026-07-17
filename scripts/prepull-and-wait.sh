#!/usr/bin/env bash
set -euo pipefail

# Waits for the whole cluster to converge after install-platform.sh: every pod
# Running or Completed, every Deployment/StatefulSet fully ready, and the state
# stable across consecutive checks. When this returns, every image referenced
# by a workload is in the k3s containerd store — the "boots in seconds"
# property of the baked image.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

CONVERGE_TIMEOUT="${PLATFORM_CONVERGE_TIMEOUT:-1800}"
STABLE_CHECKS=3

log() { printf '[prepull-and-wait] %s\n' "$*"; }

pending_workloads() {
	# Pods not Running/Succeeded (column 4 of `get pods -A`).
	kubectl get pods -A --no-headers 2>/dev/null |
		awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" { print $1 "/" $2 "(" $4 ")" }'
	# Deployments with unready replicas.
	kubectl get deploy -A --no-headers 2>/dev/null |
		awk '{ split($3, ready, "/"); if (ready[1] != ready[2]) print $1 "/" $2 "(deploy " $3 ")" }'
	# StatefulSets with unready replicas.
	kubectl get statefulset -A --no-headers 2>/dev/null |
		awk '{ split($3, ready, "/"); if (ready[1] != ready[2]) print $1 "/" $2 "(sts " $3 ")" }'
}

deadline=$((SECONDS + CONVERGE_TIMEOUT))
stable=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
	pending="$(pending_workloads)"
	if [ -z "${pending}" ]; then
		stable=$((stable + 1))
		if [ "${stable}" -ge "${STABLE_CHECKS}" ]; then
			log "cluster converged"
			break
		fi
		log "converged; confirming stability (${stable}/${STABLE_CHECKS})"
	else
		stable=0
		log "waiting on: $(echo "${pending}" | tr '\n' ' ')"
	fi
	sleep 15
done

if [ "${stable}" -lt "${STABLE_CHECKS}" ]; then
	log "cluster did not converge within ${CONVERGE_TIMEOUT}s"
	kubectl get pods -A || true
	kubectl get deploy,statefulset -A || true
	exit 1
fi

log "final state:"
kubectl get pods -A || true

log "images present in containerd:"
k3s crictl images 2>/dev/null | awk 'NR==1 || /agyn|postgres|minio|openfga|nats|ziti/' || true
