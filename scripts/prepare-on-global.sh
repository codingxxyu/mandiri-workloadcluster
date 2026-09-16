#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDERED_DIR="${ROOT_DIR}/rendered"

[[ "$(hostname)" == global-master01* ]] || {
  printf 'ERROR: run this script on Global Master 01. Current host: %s\n' "$(hostname)" >&2
  exit 1
}

command -v kubectl >/dev/null || { echo 'ERROR: kubectl is missing' >&2; exit 1; }
command -v jq >/dev/null || { echo 'ERROR: jq is missing' >&2; exit 1; }
kubectl cluster-info >/dev/null

GLOBAL_REGISTRY="$(kubectl -n cpaas-system get cluster global -o jsonpath='{.metadata.annotations.cpaas\.io/registry-address}')"
[[ -n "$GLOBAL_REGISTRY" ]] || { echo 'ERROR: global registry annotation is empty' >&2; exit 1; }

SSH_PUBLIC_KEY_FILE="$(find /root/.ssh -maxdepth 1 -type f -name '*.pub' -print -quit)"
[[ -n "$SSH_PUBLIC_KEY_FILE" ]] || { echo 'ERROR: no /root/.ssh/*.pub key found on Global Master 01' >&2; exit 1; }
SSH_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_FILE")"

WORKLOAD_API_ENDPOINT="${WORKLOAD_API_ENDPOINT:?Set WORKLOAD_API_ENDPOINT to the External LB VIP or FQDN}"
PROVIDER_ID_VALUE="${PROVIDER_ID_VALUE:?Set PROVIDER_ID_VALUE from the ACP 4.3.2 official Bare Metal example}"

rm -rf "$RENDERED_DIR"
mkdir -p "$RENDERED_DIR"
cp -R "$ROOT_DIR/manifests/." "$RENDERED_DIR/"

python3 - "$RENDERED_DIR" "$GLOBAL_REGISTRY" "$WORKLOAD_API_ENDPOINT" "$SSH_PUBLIC_KEY" "$PROVIDER_ID_VALUE" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); registry, endpoint, key, provider_id=sys.argv[2:]
replacements={
    '<existing-global-registry>': registry.removesuffix(':11443'),
    '<workload-api-fqdn-or-vip>': endpoint,
    '<deployment-ssh-public-key>': key,
    '<ACP-4.3.2-provider-supported-value>': provider_id,
}
for path in root.rglob('*.yaml'):
    text=path.read_text()
    for old,new in replacements.items(): text=text.replace(old,new)
    path.write_text(text)
PY

if grep -RInE '<[^>]+>|PROVIDER_ID|\.\.\.' "$RENDERED_DIR" --include='*.yaml'; then
  echo 'ERROR: unresolved placeholders remain. Inventory, data-disk and worker templates are expected to remain unresolved until their phase; do not apply them.' >&2
fi

printf 'Global registry: %s\n' "$GLOBAL_REGISTRY"
printf 'SSH public key: %s\n' "$SSH_PUBLIC_KEY_FILE"
printf 'Rendered manifests: %s\n' "$RENDERED_DIR"
printf 'Review every YAML before kubectl apply.\n'
