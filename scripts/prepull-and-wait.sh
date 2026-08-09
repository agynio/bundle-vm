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

# The pod list alone names what did not come up but never why, so a build that
# fails here is diagnosed by rebuilding with a change that prints more.
dump_unready_pods() {
	kubectl get pods -A --no-headers 2>/dev/null |
		awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" { print $1 " " $2 }' |
		while read -r namespace pod; do
			log "--- describe ${namespace}/${pod}"
			kubectl describe pod -n "${namespace}" "${pod}" 2>&1 | tail -40 || true
			log "--- logs ${namespace}/${pod}"
			kubectl logs -n "${namespace}" "${pod}" --all-containers --tail=80 2>&1 || true
			log "--- previous logs ${namespace}/${pod}"
			kubectl logs -n "${namespace}" "${pod}" --all-containers --previous --tail=80 2>&1 || true
		done
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
	dump_unready_pods
	exit 1
fi

# Agent workloads are created on demand, so nothing references their images
# while the image is built and the convergence wait above never pulls them. The
# first agent run on a fresh VM would fetch them over the network — slow, and
# impossible offline. Pull them here so they ship in the store like every other
# image. Keep in sync with ZITI_SIDECAR_IMAGE in deploy/values/agyn-platform.yaml.
WORKLOAD_IMAGES="${WORKLOAD_IMAGES:-openziti/ziti-tunnel:2.0.0-pre8}"
for image in ${WORKLOAD_IMAGES}; do
	log "pre-pulling workload image ${image}"
	k3s ctr -n k8s.io images pull "docker.io/${image}" >/dev/null || {
		log "failed to pre-pull ${image}"
		exit 1
	}
done

# Catalog images are pulled through the image proxy under a rewritten
# reference, and containerd keys its store by the reference it pulled with: the
# upstream copy fetched above does not satisfy a pull of the rewritten name. Tag
# the content under that name so a first agent run finds it locally.
#
# Tagging rather than pulling through the proxy on purpose — it needs no
# credential, no running proxy and no network, and the content is identical.
# Images a user registers later are not baked and go through the proxy for real,
# which is what exercises that path.
REGISTRY_HOST="${REGISTRY_HOST:-registry.agyn.dev}"
PLATFORM_NAMESPACE="${AGYN_PLATFORM_NAMESPACE:-agyn-platform}"
POSTGRES_POD="$(kubectl get pods -n "${PLATFORM_NAMESPACE}" -l app=platform-postgres -o name 2>/dev/null | head -1)"

query() {
	kubectl exec -n "${PLATFORM_NAMESPACE}" "${POSTGRES_POD}" -- \
		sh -c "psql -U \"\$POSTGRES_USER\" -d $1 -t -A -F'|' -c \"$2\"" 2>/dev/null | tr -d '\r'
}

if [ -z "${POSTGRES_POD}" ]; then
	log "no platform postgres pod; skipping catalog pre-pull"
else
	# Only the tags something actually names. A repository publishes every
	# commit; baking all of them would cost gigabytes nothing would ever read.
	query agents "
		select workspace_image_id, workspace_image_tag from environments where workspace_image_id is not null
		union select agent_runtime_image_id, agent_runtime_image_tag from environments where agent_runtime_image_id is not null
		union select image_id, image_tag from mcps where image_id is not null
	" >/tmp/prepull-refs

	query images "select id, organization_id, name, repository from images" >/tmp/prepull-images
	query organizations "select id, slug from organizations" >/tmp/prepull-orgs

	awk -F'|' '
		FILENAME == ARGV[1] { slug[$1] = $2; next }
		FILENAME == ARGV[2] { org[$1] = $2; name[$1] = $3; repo[$1] = $4; next }
		$1 != "" && $2 != "" && repo[$1] != "" && slug[org[$1]] != "" {
			print repo[$1] ":" $2 "\t" slug[org[$1]] "/" name[$1] ":" $2
		}
	' /tmp/prepull-orgs /tmp/prepull-images /tmp/prepull-refs | sort -u >/tmp/prepull-plan
	rm -f /tmp/prepull-refs /tmp/prepull-images /tmp/prepull-orgs

	while IFS="$(printf '\t')" read -r upstream path; do
		[ -n "${upstream}" ] || continue
		rewritten="${REGISTRY_HOST}/${path}"
		# A moving tag makes kubelet pull on every start regardless of what is in
		# the store, so baking it would be wasted work.
		case "${upstream}" in
		*:latest)
			log "skipping ${rewritten}: a moving tag is re-pulled on every start"
			continue
			;;
		esac
		log "baking ${rewritten}"
		if ! k3s ctr -n k8s.io images pull "${upstream}" >/dev/null 2>&1; then
			# A private repository has no credential here; it is pulled through
			# the proxy on first use instead.
			log "  upstream pull failed, leaving ${upstream} to the proxy"
			continue
		fi
		k3s ctr -n k8s.io images tag --force "${upstream}" "${rewritten}" >/dev/null || {
			log "  failed to tag ${rewritten}"
			exit 1
		}
	done </tmp/prepull-plan
	rm -f /tmp/prepull-plan
fi

log "final state:"
kubectl get pods -A || true

log "images present in containerd:"
k3s crictl images 2>/dev/null | awk 'NR==1 || /agyn|postgres|minio|openfga|nats|ziti/' || true
