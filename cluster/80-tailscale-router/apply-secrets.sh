#!/usr/bin/env bash
#
# Generate the tailscale-router-auth Secret from the Kauket-managed env file.
# Replaces the old sealed-secret: TS_AUTHKEY now lives in the Kauket store
# (k8s.tailscale_router_auth_env, profile role.k8s_admin) and is installed
# locally by `kauket get`. Run on a k8s-admin host (role.k8s_admin) before/
# around `kubectl apply -k cluster/`.
#
set -euo pipefail

NS=kube-system
KUBECTL="${KUBECTL:-kubectl}"
DIR="${K8S_SECRETS_DIR:-$HOME/k8s-secrets}"
ENVF="$DIR/tailscale-router-auth.env"

if command -v kauket >/dev/null 2>&1; then
    KAUKET_HOME="${KAUKET_HOME:-$HOME/.config/kauket}" kauket get k8s.tailscale_router_auth_env >/dev/null 2>&1 || true
fi
[ -s "$ENVF" ] || { echo "apply-secrets: missing $ENVF (run: kauket get k8s.tailscale_router_auth_env)" >&2; exit 1; }

"$KUBECTL" create secret generic tailscale-router-auth -n "$NS" \
    --from-env-file="$ENVF" --dry-run=client -o yaml | "$KUBECTL" apply -f -
