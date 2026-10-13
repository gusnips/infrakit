#!/usr/bin/env bash
# Local curl stand-in only. No monitor receives a request.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "$ROOT/tests/.heartbeat-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
export TEST_WORK=$WORK
export PATH="$WORK/bin:$PATH"
fail() { printf 'heartbeat check failed: %s\n' "$*" >&2; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "Expected $2 in ${1##*/}"; }
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && $1 == -q && $2 == --config ]] || exit 90
[[ $(stat -c %a -- "$3") == 600 && $(stat -c %a -- "${3%/*}") == 700 ]] || exit 91
printf '%s\n' "$@" >"$TEST_WORK/curl.argv"
cp -- "$3" "$TEST_WORK/curl.conf"
printf '%s' "${TEST_HTTP_STATUS:-200}"
SH
chmod 700 "$WORK/bin/curl"
run_job() {
    local result=0
    bash "$ROOT/jobs/heartbeat.sh" "$WORK/heartbeat.conf" "$2" >"$WORK/stdout" 2>"$WORK/stderr" || result=$?
    if [[ $1 == pass ]]; then
        (( result == 0 )) || { cat "$WORK/stderr" >&2; fail 'Heartbeat should pass'; }
        contains "$WORK/stdout" "Heartbeat $2 sent."
    else
        (( result != 0 )) || fail 'Heartbeat should fail closed'
    fi
}
for event in start fail success; do
    case $event in start) field=HEARTBEAT_START_URL ;; fail) field=HEARTBEAT_FAIL_URL ;; success) field=HEARTBEAT_SUCCESS_URL ;; esac
    for url in https://monitor.example https://monitor.example:443 https://monitor.example/ https://monitor.example/check-id; do
        printf '%s=%q\n' "$field" "$url" >"$WORK/heartbeat.conf"
        run_job pass "$event"
        contains "$WORK/curl.conf" "url = \"$url\""
        contains "$WORK/curl.conf" 'proto = "=https"'
        if grep -F location "$WORK/curl.conf" >/dev/null; then fail 'Heartbeat follows redirects'; fi
        if grep -F "$url" "$WORK/curl.argv" >/dev/null; then fail 'URL entered command arguments'; fi
    done
    for url in \
        http://monitor.example/ file:///etc/passwd https://user:pass@monitor.example/ \
        'https://monitor.example/a"b' 'https://monitor.example/a\b' \
        'https://monitor.example/a b' $'https://monitor.example/a\nb' \
        $'https://monitor.example/a\rb' $'https://monitor.example/a\tb' \
        $'https://monitor.example/a\177b' 'https://monitor.example"' "https://monitor.example\\"; do
        printf '%s=%q\n' "$field" "$url" >"$WORK/heartbeat.conf"
        rm -f -- "$WORK/curl.conf" "$WORK/curl.argv"
        run_job fail "$event"
        [[ ! -e $WORK/curl.conf && ! -e $WORK/curl.argv ]] || fail 'Unsafe URL reached curl'
        contains "$WORK/stderr" 'Fix the private file and retry'
    done
done
printf 'HEARTBEAT_SUCCESS_URL=https://monitor.example\n' >"$WORK/heartbeat.conf"
TEST_HTTP_STATUS=302 run_job fail success
contains "$WORK/stderr" 'Set its final HTTPS URL and retry'
# The default event also accepts a slashless root URL.
bash "$ROOT/jobs/heartbeat.sh" "$WORK/heartbeat.conf" >"$WORK/stdout" 2>"$WORK/stderr"
contains "$WORK/stdout" 'Heartbeat success sent.'
# Config escaping is independent of URL validation and still handles both characters.
# shellcheck source=../jobs/lib.sh
source "$ROOT/jobs/lib.sh"
[[ $(infra_curl_field url 'https://monitor.example/a"b\c') == 'url = "https://monitor.example/a\"b\\c"' ]] || fail 'Curl config escaping changed'
# D1 keeps its separate host/path check after the shared HTTPS guard.
# shellcheck disable=SC2016
contains "$ROOT/jobs/backup.sh" 'infra_https "$url" && [[ $url =~ ^https://([A-Za-z0-9.-]+)/ ]]'
printf 'heartbeat checks passed\n'
