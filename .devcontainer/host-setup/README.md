# host-setup

Scripts that run **on the host**, not in the devcontainer. The host owns the
Azure identity; the container deliberately ships with no `az`, `kubelogin`, or
Entra credential. These scripts bridge that gap by producing self-contained
artifacts the container ingests via environment variables.

## `gen-viewer-kubeconfig.sh` — mint the read-only AKS kubeconfig

Produces the `$KUBECONFIG_B64` value the devcontainer decodes at start
(`.devcontainer/post-start.d/30-kubeconfig.sh`) so an in-container `kubectl` can
**observe** a pgcyan migration — pods, logs, jobs, configmaps, events — with no
Azure identity present.

### What it makes

A **self-contained, token-based** kubeconfig for the namespaced, read-only
`pgcyan-viewer` ServiceAccount defined in
`projects/pgcyan/deploy/k8s/01-rbac.yaml`:

- cluster `server` + `certificate-authority-data`,
- a **bare bearer `token`** (no `exec:` plugin — nothing to invoke, no Azure
  reach),
- context namespace `pgcyan-migration`.

The token is a **legacy, non-expiring** ServiceAccount token, read from a Secret
of type `kubernetes.io/service-account-token` named `pgcyan-viewer-token`. Modern
AKS doesn't auto-create these, so the script creates it and waits for the token
controller to populate it. Non-expiring is intentional: the container just
base64-decodes a static value on every start and it keeps working across rebuilds
until the SA/Secret is deleted.

### Prerequisites (on the host)

- `az login` as an identity with admin access to the cluster,
- `kubectl` + `base64` on `PATH`,
- either a working `kubectl` context for the cluster, **or**
  `AKS_RESOURCE_GROUP` + `AKS_CLUSTER_NAME` set so the script runs
  `az aks get-credentials`.

### Usage

```bash
# Uses your current kubectl context:
./gen-viewer-kubeconfig.sh

# Or fetch credentials first:
AKS_RESOURCE_GROUP=<rg> AKS_CLUSTER_NAME=<cluster> ./gen-viewer-kubeconfig.sh
```

It writes `viewer.kubeconfig` (git-ignored — it holds a live token), prints the
`export KUBECONFIG_B64=...` line for your shell profile, and echoes the bare
base64 value to stdout. Add the export to `~/.bashrc` / `~/.zshrc`, then reopen
the devcontainer — `devcontainer.json` forwards it as
`${localEnv:KUBECONFIG_B64}`.

### Tunables (env)

| Var | Default | Purpose |
|-----|---------|---------|
| `NAMESPACE` | `pgcyan-migration` | ServiceAccount's namespace |
| `SERVICE_ACCOUNT` | `pgcyan-viewer` | the read-only SA to mint for |
| `TOKEN_SECRET` | `<SA>-token` | the long-lived token Secret |
| `APPLY_RBAC` | `1` | apply `01-rbac.yaml` first (`0` to skip) |
| `AKS_RESOURCE_GROUP` / `AKS_CLUSTER_NAME` | — | run `az aks get-credentials` if both set |
| `AKS_ADMIN` | `0` | pass `--admin` to `get-credentials` |
| `OUT_FILE` | `./viewer.kubeconfig` | where to write the kubeconfig |

### Widening what the container can see

The token carries **only** whatever RBAC is bound to the `pgcyan-viewer` SA.
Today that's a namespaced read-only Role in `pgcyan-migration`. To let the
container also observe the control-plane's dynamic `pgcyan-mig-*` namespaces,
bind **more** to the *same* SA — a cluster-scoped read-only `ClusterRoleBinding`,
or a per-namespace `RoleBinding` stamped into each migration namespace. Because
the token is tied to the SA's identity, **no regeneration is needed** — new
bindings take effect immediately. Re-run this script only if the SA or its token
Secret is deleted/rotated.

## Security notes

- `viewer.kubeconfig` and any exported `KUBECONFIG_B64` embed a **live,
  non-expiring credential**. Keep them out of git (the repo `.gitignore` ignores
  the generated kubeconfig) and out of shared logs.
- The identity is read-only by construction and, per `01-rbac.yaml`, is denied
  `secrets`, `pods/exec`, and `pods/portforward`. Revoke by deleting the
  `pgcyan-viewer-token` Secret (and/or the SA) on the cluster.
