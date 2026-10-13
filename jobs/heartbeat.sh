#!/usr/bin/env bash
set +x +v
set -euo pipefail
umask 077
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash heartbeat.sh <private-config> [start|fail|success]\nDefault: success. Each event needs its own HTTPS URL in the private file.\n'
    exit 0
fi
infra_runtime
[[ $# == 1 || $# == 2 ]] || { infra_error 'Pass a private heartbeat configuration file. Use --help for the event names.'; exit 2; }
CONF=$1
EVENT=${2:-success}
case $EVENT in start) FIELD=HEARTBEAT_START_URL ;; fail) FIELD=HEARTBEAT_FAIL_URL ;; success) FIELD=HEARTBEAT_SUCCESS_URL ;; *) infra_error 'Unknown heartbeat event. Use start, fail or success.'; exit 2 ;; esac
unset HEARTBEAT_START_URL HEARTBEAT_FAIL_URL HEARTBEAT_SUCCESS_URL
BACKUP_STATE_DIRS=() BACKUP_MAX_AGE_SECONDS=()
infra_source "$CONF"
[[ -n ${!FIELD:-} ]] || { infra_error "Heartbeat $EVENT is not configured. Set $FIELD in the private file."; exit 1; }
STALE=0
if [[ $EVENT == success ]]; then
    [[ ${#BACKUP_STATE_DIRS[@]} == "${#BACKUP_MAX_AGE_SECONDS[@]}" ]] || { infra_error 'Backup heartbeat arrays have different lengths. Give each BACKUP_STATE_DIRS entry one BACKUP_MAX_AGE_SECONDS value.'; exit 1; }
    for ((index=0; index<${#BACKUP_STATE_DIRS[@]}; index++)); do
        if ! infra_backup_fresh "${BACKUP_STATE_DIRS[index]}" "${BACKUP_MAX_AGE_SECONDS[index]}"; then
            infra_error "Required backup $((index + 1)) has no usable recent proof. Run that backup and check its private diagnostics."
            STALE=1
        fi
    done
    if (( STALE )); then
        EVENT=fail FIELD=HEARTBEAT_FAIL_URL
        [[ -n ${!FIELD:-} ]] || { infra_error 'The host is not healthy, and its failure heartbeat is not configured. Set HEARTBEAT_FAIL_URL.'; exit 1; }
    fi
fi
infra_https "${!FIELD}" || { infra_error 'The heartbeat URL is not a valid HTTPS address. Fix the private file and retry.'; exit 1; }
WORK=$(mktemp -d "${CONF%/*}/.infra-ping.XXXXXX")
{
    printf 'silent\nshow-error\nfail\nproto = "=https"\nconnect-timeout = 10\nmax-time = 20\noutput = "/dev/null"\nwrite-out = "%%{http_code}"\n'
    infra_curl_field url "${!FIELD}"
} >"$WORK/curl.conf"
infra_curl "$WORK/curl.conf" "$WORK/response" "$WORK/details" || exit 1
[[ $(<"$WORK/response") =~ ^2[0-9][0-9]$ ]] || {
    infra_error "The monitor did not accept this ping. Set its final HTTPS URL and retry; private response details are in $WORK."
    exit 1
}
rm -rf -- "$WORK"
infra_log "Heartbeat $EVENT sent."
(( STALE == 0 ))
