vmType: qemu
arch: "{{LIMA_ARCH}}"
cpus: 4
memory: 8GiB
disk: 32GiB

images:
  - location: ./bundle-vm-platform-{{ARCH}}.qcow2
    arch: "{{LIMA_ARCH}}"

mounts: []

# Lima's built-in hostResolver proxies DNS for the guest, but it answers
# non-existent names only after ~8s (and with NOERROR rather than NXDOMAIN).
# Kubernetes generates failing lookups constantly — ndots:5 search-path
# expansion, and Go gRPC's `_grpc_config.<service>` TXT probe on every cold
# channel dial — so each one cost 8s and they stacked into 10-30s first-request
# stalls. Disabling it makes Lima hand the host's real nameservers to the guest
# over DHCP: negative answers come back in ~50ms, and split-horizon/VPN DNS
# from the host works inside the cluster.
hostResolver:
  enabled: false

ssh:
  localPort: 0
  loadDotSSHPubKeys: true

containerd:
  system: false
  user: false

# The Istio ingress gateway terminates TLS on container port 443, surfaced by the
# istio-ingressgateway NodePort ({{INGRESS_NODEPORT}}). Forward it to the host so
# *.{{BASE_DOMAIN}} (which resolves to 127.0.0.1) is reachable at the public port.
portForwards:
  - guestPort: {{INGRESS_NODEPORT}}
    hostIP: "127.0.0.1"
    hostPort: {{INGRESS_HOST_PORT}}

provision:
  - mode: system
    script: |
      #!/usr/bin/env bash
      set -euo pipefail
      systemctl enable --now k3s

probes:
  - mode: readiness
    script: |
      #!/usr/bin/env bash
      set -euo pipefail
      sudo kubectl wait --for=condition=Ready nodes --all --timeout=180s
