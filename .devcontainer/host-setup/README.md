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

## `setup-portproxy.ps1` / `refresh-wsl-portproxy.ps1` — WSL2 loopback-forwarding workaround

**Only needed if `curl http://host.docker.internal:<port>` (or `localhost`
from a native Windows process) hangs after completing its TCP handshake but
never receives data**, while the same request from *inside* WSL2 works fine.
That's the signature of a WSL2 bug where Windows<->WSL2 **IPv4** loopback
forwarding gets stuck (IPv6 loopback keeps working). It breaks Docker
Desktop's `host.docker.internal` gateway too, since Docker Desktop's proxy
also relays through Windows' IPv4 loopback. Restarting the `hns` service,
cycling the `vEthernet (WSL)` adapter, `wsl --update`, and even a full reboot
did not clear it on the machine this was first diagnosed on.

### What it does

Routes around the broken loopback hop instead of trying to fix it:

```
container --> host-lan-workaround:<port>  (Windows' real LAN IP, allow-listed
              by .devcontainer/host-lan-access-init.sh, see there for the
              container-side half)
          --> netsh interface portproxy   (Windows' real LAN IP -> WSL2 VM's
                                            real IP, both non-loopback, both
                                            still work when the loopback layer
                                            doesn't)
          --> the WSL2 VM's real IP, e.g. `kubectl port-forward --address 0.0.0.0`
```

- `refresh-wsl-portproxy.ps1` re-detects the WSL2 VM's current IP (it changes
  on every `wsl --shutdown` / restart) and rewrites the `netsh portproxy`
  mapping. Safe to re-run anytime.
- `setup-portproxy.ps1` is the one-time bootstrap: opens the firewall for the
  listen port(s) and registers a Scheduled Task that runs
  `refresh-wsl-portproxy.ps1` at every Windows logon, so the mapping
  self-heals without you thinking about it.

### Usage — from your WSL2 terminal (recommended)

`bootstrap-portproxy.sh` and `refresh-portproxy.sh` are thin WSL-side wrappers
around the two `.ps1` scripts, using `powershell.exe` interop so you never
have to manually open an elevated PowerShell window:

```bash
cd .devcontainer/host-setup
./bootstrap-portproxy.sh       # one-time; accept the single UAC prompt it triggers
```

If you `wsl --shutdown` mid-session (the WSL2 VM's IP changes), refresh
without logging out of Windows — this one needs no UAC prompt, since it just
tells the already-elevated scheduled task (registered by the bootstrap step)
to run now:

```bash
./refresh-portproxy.sh
```

### Usage — directly, in an elevated/Administrator PowerShell

Equivalent to the above, if you'd rather run the `.ps1` files yourself:

```powershell
cd .devcontainer\host-setup
.\setup-portproxy.ps1          # one-time; re-running is safe
```

```powershell
.\refresh-wsl-portproxy.ps1
# or, from a non-elevated prompt, once the scheduled task exists:
Start-ScheduledTask -TaskName pgcyan-wsl-portproxy-refresh
```

### Usage (on WSL2 / in the devcontainer)

Add this to your WSL shell profile (`~/.bashrc` / `~/.zshrc`) — it re-detects
your host's real LAN IPv4 address fresh every time a shell starts (via
`powershell.exe` interop), so it self-heals across Wi-Fi networks instead of
going stale like a hardcoded IP would:

```bash
export HOST_LAN_IP="$(powershell.exe -NoProfile -Command '(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Status -eq "Up" -and (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).InterfaceDescription -notmatch "WSL|Docker|Hyper-V|Loopback" } | Select-Object -First 1).IPAddress' 2>/dev/null | tr -d '\r\n')"
```

This is the same adapter-filtering heuristic as `Get-HostLanIP` in
`refresh-wsl-portproxy.ps1` (real, up, non-virtual, non-loopback adapter) —
intentionally duplicated here rather than shelled out to that file, since a
portable one-liner can't assume where in your WSL filesystem this repo is
checked out. **If you change the filtering logic in one place, update the
other.**

Each new WSL shell pays one `powershell.exe` startup (roughly half a second)
for this. If that's annoying, cache it instead — e.g. compute once into
`~/.cache/host_lan_ip` guarded by a mtime check, or just fall back to a static
`export HOST_LAN_IP=192.168.1.23` and accept re-editing it when it goes stale.

Reopen the devcontainer — it forwards this as `${localEnv:HOST_LAN_IP}`
(`devcontainer.json`), and `post-start.d/40-host-lan-access.sh` allow-lists it
and aliases it to the hostname `host-lan-workaround`. From inside the
container:

```
curl http://host-lan-workaround:8081/...
```

reaches whatever `refresh-wsl-portproxy.ps1`'s port map (default `8081 ->
8080`) points at inside WSL2. Add more `-ListenPorts` / `$PortMap` entries in
both scripts if you need to reach additional ports this way.

**If a future WSL2/Docker Desktop update fixes the underlying loopback bug**,
this whole workaround (all four scripts here --
`{setup,refresh-wsl}-portproxy.ps1` and `{bootstrap,refresh}-portproxy.sh` --
plus `host-lan-access-init.sh`, `post-start.d/40-host-lan-access.sh`, and the
`HOST_LAN_IP` env var) can just be deleted — nothing else in the devcontainer
depends on it.

## Security notes

- `viewer.kubeconfig` and any exported `KUBECONFIG_B64` embed a **live,
  non-expiring credential**. Keep them out of git (the repo `.gitignore` ignores
  the generated kubeconfig) and out of shared logs.
- The identity is read-only by construction and, per `01-rbac.yaml`, is denied
  `secrets`, `pods/exec`, and `pods/portforward`. Revoke by deleting the
  `pgcyan-viewer-token` Secret (and/or the SA) on the cluster.
