#!/usr/bin/env bash
# Reports the images of playbooks/group_vars/all/images.yml that have a newer version.
# Read only: it asks the registries and changes nothing. Run by the weekly workflow
# image-updates; the operator learns of an update because the run fails (an e-mail).
#
# Each line of images.yml is "<name>_image: "<repository>@sha256:<digest>"  # track: <tag>".
#   - A version tag (0.19.1, v1.2.3): newer when the registry has a higher version of
#     the same shape (x.y.z stays x.y.z; no -rc, -alpine…).
#   - Any other tag (pg18): it moves with each release; newer when its digest is no
#     longer the pinned one.
# In both cases it also says if the tag being tracked no longer points to the pinned
# digest (the image was rebuilt under the same version).
#
# Usage: image-updates.sh [images.yml]
# Exit: 0 nothing new; 1 at least one update (each one as ::error with the new digest);
#       2 the file or a registry could not be read.
# SKOPEO overrides the skopeo binary (tests/images/run.sh uses a fake one).
set -euo pipefail

file=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/playbooks/group_vars/all/images.yml}
skopeo=${SKOPEO:-skopeo}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
version_re='^v?[0-9]+(\.[0-9]+)+$'

# fd 3 is the real stdout: a problem found inside $(…) must still reach the annotations.
exec 3>&1
problem() { echo "::error title=image-updates::$*" >&3; exit 2; }
[[ -r $file ]] || problem "cannot read $file"
command -v "$skopeo" >/dev/null || problem "skopeo not found"

# Reads the index (manifest list) a tag points to. Prints its digest, the same digest
# images.yml pins, and its platforms (D6: the GX10 needs linux/arm64).
index_of() {
  local raw platforms
  # A file, not $(…): the digest is over the exact bytes, and $(…) drops a final newline.
  raw=$(mktemp)
  "$skopeo" inspect --retry-times 3 --raw "docker://$1" >"$raw" || { rm -f "$raw"; problem "cannot read $1 from the registry"; }
  platforms=$(jq -r '[.manifests[]?.platform | select(.os != "unknown") | "\(.os)/\(.architecture)"] | unique | join(",")' "$raw" 2>/dev/null || true)
  printf 'sha256:%s %s\n' "$(sha256sum "$raw" | cut -d' ' -f1)" "${platforms:-not an index}"
  rm -f "$raw"
}

# Tags with the same shape as $2 (same number of parts, same v prefix), highest first.
newer_versions() {
  local repo=$1 current=$2 prefix='' parts tags
  [[ $current == v* ]] && prefix=v
  parts=$(tr -cd . <<<"$current" | wc -c)
  tags=$("$skopeo" list-tags --retry-times 3 "docker://$repo") || problem "cannot list the tags of $repo"
  jq -r '.Tags[]' <<<"$tags" | { grep -E "^${prefix}[0-9]+(\.[0-9]+){$parts}$" || true; } | sort -rV
}

lines=0 updates=0
# The backticks are Markdown for the job summary, not commands.
# shellcheck disable=SC2016
printf '| Imagen | Sigue | Fijada | Hay | Digest nuevo | Plataformas |\n| --- | --- | --- | --- | --- | --- |\n' >>"$summary"
while IFS= read -r line; do
  [[ $line =~ ^([a-z0-9_]+)_image:\ *\"([^\"@]+)@(sha256:[0-9a-f]{64})\"\ *#\ *track:\ *([^[:space:]]+) ]] || continue
  name=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} pinned=${BASH_REMATCH[3]} track=${BASH_REMATCH[4]}
  lines=$((lines + 1))
  found=$track new=''
  read -r current current_platforms < <(index_of "$repo:$track") || exit 2
  if [[ $track =~ $version_re ]]; then
    highest=$(newer_versions "$repo" "$track" | head -1)
    if [[ -n $highest && $highest != "$track" && $(printf '%s\n%s\n' "$track" "$highest" | sort -V | tail -1) == "$highest" ]]; then
      found=$highest
      read -r new platforms < <(index_of "$repo:$highest") || exit 2
      echo "::error title=New version of ${name}_image::$repo $highest (images.yml tracks $track). Digest: $new. Platforms: $platforms"
    fi
  fi
  if [[ -z $new && $current != "$pinned" ]]; then
    new=$current platforms=$current_platforms
    echo "::error title=New image for ${name}_image::$repo:$track now points to $current (images.yml pins $pinned). Platforms: $platforms"
  fi
  # shellcheck disable=SC2016
  if [[ -n $new ]]; then
    updates=$((updates + 1))
    printf '| `%s_image` | `%s` | `%s` | `%s` | `%s` | %s |\n' "$name" "$track" "${pinned:0:19}…" "$found" "$new" "$platforms" >>"$summary"
  else
    echo "ok: ${name}_image is up to date ($repo:$track)"
    printf '| `%s_image` | `%s` | `%s` | al día | | |\n' "$name" "$track" "${pinned:0:19}…" >>"$summary"
  fi
done <"$file"

((lines > 0)) || problem "no image lines with '# track:' in $file"
if ((updates > 0)); then
  echo "$updates image(s) to update: change the digest in images.yml in a PR (docs/WORKFLOW.md)"
  exit 1
fi
echo "all $lines images are up to date"
