#!/usr/bin/env bash
# Combines per-platform digests into one multi-arch manifest list per image and
# writes the Bicep parameters that reference each image by digest.
#
# Inputs (environment):
#   IMAGES       JSON array from the plan step ({ param, name, repository, ... }).
#   DIGESTS_DIR  Directory with one file per pushed platform image:
#                <name>/<sha256 hex>  (file contents are ignored).
#   TAGS         Space-separated tags to apply to every manifest list.
#   PARAMS_FILE  Path to write the ARM parameters JSON for `rad deploy -p @file`.
# Outputs (stdout, GITHUB_OUTPUT format): parameters=<json object param -> ref>
set -euo pipefail

: "${IMAGES:?}" "${DIGESTS_DIR:?}" "${TAGS:?}" "${PARAMS_FILE:?}"

parameters='{}'

while IFS=$'\t' read -r param name repository; do
  [ -n "$param" ] || continue
  dir="$DIGESTS_DIR/$name"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir")" ]; then
    echo "::error::no platform digests found for image '$name'" >&2
    exit 1
  fi

  sources=()
  for f in "$dir"/*; do
    sources+=("${repository}@sha256:$(basename "$f")")
  done

  read -r -a tags <<<"$TAGS"
  tag_args=()
  for t in "${tags[@]}"; do
    tag_args+=(--tag "${repository}:${t}")
  done

  docker buildx imagetools create "${tag_args[@]}" "${sources[@]}" >&2

  digest="$(docker buildx imagetools inspect "${repository}:${tags[0]}" --format '{{json .Manifest}}' | jq -r '.digest')"
  ref="${repository}@${digest}"
  echo "$param -> $ref" >&2
  docker buildx imagetools inspect "$ref" >&2

  parameters="$(jq -c --arg k "$param" --arg v "$ref" '. + {($k): $v}' <<<"$parameters")"
done < <(jq -r '.[] | [.param, .name, .repository] | @tsv' <<<"$IMAGES")

jq '{"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
     contentVersion: "1.0.0.0",
     parameters: with_entries(.value = {value: .value})}' <<<"$parameters" > "$PARAMS_FILE"

echo "parameters=$parameters"
