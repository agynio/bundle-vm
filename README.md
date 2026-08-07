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

The OIDC issuer is the exception to "in-cluster clients ignore the host port".
It is one URL — `https://auth.agyn.dev:<INGRESS_HOST_PORT>/realms/agyn` — used
both by the browser and, server-side, by the Gateway and Media Proxy, which
fetch discovery, JWKS and userinfo from it; zitadel/oidc rejects a discovery
document whose issuer differs from the URL it was fetched from, so the two
sides cannot name different ports. `install-ingress.sh` therefore gives the
`istio-ingressgateway` Service a second port equal to `INGRESS_HOST_PORT`,
targeting the same container port 443, and `set-ingress-port.sh` moves it when
the host picks another port.

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
  (in-cluster MinIO/OpenFGA, the umbrella's bundled Keycloak for OIDC).
- Chart versions are pinned in `scripts/install-platform.sh`.

Every platform service the Gateway routes to is deployed. The only services left
off are the ones the umbrella chart also defaults to off — `ncps` and
`registryMirror` — neither of which the Gateway dials.

## Build

Prerequisites are the same as `bundle-vm-base` (Packer, QEMU, on Apple Silicon
HVF). Build the base image first, then:

```sh
scripts/build.sh arm64          # boots base qcow2, installs platform, snapshots
scripts/package.sh arm64 dev    # compress + metadata + generated lima.yaml
```

Override the base image with `BASE_IMAGE=/abs/path/to/base.qcow2`.

## Release

One command builds, packages and publishes an architecture — to GHCR (where the
next build finds its inputs) and to the CDN (where `agyn local start` finds the
image). Both have to happen for a release to exist, so `release.sh` does both
rather than leaving the second to whoever remembers it:

```bash
scripts/release.sh arm64 0.2.0 --latest
```

Every precondition — tools, credentials, hardware acceleration, free disk — is
checked before the bake starts, so a missing one fails in the first second
rather than forty minutes in.

| | Built where | How |
|---|---|---|
| **amd64** | GitHub Actions | Push a `v*` tag, or run the Release workflow |
| **arm64** | A maintainer's machine | `scripts/release.sh arm64 <version>` |

arm64 is not built in CI because GitHub offers no arm64 runner with nested
virtualization, and without KVM the bake takes hours instead of minutes. When
such a runner exists, arm64 becomes a second job in the same workflow calling
this same script — which is precisely why the local path is a script and not a
list of commands in this file.

**A release is not complete until both architectures are published.** The amd64
workflow says so in its job summary; nothing enforces it.

Publishing needs R2 credentials in the environment (`R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT_URL`) and `oras login ghcr.io`. Pass
`--no-publish` to build and package without either.

`--latest` repoints `bundle-vm/latest.json`, which is what `version: latest`
resolves through. It is written after the uploads succeed, so `latest` never
names a half-uploaded directory.

### Base image

The platform image is built on top of a *published* `bundle-vm-base` version,
pinned by `BASE_IMAGE_VERSION` in `versions.env` and pulled by
`scripts/fetch-base.sh` (cached under `.cache/base/`). A build therefore depends
on a named artifact rather than on whatever qcow2 sits in a sibling checkout. To
move to a new base, release it from `agynio/bundle-vm-base` and bump the pin.

## Run

End users: `agyn local start` (see agyn-cli). Manually:

```sh
limactl start --name agyn artifacts/arm64/lima.yaml
open https://console.agyn.dev:2496
```

The TLS certificate chains to the in-image "Agyn Local CA"
(`agyn local ca install`, or extract it from the `istio-gateway/agyn-dev-ca`
secret).

Sign in with **`admin` / `admin`**. Authentication is the Keycloak the umbrella
bundles, served at `https://auth.agyn.dev:2496`, with a realm imported from the
chart: one client per app (`agyn-console`, `agyn-chat`, `agyn-tracing`,
`agyn-sandboxes`) and a single user, `admin@agyn.dev`. That address is also
`users.FIRST_ADMIN_EMAIL`, so the first sign-in takes cluster admin.

The realm is imported only when it does not already exist — Keycloak's
`--import-realm` is create-once and the strategy cannot be overridden — so
editing it in the chart reaches an existing VM only after the `keycloak`
database is dropped, or through the Admin API.

The Gateway's `CLUSTER_ADMIN_TOKEN` identity is unrelated and unchanged: it is
what the CLI and the e2e suites authenticate as, and nothing ever signs into
it.
