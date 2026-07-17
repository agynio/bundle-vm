#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Finalize the platform image. The base image already hardened sshd; here we
# only re-create the finalize-shutdown hook (the base removed its own during its
# finalize) so Packer's shutdown_command cleans the NoCloud seed and removes the
# temporary packer build user, leaving a clean, reusable platform disk.

rm -rf /tmp/deploy /tmp/* /var/tmp/* 2>/dev/null || true

# Sweep failed pods left behind by migration Jobs that retried while their
# dependencies were still starting (the Jobs themselves completed).
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl delete pods -A --field-selector status.phase=Failed 2>/dev/null || true

# Drop completed one-shot Job pods (stream config, ziti provisioning,
# migrations) so their images become unreferenced, then prune every image no
# container uses anymore (nats-box, ...).
kubectl delete pods -A --field-selector status.phase=Succeeded 2>/dev/null || true
k3s crictl rmi --prune 2>/dev/null || true

# Drop compressed layer blobs from the containerd content store. Pods run from
# the unpacked overlayfs snapshots; the JSON manifests/configs (kept) are all
# kubelet needs for image-presence checks. The blobs are already-compressed
# data that xz cannot shrink, so they would otherwise pass ~1:1 into the
# published artifact. Same effect as containerd's discard_unpacked_layers.
#
# Removal must go through `ctr content rm` so containerd's metadata records go
# with the files: a record without its file makes containerd skip downloading
# that blob on future pulls of images sharing a layer, then fail at extract
# ("blob not found in content store").
blobs_dir=/var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content/blobs/sha256
if [ -d "${blobs_dir}" ]; then
	for digest in $(k3s ctr -n k8s.io content ls -q); do
		blob="${blobs_dir}/${digest#sha256:}"
		[ -f "${blob}" ] || continue
		case "$(head -c1 "${blob}")" in
		"{") ;;
		*) k3s ctr -n k8s.io content rm "${digest}" || true ;;
		esac
	done
fi

# Stop k3s and all containers BEFORE zero-filling. Filling the disk to 100%
# while kubelet is live trips its DiskPressure eviction (<10% free) and bakes
# an eviction storm into the snapshot. k3s is enabled, so it starts fresh on
# first boot exactly as it would after any reboot.
systemctl stop k3s 2>/dev/null || true
/usr/local/bin/k3s-killall.sh 2>/dev/null || true

# Truncate logs and caches accumulated during the bake.
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true

# Zero remaining free space so deleted blocks (apt caches, retried image pulls,
# temp files) compress to nothing in the published xz instead of shipping as
# random garbage. dd is expected to fail when the disk fills; that is the point.
dd if=/dev/zero of=/zero.fill bs=8M 2>/dev/null || true
sync
rm -f /zero.fill
sync

cat >/usr/local/sbin/agyn-finalize-shutdown <<'SHUTDOWN_EOF'
#!/usr/bin/env bash
set -euo pipefail

cloud-init clean --logs --seed
if getent passwd packer >/dev/null; then
	sed -i "/^packer:/d" /etc/passwd /etc/shadow /etc/group /etc/gshadow
	rm -rf /home/packer
fi
rm -f /usr/local/sbin/agyn-finalize-shutdown
shutdown -P now
SHUTDOWN_EOF
chmod 0700 /usr/local/sbin/agyn-finalize-shutdown
