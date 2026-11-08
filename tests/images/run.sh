#!/usr/bin/env bash
# Tests for scripts/image-updates.sh with a fake skopeo: the sandbox and the lint job do
# not reach the registries. The real check runs weekly in .github/workflows/image-updates.yml.
set -euo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/image-updates.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SKOPEO=$work/skopeo REGISTRY=$work/registry
mkdir -p "$REGISTRY"

# The fake registry: $REGISTRY/<repo with / as _>/<tag> holds the raw index of that tag.
cat >"$SKOPEO" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
ref=${*: -1}; ref=${ref#docker://}
case $1 in
  inspect) repo=${ref%:*} tag=${ref##*:}; cat "$REGISTRY/${repo//\//_}/$tag" ;;
  list-tags) dir=$REGISTRY/${ref//\//_}; [[ -d $dir ]] || exit 1
    printf '{"Repository":"%s","Tags":[' "$ref"; ls "$dir" | sed 's/.*/"&"/' | paste -sd, | tr -d '\n'; printf ']}\n' ;;
  *) exit 64 ;;
esac
FAKE
chmod +x "$SKOPEO"

# An index for linux/amd64 and linux/arm64 (and an attestation, which does not count).
idx() { printf '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"unknown","architecture":"unknown"}}],"v":"%s"}' "$1"; }

# publish <repo> <tag> <content>: prints the digest images.yml would pin.
publish() {
  local dir=$REGISTRY/${1//\//_}
  mkdir -p "$dir"
  # With a final newline, as some registries serve them: the digest is over every byte.
  printf '%s\n' "$3" >"$dir/$2"
  printf 'sha256:%s' "$(sha256sum "$dir/$2" | cut -d' ' -f1)"
}
images() { # images <name> <repo> <digest> <track>...
  : >"$work/images.yml"
  echo '---' >>"$work/images.yml"
  while (($#)); do
    printf '# comment\n%s_image: "%s@%s"  # track: %s\n' "$1" "$2" "$3" "$4" >>"$work/images.yml"
    shift 4
  done
}

failures=0
expect() { # expect <name> <exit code> [text in the output]...
  local name=$1 want=$2 rc=0 out
  shift 2
  out=$(GITHUB_STEP_SUMMARY=$work/summary "$script" "$work/images.yml" 2>&1) || rc=$?
  if [[ $rc != "$want" ]]; then echo "FAIL: $name: exit $rc, expected $want"; echo "$out"; failures=$((failures + 1)); return; fi
  for text in "$@"; do
    if ! grep -qF -- "$text" <<<"$out"; then echo "FAIL: $name: no '$text' in:"; echo "$out"; failures=$((failures + 1)); return; fi
  done
  echo "ok: $name"
}

pg=$(publish docker.io/pgvector/pgvector pg18 "$(idx pg-1)")
r1=$(publish docker.io/restic/restic 0.19.1 "$(idx r-191)")
publish docker.io/restic/restic latest "$(idx r-latest)" >/dev/null
publish docker.io/restic/restic 0.19.2-rc1 "$(idx r-rc)" >/dev/null
publish docker.io/restic/restic 0.9.9 "$(idx r-99)" >/dev/null

images postgres docker.io/pgvector/pgvector "$pg" pg18 restic docker.io/restic/restic "$r1" 0.19.1
expect "all up to date" 0 "all 2 images are up to date"

r2=$(publish docker.io/restic/restic 0.20.0 "$(idx r-200)")
expect "a higher version, ignoring -rc, latest and lower ones" 1 \
  "::error title=New version of restic_image::docker.io/restic/restic 0.20.0 (images.yml tracks 0.19.1). Digest: $r2. Platforms: linux/amd64,linux/arm64" \
  "1 image(s) to update"
if grep -qF "| \`restic_image\` | \`0.19.1\` |" "$work/summary"; then echo "ok: the job summary lists it"; else echo "FAIL: summary"; failures=$((failures + 1)); fi
rm "$REGISTRY/docker.io_restic_restic/0.20.0"

# A version with a prefix, as Firefly III publishes them (version-6.7.9): only the same
# prefix and shape count, so not version-6.8 (a moving minor), 6.8.0, latest or develop.
ff=$(publish docker.io/fireflyiii/core version-6.7.9 "$(idx ff-679)")
for tag in version-6.7 version-6.8 6.8.0 7.0.0 latest develop version-6.7.8 version-7.0.0-beta1; do
  publish docker.io/fireflyiii/core "$tag" "$(idx "ff-$tag")" >/dev/null
done
images firefly docker.io/fireflyiii/core "$ff" version-6.7.9
expect "a prefixed version, up to date" 0 "ok: firefly_image is up to date (docker.io/fireflyiii/core:version-6.7.9)"
ff2=$(publish docker.io/fireflyiii/core version-6.7.10 "$(idx ff-6710)")
expect "a higher prefixed version, 6.7.10 after 6.7.9" 1 \
  "::error title=New version of firefly_image::docker.io/fireflyiii/core version-6.7.10 (images.yml tracks version-6.7.9). Digest: $ff2."
publish docker.io/fireflyiii/core version-7.0.0 "$(idx ff-700)" >/dev/null
expect "the highest of several, a new major" 1 \
  "::error title=New version of firefly_image::docker.io/fireflyiii/core version-7.0.0 (images.yml tracks version-6.7.9)."
images firefly docker.io/fireflyiii/core "$ff" version-6.7.9 postgres docker.io/pgvector/pgvector "$pg" pg18 \
  restic docker.io/restic/restic "$r1" 0.19.1
expect "the other images are unchanged beside it" 1 "ok: postgres_image is up to date" "ok: restic_image is up to date" \
  "1 image(s) to update"
# The v prefix keeps working, and does not mix with tags without it.
v1=$(publish example.org/tool v1.2.3 "$(idx v-123)")
v2=$(publish example.org/tool v1.2.4 "$(idx v-124)")
publish example.org/tool 1.2.5 "$(idx n-125)" >/dev/null
images tool example.org/tool "$v1" v1.2.3
expect "a v prefix, not mixed with tags without it" 1 \
  "::error title=New version of tool_image::example.org/tool v1.2.4 (images.yml tracks v1.2.3). Digest: $v2."
images postgres docker.io/pgvector/pgvector "$pg" pg18 restic docker.io/restic/restic "$r1" 0.19.1

pg2=$(publish docker.io/pgvector/pgvector pg18 "$(idx pg-2)")
expect "a moving tag with a new digest" 1 \
  "::error title=New image for postgres_image::docker.io/pgvector/pgvector:pg18 now points to $pg2 (images.yml pins $pg). Platforms: linux/amd64,linux/arm64"
publish docker.io/pgvector/pgvector pg18 "$(idx pg-1)" >/dev/null

publish docker.io/restic/restic 0.19.1 "$(idx r-rebuilt)" >/dev/null
expect "the same version rebuilt" 1 "::error title=New image for restic_image::docker.io/restic/restic:0.19.1 now points to"

publish docker.io/restic/restic 0.19.1 '{"single":"manifest"}' >/dev/null
images restic docker.io/restic/restic "$r1" 0.19.1
expect "a tag that is not a multi-platform index" 1 "Platforms: not an index"

images postgres docker.io/pgvector/pgvector "$pg" pg99
expect "a tag that does not exist" 2 "::error title=image-updates::cannot read docker.io/pgvector/pgvector:pg99 from the registry"

: >"$work/images.yml"
expect "no image lines" 2 "no image lines with '# track:'"

images postgres docker.io/pgvector/pgvector "$pg" pg18
SKOPEO=$work/missing expect "no skopeo" 2 "skopeo not found"

# The real file: every image line has a track tag the script understands.
n=$(grep -cE '^[a-z0-9_]+_image: "[^"@]+@sha256:[0-9a-f]{64}" +# track: [^ ]+$' "$(dirname "$script")/../playbooks/group_vars/all/images.yml")
m=$(grep -cE '^[a-z0-9_]+_image:' "$(dirname "$script")/../playbooks/group_vars/all/images.yml")
if [[ $n == "$m" && $n -gt 0 ]]; then echo "ok: images.yml has $n images, all with '# track:'"; else echo "FAIL: images.yml: $n of $m lines have '# track:'"; failures=$((failures + 1)); fi

((failures == 0)) || { echo "$failures test(s) failed"; exit 1; }
echo "all image-updates tests passed"
