#!/usr/bin/env bash
# Uploads an Acode plugin zip to acode.app with an API key.
# Inputs come from INPUT_* environment variables (see action.yml).
set -euo pipefail

api_key="${INPUT_API_KEY:-}"
zip="${INPUT_ZIP:-plugin.zip}"
changelogs="${INPUT_CHANGELOGS:-}"
create_if_missing="${INPUT_CREATE_IF_MISSING:-false}"
api_url="${INPUT_API_URL:-https://acode.app}"
api_url="${api_url%/}"

fail() {
  echo "::error title=Acode publish::$1"
  exit 1
}

set_output() {
  # Values are single-line, so the simple name=value form is safe.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

# shellcheck disable=SC2016 # the ${{ }} is GitHub Actions syntax shown to the user, not shell
[[ -n "$api_key" ]] || fail 'api-key is empty. Save your key as a repository secret and pass it with api-key: ${{ secrets.ACODE_API_KEY }}.'
echo "::add-mask::$api_key"
[[ "$api_key" =~ ^acode_[0-9A-Za-z]{42}$ ]] || fail "api-key is not an Acode API key. Create one at https://acode.app/api-keys."

case "$create_if_missing" in
  true | false) ;;
  *) fail "create-if-missing must be true or false." ;;
esac

# Never send the key over plain HTTP, except to a local test server.
[[ "$api_url" =~ ^https:// || "$api_url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$ ]] || fail "api-url must use https."

[[ -f "$zip" ]] || fail "Plugin zip not found at '$zip'. Build the plugin first or set the zip input."
manifest="$(unzip -p "$zip" plugin.json 2>/dev/null)" || fail "plugin.json is missing from the root of '$zip'."
{
  read -r plugin_id
  read -r version
} < <(node -e '
  try {
    const m = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(String(m.id || "").toLowerCase());
    console.log(String(m.version || ""));
  } catch {
    console.log(""); console.log("");
  }' <<<"$manifest")
[[ -n "$plugin_id" && -n "$version" ]] || fail "plugin.json in '$zip' must have an id and a version."

set_output plugin-id "$plugin_id"
set_output version "$version"
echo "Publishing $plugin_id $version to $api_url"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# Sets http_status, error_code, under_review, message and warning.
upload() {
  local method="$1"
  local args=(
    --silent --show-error
    --connect-timeout 30 --max-time 300
    --request "$method"
    --output "$body_file"
    --write-out '%{http_code}'
    --config -
    --form "plugin=@${zip};type=application/zip"
  )
  # --form-string sends the text as is; with --form a leading @ or < would read a file.
  if [[ -n "$changelogs" ]]; then args+=(--form-string "changelogs=$changelogs"); fi

  # The key goes through stdin, so it never shows up in the process list.
  http_status="$(printf 'header = "Authorization: Bearer %s"\n' "$api_key" | curl "${args[@]}" "$api_url/api/plugin")" ||
    fail "Could not reach $api_url."

  {
    read -r error_code
    read -r under_review
    read -r message
    read -r warning
  } < <(node -e '
    let r = {};
    try { r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch {}
    const line = (v) => String(v ?? "").replace(/\s+/g, " ").trim();
    console.log(line(r.code));
    console.log(r.review === true ? "true" : "false");
    console.log(line(r.error || r.message));
    console.log(line(r.warning));' "$body_file")
}

result=published
upload PUT

if [[ "$http_status" == 403 && "$error_code" == plugin_not_found && "$create_if_missing" == true ]]; then
  echo "::notice title=Acode publish::$plugin_id doesn't exist yet, submitting it as a new plugin."
  result=submitted
  upload POST
fi

if [[ ! "$http_status" =~ ^2 ]]; then
  [[ -n "$message" ]] || message="acode.app responded with HTTP $http_status."
  if [[ "$error_code" == plugin_not_found && "$create_if_missing" != true ]]; then
    message="$message Set create-if-missing: true to submit it from CI."
  fi
  fail "$message"
fi

if [[ "$result" == published && "$under_review" == true ]]; then result=review; fi

set_output result "$result"
set_output message "$message"
if [[ -n "$warning" ]]; then echo "::warning title=Acode publish::$warning"; fi

case "$result" in
  published) summary="$plugin_id $version is live." ;;
  review) summary="$plugin_id $version was held for admin review and will go live once approved." ;;
  submitted) summary="$plugin_id $version was submitted and is waiting for admin approval." ;;
esac
echo "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### Acode plugin\n\n%s\n\n%s\n' "$summary" "$message" >>"$GITHUB_STEP_SUMMARY"
fi
