# Egress proxy

A second container next to the dev container. HTTPS leaves the dev container
through it, and it decides by **hostname**, from the same `~/allowed_domains`
file on the host that the firewall has always read.

Why: the firewall resolved each allowed name to addresses once, when the
container started. A service behind many rotating addresses
(`management.azure.com`, Microsoft's sign-in endpoints) then stopped answering
within the hour, and the only fix was more address ranges. A hostname does not
rotate.

## How it fits together

| Piece | What it does |
|---|---|
| `docker-compose.yml` | Runs both containers on one network and points the dev container's `HTTPS_PROXY` at `egress-proxy:3128` |
| `egress-proxy/` | The Squid image: `entrypoint.sh` writes the configuration, `gen-allowlist.sh` turns the allowlist into Squid's format |
| `firewall-init.sh` | Still drops everything else. When it finds the proxy it no longer resolves hostnames; it only opens address ranges and `direct:` hosts |

The proxy tunnels HTTPS, it does not decrypt it: no certificate is installed
anywhere. It lets through a `CONNECT` to a listed hostname on port 443, checks
that the hostname in the TLS handshake is listed too, and refuses everything
else: plain HTTP, other ports, bare addresses.

## `~/allowed_domains`

```
management.azure.com          # that host, and only that host
.vault.azure.net              # the domain and every host under it (also *.vault.azure.net)
20.190.128.0/18               # an address range: opened in the firewall, for what does not use the proxy
direct:db.example.com         # a host reached without the proxy (Postgres, SSH): resolved by the firewall
```

- `baseline_domains` in this directory is always added: GitHub and Claude Code's own hosts.
- Avoid wildcards for services that host other people's content
  (`.blob.core.windows.net`, `.githubusercontent.com`): name the account.
- After an edit, on the host:
  `docker exec "$(docker ps -qf name=egress-proxy)" entrypoint.sh reload`.
  No dev container restart. It prints how many hostnames are allowed, which is
  how you know it read the file.
- `docker restart "$(docker ps -qf name=egress-proxy)"` does the same more
  bluntly, and is what to use if the reload cannot signal Squid, or if your
  editor replaces `~/allowed_domains` instead of writing into it (the
  container then still holds the old file).

## Seeing what was refused

```
docker logs --tail 50 <egress-proxy container>
```

One line per request. `TCP_DENIED/403` is a hostname that is not on the list;
`NONE_NONE/000` after a `CONNECT` is one stopped at the TLS handshake. Expect
a few on the first day: with address rules, any name that shared an address
with a listed one got through unnoticed, and now it has to be listed.

## Before switching to it

On the host, with the dev container closed or open, it does not matter:

```
bash .devcontainer/egress-proxy/smoke-test.sh
```

It builds the proxy by itself and checks what it allows and refuses. A refusal
is recognised by the answer being Squid's own, not by curl's exit code: curl
reports a 403 error page as a success, so an earlier version of this script
called two refusals "allowed". Rebuild the dev container only when it passes: a proxy that does not work leaves the
dev container with no way out, Claude Code included.

To go back: `git checkout` the previous `devcontainer.json` and rebuild. The
firewall script works without the proxy as it did before.

If the proxy starts but tunnels fail, set `EGRESS_PROXY_SNI_CHECK=0` in the
host shell before rebuilding: the handshake check is the part with the most
moving pieces, and without it the proxy is a plain `CONNECT` allowlist.

## What it does not do

- **Anything that is not HTTPS** does not use it: Postgres, git over SSH.
  Those need a `direct:` line or an address range, as before.
- **Tools that ignore `HTTPS_PROXY`** are simply blocked. curl, git, gh, pip,
  npm, az, terraform, kubectl and Claude Code honour it.
- **A listed service that hosts other people's content** is still a way out:
  the proxy sees the hostname, not what is sent to it.
- **DNS** is still answered for any name.
- **Run through the dev container**, not `docker compose up` by hand: the
  workspace is mounted under the name of the host directory, which
  `devcontainer.json` writes to `.devcontainer/.env` first.
- **A new machine** needs `docker volume create pgcyan-claude-home` once: the
  compose file refers to that volume and does not create it.
