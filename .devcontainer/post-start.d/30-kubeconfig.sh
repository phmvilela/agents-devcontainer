#!/bin/bash
#
# post-start step: ingest the read-only AKS kubeconfig from the host.
#
# The host owns the Azure identity: `az login` + host-setup/gen-viewer-kubeconfig.sh
# mint a self-contained, read-only, token-based kubeconfig and export it as
# $KUBECONFIG_B64 (base64). This step decodes it to ~/.kube/config so the
# `kubectl` in the image (installed by the Dockerfile) can observe the pgcyan
# migration -- pods, logs, jobs, configmaps -- with NO az / kubelogin / Azure
# identity present in the container. See host-setup/README.md.
#
# The firewall (10-firewall.sh, which runs earlier) has already allow-listed the
# API-server FQDN out of the same $KUBECONFIG_B64.
#
# Best-effort: a missing or malformed value logs and skips rather than failing
# the whole container start (mirrors 20-gpg-signing.sh).

# -u: undefined vars are errors; -o pipefail: catch failures in pipelines.
# NOTE: no -e on purpose -- individual steps degrade gracefully below.
set -uo pipefail

if [ -z "${KUBECONFIG_B64:-}" ]; then
    echo "KUBECONFIG_B64 not set in host environment; skipping kubeconfig setup."
    echo "  (Run host-setup/gen-viewer-kubeconfig.sh on the host to enable AKS access.)"
    exit 0
fi

KUBE_DIR="$HOME/.kube"
KUBE_CONFIG="$KUBE_DIR/config"

mkdir -p "$KUBE_DIR" && chmod 700 "$KUBE_DIR"

if ! echo "$KUBECONFIG_B64" | base64 -d > "$KUBE_CONFIG" 2>/dev/null; then
    echo "Could not base64-decode KUBECONFIG_B64; skipping kubeconfig setup."
    rm -f "$KUBE_CONFIG"
    exit 0
fi
chmod 600 "$KUBE_CONFIG"

# Cheap structural sanity check before announcing success.
if ! grep -q 'apiVersion: v1' "$KUBE_CONFIG" 2>/dev/null; then
    echo "Decoded KUBECONFIG_B64 does not look like a kubeconfig; leaving it in place but skipping verification."
    exit 0
fi

echo "Wrote read-only kubeconfig to $KUBE_CONFIG."

# Verify connectivity/authz, but never fail the container on it -- the cluster
# may simply be unreachable right now (VPN, cluster stopped, token rotated).
if command -v kubectl >/dev/null 2>&1; then
    ns="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
    ns="${ns:-default}"
    if kubectl get pods -n "$ns" >/dev/null 2>&1; then
        echo "kubectl OK: can list pods in namespace '$ns'."
    else
        echo "kubectl configured but could not list pods in '$ns' yet."
        echo "  (cluster unreachable, stopped, or token rotated -- re-run host-setup/gen-viewer-kubeconfig.sh if needed.)"
    fi
else
    echo "WARN: kubectl not found on PATH; kubeconfig written but unusable."
fi
