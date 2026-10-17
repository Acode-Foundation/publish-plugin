#!/usr/bin/env bash
# Runs publish.sh against a mock server for each scenario. Needs bash, curl, zip, unzip and node.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'kill "${server_pid:-}" 2>/dev/null; wait "${server_pid:-}" 2>/dev/null; rm -rf "$work"' EXIT

key="acode_$(printf 'a%.0s' {1..42})"
port=47321
passed=0
failed=0

(cd "$work" && printf '{"id":"Test.Plugin","name":"Test","version":"1.2.3","main":"main.js"}' >plugin.json && echo '' >main.js && zip -q plugin.zip plugin.json main.js)

start_server() {
  kill "${server_pid:-}" 2>/dev/null
  wait "${server_pid:-}" 2>/dev/null
  : >"$work/requests.log"
  node "$root/test/mock-server.mjs" "$port" "$1" "$work/requests.log" &
  server_pid=$!
  for _ in $(seq 1 50); do
    # The readiness ping is logged too, so clear the log once the server answers.
    if curl -s -o /dev/null "http://127.0.0.1:$port"; then
      : >"$work/requests.log"
      return
    fi
    sleep 0.1
  done
}

# run <name> <expected exit> [VAR=value ...]
run() {
  local name="$1" expected="$2"
  shift 2
  : >"$work/output"
  (
    cd "$work" || exit 1
    env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$work/output" \
      INPUT_API_KEY="$key" INPUT_API_URL="http://127.0.0.1:$port" "$@" \
      bash "$root/publish.sh"
  ) >"$work/stdout" 2>&1
  local status=$?
  if [[ $status -ne $expected ]]; then
    report_fail "$name: exit $status, expected $expected"
    return 1
  fi
}

check() { # <name> <condition description> <command...>
  local name="$1" what="$2"
  shift 2
  if "$@"; then return 0; fi
  report_fail "$name: $what"
  return 1
}

report_fail() {
  failed=$((failed + 1))
  echo "FAIL $1"
  sed 's/^/    /' "$work/stdout"
}

pass() {
  passed=$((passed + 1))
  echo "ok   $1"
}

output() { grep "^$1=" "$work/output" | cut -d= -f2-; }
requests() { wc -l <"$work/requests.log" | tr -d ' '; }

t='publishes an update'
start_server published
run "$t" 0 INPUT_CHANGELOGS='Fixed a bug' &&
  check "$t" 'result output' test "$(output result)" = published &&
  check "$t" 'plugin id lowercased' test "$(output plugin-id)" = test.plugin &&
  check "$t" 'version output' test "$(output version)" = 1.2.3 &&
  check "$t" 'bearer header' grep -q "\"auth\":\"Bearer $key\"" "$work/requests.log" &&
  check "$t" 'changelogs sent' grep -q 'Fixed a bug' "$work/requests.log" &&
  check "$t" 'used PUT' grep -q '"method":"PUT"' "$work/requests.log" &&
  pass "$t"

t='reports updates held for review'
start_server review
run "$t" 0 && check "$t" 'result output' test "$(output result)" = review && pass "$t"

t='submits a missing plugin when create-if-missing is true'
start_server missing
run "$t" 0 INPUT_CREATE_IF_MISSING=true &&
  check "$t" 'result output' test "$(output result)" = submitted &&
  check "$t" 'PUT then POST' test "$(requests)" = 2 &&
  check "$t" 'used POST' grep -q '"method":"POST"' "$work/requests.log" &&
  pass "$t"

t='shows server warnings as GitHub warnings'
start_server missingFullKey
run "$t" 0 INPUT_CREATE_IF_MISSING=true &&
  check "$t" 'warning annotation' grep -q '::warning title=Acode publish::This API key already covers 100 plugins' "$work/stdout" &&
  pass "$t"

t='fails on a missing plugin by default and says how to fix it'
start_server missing
run "$t" 1 &&
  check "$t" 'no POST' test "$(requests)" = 1 &&
  check "$t" 'hint' grep -q 'create-if-missing: true' "$work/stdout" &&
  pass "$t"

t='does not fall back to POST for other 403s'
start_server denied
run "$t" 1 INPUT_CREATE_IF_MISSING=true &&
  check "$t" 'no POST' test "$(requests)" = 1 &&
  check "$t" 'server message' grep -q 'cannot publish' "$work/stdout" &&
  pass "$t"

t='surfaces rejected keys'
start_server invalid
run "$t" 1 && check "$t" 'server message' grep -q 'Invalid API key' "$work/stdout" && pass "$t"

t='sends changelogs starting with @ as text, not a file'
start_server published
run "$t" 0 INPUT_CHANGELOGS='@/etc/hosts' &&
  check "$t" 'literal text' grep -q '@/etc/hosts' "$work/requests.log" &&
  check "$t" 'no file contents' bash -c "! grep -q localhost '$work/requests.log'" &&
  pass "$t"

t='masks the key and never prints it otherwise'
start_server published
run "$t" 0 &&
  check "$t" 'mask command' grep -q "::add-mask::$key" "$work/stdout" &&
  check "$t" 'printed once' test "$(grep -c "$key" "$work/stdout")" = 1 &&
  pass "$t"

t='rejects a malformed key before any request'
start_server published
run "$t" 1 INPUT_API_KEY=ghp_notakey &&
  check "$t" 'no request' test "$(requests)" = 0 && pass "$t"

t='rejects plain http to a remote host'
start_server published
run "$t" 1 INPUT_API_URL=http://example.com &&
  check "$t" 'no request' test "$(requests)" = 0 && pass "$t"

t='fails clearly when the zip is missing'
start_server published
run "$t" 1 INPUT_ZIP=dist/missing.zip && check "$t" 'message' grep -q 'Plugin zip not found' "$work/stdout" && pass "$t"

t='fails clearly when plugin.json is missing from the zip'
(cd "$work" && zip -q empty.zip main.js)
run "$t" 1 INPUT_ZIP=empty.zip && check "$t" 'message' grep -q 'plugin.json is missing' "$work/stdout" && pass "$t"

echo
echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
