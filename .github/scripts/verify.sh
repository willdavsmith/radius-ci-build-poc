#!/usr/bin/env bash
# Verifies that every deployment of the application runs the exact image digests
# CI built, waits for rollout, and calls the api service to report its architecture.
#
# Inputs (environment):
#   APP_NAME       Radius application name (radapp.io/application label).
#   API_RESOURCE   Radius resource name of the api container (radapp.io/resource label).
#   PARAMETERS     JSON object mapping Bicep parameter names to image references.
#   KUBECONFIG     Optional; the cluster the application resources were deployed to.
set -euo pipefail

: "${APP_NAME:?}" "${API_RESOURCE:?}" "${PARAMETERS:?}"

selector="radapp.io/application=${APP_NAME}"
deployments="$(kubectl get deployment -A -l "$selector" -o json)"
count="$(jq '.items | length' <<<"$deployments")"
if [ "$count" -eq 0 ]; then
  echo "::error::no deployments found with label $selector" >&2
  exit 1
fi

expected="$(jq -c '[.[]]' <<<"$PARAMETERS")"
while IFS=$'\t' read -r ns name image; do
  echo "deployment $ns/$name image=$image"
  if ! jq -e --arg img "$image" 'index($img) != null' <<<"$expected" >/dev/null; then
    echo "::error::deployment $ns/$name runs $image, which is not a CI-built digest" >&2
    exit 1
  fi
  kubectl rollout status "deployment/$name" -n "$ns" --timeout=300s
done < <(jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n
  | .spec.template.spec.containers[] | [$ns, $n, .image] | @tsv' <<<"$deployments")

read -r api_ns api_deploy < <(kubectl get deployment -A -l "radapp.io/resource=${API_RESOURCE}" \
  -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}')
node="$(kubectl get pod -n "$api_ns" -l "radapp.io/resource=${API_RESOURCE}" -o jsonpath='{.items[0].spec.nodeName}')"
node_arch="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')"

kubectl port-forward -n "$api_ns" "deployment/$api_deploy" 18080:8080 >/dev/null 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  if response="$(curl -fsS http://127.0.0.1:18080/)"; then break; fi
  sleep 1
done
echo "api response: ${response:?api did not respond}"
echo "api node $node arch: $node_arch"

if [ "$(jq -r .arch <<<"$response")" != "$node_arch" ]; then
  echo "::error::api reports arch $(jq -r .arch <<<"$response") but node is $node_arch" >&2
  exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ${APP_NAME}"
    echo
    echo "| Deployment | Image |"
    echo "|---|---|"
    jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $n
      | .spec.template.spec.containers[] | "| \($ns)/\($n) | `\(.image)` |"' <<<"$deployments"
    echo
    echo "api on node arch \`${node_arch}\` returned \`${response}\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
