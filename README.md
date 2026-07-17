# bundle-vm

Builds the **Agyn platform VM image** — a prebuilt QCOW2 that boots the full
platform in seconds, instead of running the multi-minute Terraform provisioning
each time.

It is the second layer of a two-image design:

| Image | Repo | Contains |
|-------|------|----------|
| Base | [`bundle-vm-base`](../bundle-vm-base) | Ubuntu (minimal) + k3s + cert-manager + helm/kubectl. The parts that rarely change. |
| Platform | **this repo** | Inherits the base image, installs Istio ingress + wildcard TLS, then the Agyn platform with **plain Helm** from the public `ghcr.io/agynio` charts. |

## How the bake works

`packer/bundle-vm.pkr.hcl` boots the **base image qcow2** as its input disk
(`disk_image = true`, `iso_url = file://.../bundle-vm-base-<arch>.qcow2`). The
base disk was finalized clean (`cloud-init clean --seed`), so the NoCloud seed
re-creates a temporary `packer` build user on boot exactly like the base build.

The build then:

1. copies `deploy/` into the guest,
2. `scripts/install-ingress.sh` — Istio (base + istiod + gateway as NodePort),
   the `istio` IngressClass, and the local CA + wildcard `*.agyn.dev`
   certificate (issued in-cluster by cert-manager),
3. `scripts/install-platform.sh` — applies `deploy/manifests/` with kubectl,
   then `helm upgrade --install` in dependency order: trust-manager →
   ziti-controller → (ziti-provision Job) → ziti-router → openfga-db → openfga
   → minio → the **`agyn-platform` umbrella chart** (the entire platform as one
   release),
4. `scripts/prepull-and-wait.sh` — waits until every pod/Deployment/StatefulSet
   converges, which also means every image is in the k3s containerd store,
5. `scripts/cleanup-image.sh` — sweeps job pods, prunes unused images, strips
   the containerd content-store layer blobs, stops k3s, zero-fills free space,
   and finalizes to a clean disk.

Result: `limactl start` on the platform image comes up with the platform
already running and nothing to pull. There is no GitOps controller in the
image; upgrades are image replacement (see `agyn local upgrade`).

## Ingress

Inside the VM the Istio ingress gateway always terminates TLS on **container
port 443**, surfaced by the `istio-ingressgateway` NodePort (`32443`). The
external port is purely a Lima port-forward onto that NodePort — set by
`INGRESS_HOST_PORT` (default `2496`). `*.agyn.dev` resolves to `127.0.0.1`
publicly, so services are reached at e.g. `https://console.agyn.dev:2496`.

Note: the OpenZiti controller advertises `ziti.<domain>:<INGRESS_HOST_PORT>` in
enrollment JWTs, so external Ziti clients must reach the VM on exactly that
host port. In-cluster clients use the CoreDNS rewrites instead.

## Deploy layout

The platform is deployed as the **single unified `agyn-platform` umbrella
chart** ([`platform-charts`](../platform-charts)), not one release per
microservice.

- `deploy/manifests/` — namespaces, dev secrets (`agyn-platform-database-urls`,
  `agyn-files-s3`, …), a shared Postgres, CoreDNS rewrites, the ziti-provision
  Job, and Istio `VirtualService` routing. Applied first with kubectl.
  `{{BASE_DOMAIN}}` / `{{INGRESS_HOST_PORT}}` are substituted at install time.
- `deploy/values/` — one Helm values file per release. `agyn-platform.yaml` is
  a local port of the canonical contract file
  `infrastructure/terraform/components/platform/values/agyn-platform.yaml.tftpl`
  (in-cluster MinIO/OpenFGA, mockauth.dev dev OIDC).
- Chart versions are pinned in `scripts/install-platform.sh`.

Disabled services (bootstrap parity / no provisioning path yet):
`egress-gateway`, `groups`, `networks`, `expose`, `ncps`, `registryMirror`.

## Build

Prerequisites are the same as `bundle-vm-base` (Packer, QEMU, on Apple Silicon
HVF). Build the base image first, then:

```sh
scripts/build.sh arm64          # boots base qcow2, installs platform, snapshots
scripts/package.sh arm64 dev    # compress + metadata + generated lima.yaml
```

Override the base image with `BASE_IMAGE=/abs/path/to/base.qcow2`.

## Publish

```sh
scripts/publish.sh arm64 <version> ghcr.io/agynio/bundle-vm latest   # OCI artifact
# plus the CDN copy (R2): s5cmd cp artifacts/arm64/* s3://downloads/bundle-vm/<version>/arm64/
```

## Run

End users: `agyn local start` (see agyn-cli). Manually:

```sh
limactl start --name agyn artifacts/arm64/lima.yaml
open https://console.agyn.dev:2496
```

The TLS certificate chains to the in-image "Agyn Local CA"
(`agyn local ca install`, or extract it from the `istio-gateway/agyn-dev-ca`
secret).
