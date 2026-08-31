#!/usr/bin/env bash

set -Eeuo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RELEASE_TAG:=Manifest-V3-Update}"
: "${RELEASE_ASSET:=build/release.zip}"
: "${RELEASE_TARGET_BRANCH:=update-to-mv3}"
: "${RELEASE_FALLBACK_TITLE:=Manifest V3 Update - Personal Testing Release}"
: "${RELEASE_FALLBACK_NOTES:=.github/release-notes.md}"
: "${TARGET_SHA:?TARGET_SHA is required}"

release_json=""
release_id=""
release_title="$RELEASE_FALLBACK_TITLE"
release_draft=false
release_prerelease=false
notes_file="${RUNNER_TEMP:-/tmp}/kc3kai-release-notes.md"

if release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" 2>/dev/null)"; then
  release_id="$(jq -r '.id' <<< "$release_json")"
  release_title="$(jq -r '.name // empty' <<< "$release_json")"
  release_draft="$(jq -r '.draft' <<< "$release_json")"
  release_prerelease="$(jq -r '.prerelease' <<< "$release_json")"
  # -j keeps the exact body bytes without jq adding a line terminator.
  jq -j '.body // ""' <<< "$release_json" > "$notes_file"
else
  cp "$RELEASE_FALLBACK_NOTES" "$notes_file"
fi

if [[ -z "$release_title" ]]; then
  release_title="$RELEASE_FALLBACK_TITLE"
fi

metadata_hash_before=""
if [[ -n "$release_json" ]]; then
  metadata_hash_before="$(jq -c '{tag_name,name,body,draft,prerelease}' <<< "$release_json" | shasum -a 256 | awk '{print $1}')"
fi

# Keep the stable release URL while making its source archive point at the
# tested MV3 commit.
if ref_json="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG" 2>/dev/null)"; then
  current_tag_sha="$(jq -r '.object.sha' <<< "$ref_json")"
  if [[ "$current_tag_sha" != "$TARGET_SHA" ]]; then
    gh api --method PATCH \
      "repos/$GITHUB_REPOSITORY/git/refs/tags/$RELEASE_TAG" \
      -f "sha=$TARGET_SHA" \
      -F force=true >/dev/null
  fi
else
  gh api --method POST \
    "repos/$GITHUB_REPOSITORY/git/refs" \
    -f "ref=refs/tags/$RELEASE_TAG" \
    -f "sha=$TARGET_SHA" >/dev/null
fi

if [[ -n "$release_id" ]]; then
  gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/$release_id" >/dev/null
  echo "deleted release id $release_id"
fi

release_payload_file="${RUNNER_TEMP:-/tmp}/kc3kai-release-payload.json"
if [[ "$release_draft" == "true" || "$release_prerelease" == "true" ]]; then
  make_latest="legacy"
else
  make_latest="true"
fi
jq -n \
  --arg tag "$RELEASE_TAG" \
  --arg name "$release_title" \
  --rawfile body "$notes_file" \
  --arg target "$RELEASE_TARGET_BRANCH" \
  --argjson draft "$release_draft" \
  --argjson prerelease "$release_prerelease" \
  --arg make_latest "$make_latest" \
  '{tag_name:$tag,name:$name,body:$body,target_commitish:$target,draft:$draft,prerelease:$prerelease,make_latest:$make_latest}' \
  > "$release_payload_file"

new_release_json="$(gh api --method POST \
  "repos/$GITHUB_REPOSITORY/releases" \
  --input "$release_payload_file")"
new_release_id="$(jq -r '.id' <<< "$new_release_json")"
upload_response="$(gh api --method POST \
  "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$new_release_id/assets?name=release.zip" \
  -H 'Content-Type: application/zip' \
  --input "$RELEASE_ASSET")"
new_asset_size="$(jq -r '.size' <<< "$upload_response")"
release_url="$(jq -r '.html_url' <<< "$new_release_json")"
new_release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/$new_release_id")"
local_asset_size="$(stat -c '%s' "$RELEASE_ASSET")"
final_tag_sha="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG" | jq -r '.object.sha')"

test "$final_tag_sha" = "$TARGET_SHA"
test "$new_asset_size" = "$local_asset_size"
if [[ -n "$metadata_hash_before" ]]; then
  metadata_hash_after="$(jq -c '{tag_name,name,body,draft,prerelease}' <<< "$new_release_json" | shasum -a 256 | awk '{print $1}')"
  test "$metadata_hash_before" = "$metadata_hash_after"
fi

echo "published release id $new_release_id: $release_url"
echo "release asset size: $new_asset_size bytes"
echo "release content preserved: yes"
