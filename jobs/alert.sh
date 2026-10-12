#!/usr/bin/env bash
# Values are loaded indirectly from private configuration; validation chains fail closed.
# shellcheck disable=SC2015,SC2153
set +x +v
set -euo pipefail
umask 077
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: ALERT_CONFIG=/private/alert.conf bash alert.sh [--test] <subject>\nRead the message from stdin. --test labels a setup test.\n'
    exit 0
fi
infra_runtime
TEST=0
if [[ ${1:-} == --test ]]; then TEST=1; shift; fi
[[ $# == 1 ]] || { infra_error 'Pass one subject and the message on stdin. Use --help for an example.'; exit 2; }
SUBJECT=$1
infra_single_line "$SUBJECT" || { infra_error 'The mail subject is empty or contains a control character. Use one line of text.'; exit 2; }
[[ -n ${ALERT_CONFIG:-} ]] || { infra_error 'Alert mail is not configured. Set ALERT_CONFIG to a private SMTP configuration file.'; exit 1; }
CONF=$ALERT_CONFIG
unset SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM SMTP_TO SMTP_TRANSPORT
SMTP_TO=()
infra_source "$CONF"
for field in SMTP_HOST SMTP_USER SMTP_PASS SMTP_FROM; do
    infra_single_line "${!field:-}" || { infra_error "Mail is missing a valid $field. Set it in ALERT_CONFIG and retry."; exit 1; }
done
[[ $SMTP_USER != *:* ]] || { infra_error 'SMTP_USER contains a colon. Use the provider login name without a password.'; exit 1; }
[[ $SMTP_HOST =~ ^[A-Za-z0-9.-]+$ ]] || { infra_error 'SMTP_HOST must be a hostname without a scheme or path. Fix ALERT_CONFIG.'; exit 1; }
[[ $SMTP_FROM =~ ^[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+$ && ${#SMTP_TO[@]} -gt 0 ]] || {
    infra_error 'Set a bare SMTP_FROM address and a nonempty SMTP_TO array in ALERT_CONFIG.'; exit 1;
}
SMTP_PORT=${SMTP_PORT:-587}
[[ $SMTP_PORT =~ ^[0-9]{1,5}$ ]] && (( 10#$SMTP_PORT >= 1 && 10#$SMTP_PORT <= 65535 )) || { infra_error 'SMTP_PORT must be 1 to 65535. Fix ALERT_CONFIG.'; exit 1; }
case ${SMTP_TRANSPORT:-starttls} in
    starttls) SCHEME=smtp ;;
    tls) SCHEME=smtps ;;
    *) infra_error 'SMTP_TRANSPORT must be starttls or tls. Fix ALERT_CONFIG.'; exit 1 ;;
esac
for recipient in "${SMTP_TO[@]}"; do
    [[ $recipient =~ ^[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+$ ]] || { infra_error 'SMTP_TO contains an invalid address. Use bare email addresses in the array.'; exit 1; }
done
WORK=$(mktemp -d "${CONF%/*}/.infra-mail.XXXXXX")
if (( TEST )); then SUBJECT="[Setup test] $SUBJECT"; fi
{
    printf 'From: %s\r\nTo: ' "$SMTP_FROM"
    separator=''
    for recipient in "${SMTP_TO[@]}"; do printf '%s%s' "$separator" "$recipient"; separator=', '; done
    printf '\r\nSubject: %s\r\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n'
    cat
} >"$WORK/message"
{
    printf 'silent\nshow-error\nssl-reqd\nconnect-timeout = 10\nmax-time = 30\n'
    infra_curl_field url "$SCHEME://$SMTP_HOST:$SMTP_PORT"
    infra_curl_field user "$SMTP_USER:$SMTP_PASS"
    infra_curl_field mail-from "$SMTP_FROM"
    for recipient in "${SMTP_TO[@]}"; do infra_curl_field mail-rcpt "$recipient"; done
    infra_curl_field upload-file "$WORK/message"
} >"$WORK/curl.conf"
infra_curl "$WORK/curl.conf" "$WORK/response" "$WORK/details" || exit 1
# Only this generated directory is removed; failed requests keep private diagnostics.
rm -rf -- "$WORK"
infra_log 'Alert mail sent.'
