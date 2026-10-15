#!/usr/bin/env bash
# Reads `metadata.radius.build` from the parameters of a compiled Bicep template
# and emits the build matrix (one entry per image x platform) and the image list.
#
# Inputs (environment):
#   TEMPLATE_JSON      Compiled ARM JSON of the application template.
#   REGISTRY           Repository prefix for pushed images (e.g. ghcr.io/owner/repo).
#   DEFAULT_PLATFORMS  Comma-separated platforms used when an image sets none.
#   AMD64_RUNNER       Runner label for linux/amd64 builds.
#   ARM64_RUNNER       Runner label for linux/arm64 builds.
#   WORKSPACE          Directory that build contexts are relative to.
# Outputs (stdout, GITHUB_OUTPUT format): matrix=<json>, images=<json>, count=<n>
set -euo pipefail

: "${TEMPLATE_JSON:?}" "${REGISTRY:?}" "${DEFAULT_PLATFORMS:?}"
: "${AMD64_RUNNER:?}" "${ARM64_RUNNER:?}" "${WORKSPACE:=.}"

registry="$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')"

images="$(jq -c \
  --arg registry "$registry" \
  --arg defaultPlatforms "$DEFAULT_PLATFORMS" '
  [ (.parameters // {}) | to_entries[]
    | select(.value.metadata.radius.build != null)
    | .key as $param
    | .value.metadata.radius.build as $b
    | ($b.name // ($param | sub("Image$"; "")
        | gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)-\(.b)")
        | ascii_downcase)) as $name
    | ($b.context // error("parameter \($param): metadata.radius.build.context is required")) as $context
    | {
        param: $param,
        name: $name,
        repository: "\($registry)/\($name)",
        context: $context,
        dockerfile: ($context + "/" + ($b.dockerfile // "Dockerfile")),
        platforms: ($b.platforms // ($defaultPlatforms | split(",") | map(gsub("^\\s+|\\s+$"; ""))))
      }
  ]' "$TEMPLATE_JSON")"

count="$(jq 'length' <<<"$images")"

while IFS=$'\t' read -r param context dockerfile; do
  [ -n "$param" ] || continue
  if [ ! -d "$WORKSPACE/$context" ]; then
    echo "::error::$param: build context '$context' does not exist" >&2
    exit 1
  fi
  if [ ! -f "$WORKSPACE/$dockerfile" ]; then
    echo "::error::$param: Dockerfile '$dockerfile' does not exist" >&2
    exit 1
  fi
done < <(jq -r '.[] | [.param, .context, .dockerfile] | @tsv' <<<"$images")

dupes="$(jq -r 'group_by(.name) | map(select(length > 1) | .[0].name) | join(",")' <<<"$images")"
if [ -n "$dupes" ]; then
  echo "::error::multiple parameters resolve to the same image name: $dupes (set metadata.radius.build.name)" >&2
  exit 1
fi

matrix="$(jq -c \
  --arg amd64 "$AMD64_RUNNER" \
  --arg arm64 "$ARM64_RUNNER" '
  { include: [ .[] | . as $img | $img.platforms[] as $p
      | {
          param: $img.param,
          name: $img.name,
          repository: $img.repository,
          context: $img.context,
          dockerfile: $img.dockerfile,
          platform: $p,
          slug: "\($img.name)-\($p | gsub("[^A-Za-z0-9]+"; "-"))",
          runner: (if $p == "linux/amd64" then $amd64
                   elif $p == "linux/arm64" then $arm64
                   else $amd64 end),
          emulate: ($p != "linux/amd64" and $p != "linux/arm64")
        } ] }' <<<"$images")"

echo "matrix=$matrix"
echo "images=$images"
echo "count=$count"
