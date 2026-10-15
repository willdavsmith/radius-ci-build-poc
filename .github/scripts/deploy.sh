#!/usr/bin/env bash
# Deploys the application with CI-built image references.
#
# Inputs (environment):
#   TEMPLATE    Application Bicep file.
#   PARAMETERS  JSON object mapping Bicep parameter names to image references.
set -euo pipefail

: "${TEMPLATE:?}" "${PARAMETERS:?}"

args=()
while IFS=$'\t' read -r name value; do
  [ -n "$name" ] || continue
  args+=(--parameters "${name}=${value}")
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$PARAMETERS")

echo "rad deploy $TEMPLATE ${args[*]}"
rad deploy "$TEMPLATE" "${args[@]}"
