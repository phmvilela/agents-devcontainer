#!/bin/bash
#
# gen-viewer-kubeconfig.sh -- mint the read-only AKS kubeconfig the devcontainer
# ingests as $KUBECONFIG_B64.
#
# RUNS ON THE HOST, not in the container. The host owns the Azure identity; the
# container deliberately has no az / kubelogin / Entra credential. This script is
# the bridge: using your admin cluster access it produces a SELF-CONTAINED,
# token-based kubeconfig for the namespaced, read-only `pgcyan-viewer`
# ServiceAccount (deploy/k8s/01-rbac.yaml) -- server URL + CA + a bare bearer
# token, NO exec plugin -- so the container can `kubectl` with zero Azure reach.
#
# The token is a LEGACY, non-expiring ServiceAccount token, pulled from a Secret
# of type kubernetes.io/service-account-token (named `<sa>-token`). Modern AKS no
# longer auto-creates these, so we create it explicitly and wait for the token
# controller to populate it. Non-expiring is intentional here: the container just
# base64-decodes a static value at every start (post-start.d/30-kubeconfig.sh) and
# it keeps working across rebuilds until the SA/Secret is deleted. The token
# carries only whatever RBAC is bound to the `pgcyan-viewer` SA -- widen access by
# binding MORE to that same SA (a ClusterRoleBinding, or per-namespace
# RoleBindings); you do NOT need to re-run this script to pick that up.
#
# Flow (mirrors deploy/k8s + post-start.d/30-kubeconfig.sh):
#   1. Reach the cluster with your admin identity (az aks get-credentials, or an
#      existing working context).
#   2. Ensure the pgcyan-viewer SA + read-only RBAC exist (apply 01-rbac.yaml).
#   3. Ensure a long-lived token Secret exists and is populated.
#   4. Assemble server + CA + token into a self-contained kubeconfig.
#   5. Emit it base64-encoded and print the `export KUBECONFIG_B64=...` line the
#      devcontainer forwards (devcontainer.json -> ${localEnv:KUBECONFIG_B64}).
#
# Usage:
#   ./gen-viewer-kubeconfig.sh                      # uses current kubectl context
#   AKS_RESOURCE_GROUP=rg AKS_CLUSTER_NAME=cl \
#       ./gen-viewer-kubeconfig.sh                  # az aks get-credentials first
#
# Env (all optional; sane defaults):
#   NAMESPACE            default: pgcyan-migration   (SA's namespace)
#   SERVICE_ACCOUNT      default: pgcyan-viewer
#   TOKEN_SECRET         default: <SERVICE_ACCOUNT>-token
#   APPLY_RBAC           default: 1   (0 = assume RBAC already applied)
#   AKS_RESOURCE_GROUP / AKS_CLUSTER_NAME  -> if both set, run az aks
#                        get-credentials (add AKS_ADMIN=1 for --admin).
#   OUT_FILE             default: <script dir>/viewer.kubeconfig
#
# See also: .devcontainer/host-setup/README.md,
#           .devcontainer/post-start.d/30-kubeconfig.sh (the container side).

set -euo pipefail
IFS=$'\n\t'

# --- config / defaults -------------------------------------------------------
NAMESPACE="${NAMESPACE:-pgcyan-migration}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-pgcyan-viewer}"
TOKEN_SECRET="${TOKEN_SECRET:-${SERVICE_ACCOUNT}-token}"
APPLY_RBAC="${APPLY_RBAC:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# host-setup lives at .devcontainer/host-setup, so the repo root is two up.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RBAC_MANIFEST="$REPO_ROOT/projects/pgcyan/deploy/k8s/01-rbac.yaml"
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/viewer.kubeconfig}"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. prerequisites --------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH."
command -v base64  >/dev/null 2>&1 || die "base64 not found on PATH."

# --- 1. cluster access (admin identity, on the host) -------------------------
if [ -n "${AKS_RESOURCE_GROUP:-}" ] && [ -n "${AKS_CLUSTER_NAME:-}" ]; then
    command -v az >/dev/null 2>&1 || die "AKS_* set but az not found on PATH."
    log "Fetching cluster credentials for $AKS_CLUSTER_NAME (rg: $AKS_RESOURCE_GROUP)..."
    admin_flag=(); [ "${AKS_ADMIN:-0}" = "1" ] && admin_flag=(--admin)
    az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing "${admin_flag[@]}" >&2
fi

kubectl cluster-info >/dev/null 2>&1 \
    || die "cannot reach the cluster. Set AKS_RESOURCE_GROUP/AKS_CLUSTER_NAME or select a working kubectl context first."

# --- 2. ensure the read-only identity + RBAC exist ---------------------------
if [ "$APPLY_RBAC" = "1" ]; then
    [ -f "$RBAC_MANIFEST" ] || die "RBAC manifest not found at $RBAC_MANIFEST (set APPLY_RBAC=0 to skip)."
    log "Applying read-only RBAC from $RBAC_MANIFEST ..."
    kubectl apply -f "$RBAC_MANIFEST" >&2
fi

kubectl -n "$NAMESPACE" get serviceaccount "$SERVICE_ACCOUNT" >/dev/null 2>&1 \
    || die "ServiceAccount $NAMESPACE/$SERVICE_ACCOUNT does not exist (apply deploy/k8s/01-rbac.yaml, or set APPLY_RBAC=1)."

# --- 3. ensure a long-lived token Secret exists and is populated -------------
# Idempotent: create the annotated service-account-token Secret if missing, then
# wait for the token controller to fill in .data.token (populated asynchronously).
if ! kubectl -n "$NAMESPACE" get secret "$TOKEN_SECRET" >/dev/null 2>&1; then
    log "Creating long-lived token Secret $NAMESPACE/$TOKEN_SECRET ..."
    kubectl apply -f - >&2 <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SERVICE_ACCOUNT}
type: kubernetes.io/service-account-token
EOF
fi

log "Waiting for the token controller to populate $TOKEN_SECRET ..."
TOKEN_B64=""
for _ in $(seq 1 30); do
    TOKEN_B64="$(kubectl -n "$NAMESPACE" get secret "$TOKEN_SECRET" \
        -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [ -n "$TOKEN_B64" ] && break
    sleep 1
done
[ -n "$TOKEN_B64" ] || die "token Secret $TOKEN_SECRET was not populated in time."

# --- 4. assemble a self-contained kubeconfig (no exec plugin) ----------------
# CA comes straight off the Secret (already base64 PEM -> use verbatim for
# certificate-authority-data). Server + a stable cluster name come from the admin
# context. Token is the decoded JWT.
CA_DATA="$(kubectl -n "$NAMESPACE" get secret "$TOKEN_SECRET" -o jsonpath='{.data.ca\.crt}')"
[ -n "$CA_DATA" ] || die "could not read ca.crt from $TOKEN_SECRET."

SERVER="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
CLUSTER_NAME="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].name}')"
[ -n "$SERVER" ] || die "could not determine the API server URL from the current context."
CLUSTER_NAME="${CLUSTER_NAME:-aks}"
TOKEN="$(printf '%s' "$TOKEN_B64" | base64 -d)"

umask 077
cat > "$OUT_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${SERVICE_ACCOUNT}
    user:
      token: ${TOKEN}
contexts:
  - name: ${SERVICE_ACCOUNT}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${SERVICE_ACCOUNT}
      namespace: ${NAMESPACE}
current-context: ${SERVICE_ACCOUNT}@${CLUSTER_NAME}
EOF

log "Wrote self-contained kubeconfig to $OUT_FILE"

# Sanity check: the minted kubeconfig should authenticate as the viewer SA.
if KUBECONFIG="$OUT_FILE" kubectl auth whoami >/dev/null 2>&1; then
    log "Verified: kubeconfig authenticates ($(KUBECONFIG="$OUT_FILE" kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null))."
else
    log "WARN: could not verify the kubeconfig (cluster may be unreachable right now); it was still written."
fi

# --- 5. emit the value the devcontainer consumes -----------------------------
KUBECONFIG_B64="$(base64 -w0 "$OUT_FILE" 2>/dev/null || base64 "$OUT_FILE" | tr -d '\n')"

cat >&2 <<EOF

Done. Add this to your HOST shell profile (~/.bashrc, ~/.zshrc, ...), then reopen
the devcontainer so devcontainer.json forwards it as \${localEnv:KUBECONFIG_B64}:

    export KUBECONFIG_B64=$KUBECONFIG_B64

EOF

# Also print the bare value to stdout so it can be captured/piped if desired.
printf '%s\n' "$KUBECONFIG_B64"
