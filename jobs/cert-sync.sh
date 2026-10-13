#!/usr/bin/env bash
# Keep existing target inodes: Docker can bind-mount each certificate file separately.
# shellcheck disable=SC2015
set +x +v
set -euo pipefail
umask 077
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash cert-sync.sh <private-config>\nCopies a checked Caddy certificate, reloads PostgreSQL and checks its served fingerprint.\nNever restarts a container. Tries to restore previous files after a failed write, reload or TLS check.\nKeeps recovery files if restore cannot be confirmed. Fix the failed step and retry.\n'
    exit 0
fi
infra_runtime
infra_require docker openssl flock jq sha256sum cmp timeout find chown
[[ $# == 1 ]] || { infra_error 'Pass one private certificate configuration file. Use --help for the command.'; exit 2; }
unset STATE_DIR ALERT_CONFIG CERT_HOSTNAME SOURCE_CERT SOURCE_KEY SOURCE_CONTAINER CADDY_CERT_ROOT
unset TARGET_CERT TARGET_KEY CONTAINER_CERT CONTAINER_KEY DB_CONTAINER DB_USER DB_NAME
unset VERIFY_HOST VERIFY_PORT VERIFY_ATTEMPTS VERIFY_TIMEOUT_SECONDS EXPIRY_WARN_DAYS BOX_LOCK BOX_LOCK_WAIT_SECONDS DEPLOY_UID DEPLOY_GID
infra_source "$1"
for field in STATE_DIR CERT_HOSTNAME TARGET_CERT TARGET_KEY CONTAINER_CERT CONTAINER_KEY DB_CONTAINER; do
    [[ -n ${!field:-} ]] || { infra_error "$field is missing. Set it in the private certificate configuration."; exit 1; }
done
[[ $CERT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $CERT_HOSTNAME != *..* ]] || { infra_error 'CERT_HOSTNAME must be a hostname without a scheme or path. Fix the certificate configuration.'; exit 1; }
infra_name "$DB_CONTAINER" || { infra_error 'DB_CONTAINER is not a safe container name. Fix the certificate configuration.'; exit 1; }
DB_USER=${DB_USER:-postgres} DB_NAME=${DB_NAME:-postgres}
infra_name "$DB_USER" && infra_name "$DB_NAME" || { infra_error 'DB_USER and DB_NAME must be plain database names. Fix the certificate configuration.'; exit 1; }
VERIFY_HOST=${VERIFY_HOST:-127.0.0.1} VERIFY_PORT=${VERIFY_PORT:-5432}
[[ $VERIFY_HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $VERIFY_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( VERIFY_PORT <= 65535 )) || { infra_error 'Set VERIFY_HOST to an IPv4 address or hostname and VERIFY_PORT to 1 to 65535. Use the direct PostgreSQL port, not a pooler.'; exit 1; }
VERIFY_ATTEMPTS=${VERIFY_ATTEMPTS:-5} VERIFY_TIMEOUT_SECONDS=${VERIFY_TIMEOUT_SECONDS:-10}
EXPIRY_WARN_DAYS=${EXPIRY_WARN_DAYS:-14} BOX_LOCK_WAIT_SECONDS=${BOX_LOCK_WAIT_SECONDS:-900}
for field in VERIFY_ATTEMPTS VERIFY_TIMEOUT_SECONDS EXPIRY_WARN_DAYS BOX_LOCK_WAIT_SECONDS; do
    infra_uint "${!field}" || { infra_error "$field must be a positive integer of at most seven digits. Fix the certificate configuration."; exit 1; }
done
(( VERIFY_ATTEMPTS <= 30 && VERIFY_TIMEOUT_SECONDS <= 60 && EXPIRY_WARN_DAYS <= 3650 && BOX_LOCK_WAIT_SECONDS <= 3600 )) || { infra_error 'Certificate retry limits are too large. Use at most 30 attempts, 60 seconds per probe, 3650 warning days and 3600 lock-wait seconds.'; exit 1; }
for field in TARGET_CERT TARGET_KEY CONTAINER_CERT CONTAINER_KEY; do
    infra_absolute "${!field}" || { infra_error "$field must be a clean absolute file path. Fix the certificate configuration."; exit 1; }
done
[[ $TARGET_CERT != "$TARGET_KEY" && $CONTAINER_CERT != "$CONTAINER_KEY" ]] || { infra_error 'Certificate and key paths must be different on the host and in the container. Fix the certificate configuration.'; exit 1; }
if [[ -n ${DEPLOY_UID:-}${DEPLOY_GID:-} ]]; then
    for field in DEPLOY_UID DEPLOY_GID; do
        [[ ${!field:-} =~ ^(0|[1-9][0-9]{0,9})$ ]] && (( ${!field} <= 4294967294 )) || { infra_error "$field must be a numeric UID or GID from 0 to 4294967294. Check the deployment account and set both IDs."; exit 1; }
    done
fi
# This exception is local to verified certificate targets and the shared lock.
# Config and STATE_DIR still use the unchanged, stricter shared validators.
deployment_access() {
    local file_uid=$1 file_gid=$2 file_mode=$3
    [[ $file_mode =~ ^[0-7]{1,4}$ ]] || return 1
    { [[ $file_uid == 0 || $file_uid == "$EUID" ]] && (( (8#$file_mode & 0022) == 0 )); } ||
        { [[ -n ${DEPLOY_UID:-} && $file_uid == "$DEPLOY_UID" && $file_gid == "$DEPLOY_GID" ]] && (( (8#$file_mode & 0002) == 0 )); }
}
certificate_ancestors() {
    local cursor=$1 kind=$2 service_root=${3:-} metadata file_type file_uid file_gid file_mode
    while :; do
        metadata=$(stat -c '%F %u %g %a' -- "$cursor") || return 1
        read -r file_type file_uid file_gid file_mode <<<"$metadata" || return 1
        [[ $file_type == directory && $file_mode =~ ^[0-7]{1,4}$ ]] || return 1
        if ! deployment_access "$file_uid" "$file_gid" "$file_mode"; then
            if [[ $kind == lock && $cursor == /run/lock && $file_uid == 0 && $file_gid == 0 && $file_mode == 1777 ]]; then :
            elif [[ $kind == target && -n $service_root && ( $cursor == "$service_root" || $cursor == "$service_root/"* ) && $file_uid == "$postgres_uid" && $file_gid == "$postgres_gid" ]] && (( (8#$file_mode & 0022) == 0 )); then :
            else return 1; fi
        fi
        [[ $cursor != / ]] || break
        cursor=${cursor%/*}
        cursor=${cursor:-/}
    done
}
for path in "$TARGET_CERT" "$TARGET_KEY"; do
    infra_source_path "$path" && [[ -f $path && ! -L $path && $(stat -c %h -- "$path") == 1 ]] || {
        infra_error 'A target file is missing, symlinked or hard-linked. Use existing regular files at their real paths before scheduling sync.'; exit 1;
    }
done
infra_dir "$STATE_DIR"
[[ $STATE_DIR != "${TARGET_CERT%/*}" && $STATE_DIR != "${TARGET_KEY%/*}" && $TARGET_CERT != "$STATE_DIR/"* && $TARGET_KEY != "$STATE_DIR/"* ]] || { infra_error 'Certificate targets overlap STATE_DIR. Use a separate private state directory.'; exit 1; }
infra_lock "$STATE_DIR/cert.lock"
if [[ -n ${ALERT_CONFIG:-} ]]; then infra_private "$ALERT_CONFIG"; fi
# Resolve system lock-directory aliases, but never follow a lock-file symlink.
BOX_LOCK=${BOX_LOCK:-/var/lock/box-deploy.lock}
infra_absolute "$BOX_LOCK" && [[ ! -L $BOX_LOCK ]] || { infra_error 'BOX_LOCK must be an absolute path to a regular file, not a symlink. Check the shared deployment lock and retry.'; exit 1; }
BOX_LOCK=$(readlink -m -- "$BOX_LOCK")
certificate_ancestors "${BOX_LOCK%/*}" lock || { infra_error 'A shared lock directory has an unsafe owner or write mode. Use protected deployment directories; only root-owned sticky /run/lock allows other-user write.'; exit 1; }
[[ -f $BOX_LOCK && ! -L $BOX_LOCK ]] || { infra_error 'The shared server lock is missing or unsafe. Use the existing regular deployment lock before scheduling sync.'; exit 1; }
lock_metadata=$(stat -c '%u %g %a %h %d:%i' -- "$BOX_LOCK")
read -r lock_owner lock_group lock_mode lock_links _lock_inode <<<"$lock_metadata"
[[ $lock_links == 1 ]] || { infra_error 'The shared server lock has more than one link. Inspect the deployment lock before retrying; the job will not change it.'; exit 1; }
if [[ -n ${DEPLOY_UID:-} ]]; then
    [[ $lock_owner == "$DEPLOY_UID" && $lock_group == "$DEPLOY_GID" ]] || { infra_error 'The shared server lock does not belong to DEPLOY_UID and DEPLOY_GID. Check the deployment account IDs and retry; the job will not change the lock.'; exit 1; }
fi
deployment_access "$lock_owner" "$lock_group" "$lock_mode" || { infra_error 'The shared server lock has an unexpected owner or write mode. Check and set DEPLOY_UID and DEPLOY_GID for a deployment-owned lock; other-user write is never allowed.'; exit 1; }
# Read-only open has no O_CREAT: protected_regular can reject a root create-open
# on a deployment-owned file in root's sticky /run/lock, even when the file exists.
exec 8<"$BOX_LOCK"
opened_metadata=$(stat -Lc '%u %g %a %h %d:%i' -- /dev/fd/8)
[[ $opened_metadata == "$lock_metadata" ]] || { infra_error 'The shared lock changed while it was opened. Keep the same deployment lock inode and retry; no certificate was changed.'; exit 1; }
infra_log "Waiting for the shared server lock before checking $CERT_HOSTNAME."
flock -w "$BOX_LOCK_WAIT_SECONDS" 8 || { infra_error 'Another server job holds the deploy lock. Wait for it to finish and retry; no certificate was changed.'; exit 1; }
current_lock_metadata=$(stat -c '%u %g %a %h %d:%i' -- "$BOX_LOCK")
[[ $current_lock_metadata == "$lock_metadata" ]] || { infra_error 'The shared lock changed while waiting. Keep the same deployment lock inode and retry; no certificate was changed.'; exit 1; }
BINDING=$(printf '%s\n' "$CERT_HOSTNAME" "$DB_CONTAINER" "$DB_USER" "$DB_NAME" "$TARGET_CERT" "$TARGET_KEY" "$CONTAINER_CERT" "$CONTAINER_KEY" "$VERIFY_HOST" "$VERIFY_PORT" | sha256sum)
BINDING=${BINDING%% *}
OWNER="$STATE_DIR/.cert-owner"
if [[ -e $OWNER || -L $OWNER ]]; then
    infra_private "$OWNER"
    [[ $(<"$OWNER") == "$BINDING" ]] || { infra_error 'The certificate state belongs to another target. Keep it for recovery and use a new STATE_DIR.'; exit 1; }
else
    state_contents=$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name cert.lock -print -quit) || { infra_error 'Certificate state could not be read. Check directory access and retry; existing files and proof were kept.'; exit 1; }
    [[ -z $state_contents ]] || { infra_error 'Certificate state is not empty and has no owner marker. Use a new empty STATE_DIR; existing files were kept.'; exit 1; }
    printf '%s\n' "$BINDING" | infra_atomic "$OWNER"
fi
WORK=$(mktemp -d "$STATE_DIR/.cert-check.XXXXXX")
PENDING="$STATE_DIR/pending"
STAGING="$STATE_DIR/staging"
PROOF="$STATE_DIR/last-success"
TARGETS_VERIFIED=0
command_step() {
    local label=$1; shift
    "$@" 2>"$WORK/$label.details" || { infra_error "$label failed. Check the private details in $WORK/$label.details and retry."; return 1; }
}
postgres() { docker exec "$DB_CONTAINER" psql -X --no-password -At -U "$DB_USER" -d "$DB_NAME" -c "$1"; }
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^[^=]*=//; s/://g'; }
served_matches() {
    local expected=$1 attempt actual
    for ((attempt=1; attempt<=VERIFY_ATTEMPTS; attempt++)); do
        if timeout "$VERIFY_TIMEOUT_SECONDS" openssl s_client -starttls postgres -connect "$VERIFY_HOST:$VERIFY_PORT" -servername "$CERT_HOSTNAME" -showcerts </dev/null >"$WORK/served.txt" 2>"$WORK/tls.details"; then
            awk '/-----BEGIN CERTIFICATE-----/ {copy=1} copy {print} /-----END CERTIFICATE-----/ {exit}' "$WORK/served.txt" >"$WORK/served.crt"
            if actual=$(fingerprint "$WORK/served.crt" 2>"$WORK/fingerprint.details") && [[ $actual == "$expected" ]]; then return 0; fi
        fi
        if (( attempt < VERIFY_ATTEMPTS )); then sleep 1; fi
    done
    return 1
}
reload() {
    local reply
    reply=$(command_step postgres-reload postgres 'SELECT pg_reload_conf();') || return 1
    [[ $reply == t ]] || { infra_error 'PostgreSQL refused its configuration reload. Check the database role and server log, then retry.'; return 1; }
}
restore_pending() {
    local label target uid gid mode inode extra result=0 old_fingerprint
    [[ -d $PENDING && ! -L $PENDING ]] || return 0
    infra_dir "$PENDING" || return 1
    if [[ ! -e $PENDING/ready && ! -L $PENDING/ready ]]; then
        # The checked .cert-owner binds even an interrupted pre-binding directory.
        # Without ready, the job could not have started a target write.
        if [[ -e $PENDING/binding || -L $PENDING/binding ]]; then
            infra_private "$PENDING/binding" && [[ $(<"$PENDING/binding") == "$BINDING" ]] || return 1
        fi
        rm -rf -- "$PENDING"
        return 0
    fi
    infra_private "$PENDING/binding" || return 1
    [[ $(<"$PENDING/binding") == "$BINDING" ]] || { infra_error 'A pending certificate change belongs to another target. Inspect its private state before retrying.'; return 1; }
    infra_private "$PENDING/ready" && infra_private "$PENDING/proof-existed" || return 1
    for label in cert key; do
        if [[ $label == cert ]]; then target=$TARGET_CERT; else target=$TARGET_KEY; fi
        infra_private "$PENDING/$label.old" && infra_private "$PENDING/$label.meta" || return 1
        IFS=' ' read -r uid gid mode inode extra <"$PENDING/$label.meta"
        [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $mode =~ ^[0-7]{1,4}$ && $inode =~ ^[0-9]+:[0-9]+$ && -z ${extra:-} && -f $target && ! -L $target && $(stat -c %h -- "$target") == 1 && $(stat -c '%d:%i' -- "$target") == "$inode" ]] || {
            infra_error 'A certificate target changed during sync. Keep the pending recovery files and inspect the Docker mount before retrying.'; return 1;
        }
        # Restore the saved owner before its possibly deployment-group-writable mode.
        if ! cat "$PENDING/$label.old" >"$target" || ! chown "$uid:$gid" "$target" || ! chmod "$mode" "$target"; then result=1; fi
    done
    (( result == 0 )) || { infra_error 'The previous certificate files could not be restored. Keep the pending recovery files and fix target permissions.'; return 1; }
    if [[ $(<"$PENDING/proof-existed") == yes ]]; then
        infra_private "$PENDING/proof.old" && infra_atomic "$PROOF" <"$PENDING/proof.old" || return 1
    elif [[ $(<"$PENDING/proof-existed") == no ]]; then
        [[ ! -e $PROOF && ! -L $PROOF ]] || { infra_private "$PROOF" && rm -- "$PROOF"; } || return 1
    else return 1; fi
    old_fingerprint=$(command_step old-fingerprint fingerprint "$PENDING/cert.old") || return 1
    reload && served_matches "$old_fingerprint" || { infra_error 'Previous certificate files are restored, but their served certificate was not confirmed. Check PostgreSQL and the direct verification port; recovery files were kept.'; return 1; }
    rm -rf -- "$PENDING"
    infra_log 'Previous certificate files and served fingerprint restored.'
}
finish() {
    local result=$?
    trap - EXIT INT TERM
    if (( result != 0 )); then
        if (( TARGETS_VERIFIED )); then restore_pending || result=1; fi
        infra_error "Certificate sync did not finish. Fix the reported step and retry. Private checks remain in $WORK."
        infra_alert "Certificate sync failed for $CERT_HOSTNAME" 'Certificate sync did not finish. Check the private sync log and retry. The job does not restart PostgreSQL.' || true
    else rm -rf -- "$WORK"; fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
command_step mounts docker inspect --format '{{json .Mounts}}' "$DB_CONTAINER" >"$WORK/mounts.json"
for label in cert key; do
    if [[ $label == cert ]]; then target=$TARGET_CERT; container_path=$CONTAINER_CERT; else target=$TARGET_KEY; container_path=$CONTAINER_KEY; fi
    # Pick the effective mount before checking its type: tmpfs and other shadows count.
    # Docker reports the host Source for named volumes as well as binds.
    # shellcheck disable=SC2016
    command_step mount-check jq -er --arg host "$target" --arg container "$container_path" '
        [ .[] | .Destination as $dest |
          select($dest == "/" or $container == $dest or ($container | startswith($dest + "/"))) ] |
        sort_by(.Destination | length) | .[-1].Destination as $dest |
        map(select(.Destination == $dest)) |
        if length != 1 then error("No unique effective certificate mount") else .[0] end |
        select(.Type == "bind" or .Type == "volume") |
        .Source as $source | .Destination as $dest |
        (if $container == $dest then "" elif $dest == "/" then $container else ($container | ltrimstr($dest)) end) as $suffix |
        select(($source | rtrimstr("/")) + $suffix == $host) | $source
    ' "$WORK/mounts.json" >"$WORK/mount-source.$label" || { infra_error 'The effective Docker mount does not map to a configured host target. Check the target paths and any nested mounts before retrying.'; exit 1; }
done
for label in cert key; do
    if [[ $label == cert ]]; then container_path=$CONTAINER_CERT; setting=ssl_cert_file; else container_path=$CONTAINER_KEY; setting=ssl_key_file; fi
    actual=$(command_step postgres-path postgres "SHOW $setting;")
    [[ $actual == "$container_path" ]] || { infra_error 'PostgreSQL uses a different certificate path. Check its SSL settings and the private configuration before retrying.'; exit 1; }
done
postgres_uid=$(command_step postgres-uid docker exec "$DB_CONTAINER" id -u postgres)
postgres_gid=$(command_step postgres-gid docker exec "$DB_CONTAINER" id -g postgres)
[[ $postgres_uid =~ ^[0-9]+$ && $postgres_gid =~ ^[0-9]+$ ]] || { infra_error 'PostgreSQL UID or GID was not readable. Check its container user before retrying.'; exit 1; }
for label in cert key; do
    if [[ $label == cert ]]; then target=$TARGET_CERT; else target=$TARGET_KEY; fi
    mount_source=$(<"$WORK/mount-source.$label")
    certificate_ancestors "${target%/*}" target "$mount_source" || { infra_error 'A target directory has an unsafe owner or write mode. Check DEPLOY_UID and DEPLOY_GID for deployment directories; other-user write and symlinks are never allowed.'; exit 1; }
    target_metadata=$(stat -c '%u %g %a' -- "$target")
    read -r target_owner target_group target_mode <<<"$target_metadata"
    deployment_access "$target_owner" "$target_group" "$target_mode" || {
        [[ $target_owner == "$postgres_uid" && $target_group == "$postgres_gid" && $target_mode =~ ^[0-7]{1,4}$ ]] && (( (8#$target_mode & 0022) == 0 )) || {
            infra_error 'A target file has an unsafe owner or write mode. Use root, the job user, the pinned deployment account or the verified PostgreSQL account; other-user write is never allowed.'; exit 1;
        }
    }
done
TARGETS_VERIFIED=1
# Unpublished staging cannot have changed a target. Only discard it inside this
# job-owned state directory after the .cert-owner binding has been checked.
if [[ -e $STAGING || -L $STAGING ]]; then
    [[ -d $STAGING && ! -L $STAGING ]] && infra_dir "$STAGING" || { infra_error 'Certificate staging is not a private directory. Inspect its owner and mode before retrying.'; exit 1; }
    if [[ -e $STAGING/binding || -L $STAGING/binding || -e $STAGING/ready || -L $STAGING/ready ]]; then
        infra_private "$STAGING/binding" && [[ $(<"$STAGING/binding") == "$BINDING" ]] || { infra_error 'Certificate staging has no matching target binding. Keep it and inspect the private recovery state before retrying.'; exit 1; }
    fi
    rm -rf -- "$STAGING"
fi
# Verify the effective target mapping before any recovery write too.
if [[ -e $PENDING || -L $PENDING ]]; then
    [[ -d $PENDING && ! -L $PENDING ]] || { infra_error 'Pending certificate state is not a regular directory. Inspect it before retrying.'; exit 1; }
    infra_log 'Recovering an interrupted certificate change.'
    restore_pending
fi
if [[ -n ${SOURCE_CONTAINER:-} ]]; then infra_name "$SOURCE_CONTAINER" || { infra_error 'SOURCE_CONTAINER must be a safe container name. Fix the certificate configuration.'; exit 1; }; fi
if [[ -n ${CADDY_CERT_ROOT:-} ]]; then
    [[ -z ${SOURCE_CERT:-}${SOURCE_KEY:-} ]] || { infra_error 'Use either CADDY_CERT_ROOT or SOURCE_CERT with SOURCE_KEY, not both.'; exit 1; }
    infra_absolute "$CADDY_CERT_ROOT" || { infra_error 'CADDY_CERT_ROOT must be a clean absolute directory path. Fix the certificate configuration.'; exit 1; }
    if [[ -n ${SOURCE_CONTAINER:-} ]]; then
        command_step caddy-find docker exec "$SOURCE_CONTAINER" find "$CADDY_CERT_ROOT" -type f -path "*/$CERT_HOSTNAME/$CERT_HOSTNAME.crt" -print >"$WORK/sources"
    else
        infra_source_path "$CADDY_CERT_ROOT"
        command_step caddy-find find "$CADDY_CERT_ROOT" -type f -path "*/$CERT_HOSTNAME/$CERT_HOSTNAME.crt" -print >"$WORK/sources"
    fi
    mapfile -t sources <"$WORK/sources"
    [[ ${#sources[@]} == 1 ]] || { infra_error 'Caddy has no matching certificate or more than one issuer copy. Set SOURCE_CERT and SOURCE_KEY to the intended pair, then retry.'; exit 1; }
    SOURCE_CERT=${sources[0]} SOURCE_KEY=${sources[0]%.crt}.key
fi
[[ -n ${SOURCE_CERT:-} && -n ${SOURCE_KEY:-} ]] || { infra_error 'Set SOURCE_CERT and SOURCE_KEY, or CADDY_CERT_ROOT for issuer-independent discovery.'; exit 1; }
for label in cert key; do
    if [[ $label == cert ]]; then source_path=$SOURCE_CERT; else source_path=$SOURCE_KEY; fi
    infra_absolute "$source_path" || { infra_error 'A source certificate path is not a clean absolute file path. Fix the certificate configuration.'; exit 1; }
    if [[ -n ${SOURCE_CONTAINER:-} ]]; then
        resolved=$(command_step source-path docker exec "$SOURCE_CONTAINER" readlink -f -- "$source_path")
        [[ $resolved == "$source_path" ]] && command_step source-type docker exec "$SOURCE_CONTAINER" test -f "$source_path" || { infra_error 'A source file is missing or symlinked. Set its real regular-file path.'; exit 1; }
        command_step source-copy docker cp "$SOURCE_CONTAINER:$source_path" "$WORK/source.$label"
    else
        infra_source_path "$source_path" && [[ -f $source_path && ! -L $source_path ]] || { infra_error 'A source certificate file is missing or symlinked. Set its real regular-file path.'; exit 1; }
        command_step source-copy cp -- "$source_path" "$WORK/source.$label"
    fi
    [[ -f $WORK/source.$label && ! -L $WORK/source.$label ]] || { infra_error 'The source copy is not a regular file. Inspect its source before retrying.'; exit 1; }
    chmod 600 "$WORK/source.$label"
done
# Some OpenSSL versions print a mismatch without a failing exit code.
if ! command_step certificate-host openssl x509 -in "$WORK/source.cert" -noout -checkhost "$CERT_HOSTNAME" >"$WORK/host-check" ||
    [[ $(<"$WORK/host-check") != "Hostname $CERT_HOSTNAME does match certificate" ]]; then
    infra_error 'The source certificate does not match CERT_HOSTNAME, or it could not be read. Select a valid Caddy certificate for that hostname, then retry. Target files were not changed.'
    exit 1
fi
if ! command_step certificate-expiry openssl x509 -in "$WORK/source.cert" -noout -checkend 0 >"$WORK/expiry-check"; then
    infra_error 'The source certificate has expired, or its expiry could not be read. Check Caddy renewal and select a current certificate, then retry. Target files were not changed.'
    exit 1
fi
starts=$(command_step certificate-start openssl x509 -in "$WORK/source.cert" -noout -startdate)
starts=$(date -d "${starts#notBefore=}" +%s)
(( starts <= $(date +%s) )) || { infra_error 'The source certificate is not valid yet. Check the server clock and Caddy renewal before retrying.'; exit 1; }
command_step certificate-public openssl x509 -in "$WORK/source.cert" -pubkey -noout | command_step certificate-der openssl pkey -pubin -outform DER >"$WORK/cert.pub"
command_step key-public openssl pkey -in "$WORK/source.key" -passin pass: -pubout -outform DER >"$WORK/key.pub"
cmp -s "$WORK/cert.pub" "$WORK/key.pub" || { infra_error 'The source certificate and private key do not match. Select one Caddy pair and retry; target files were not changed.'; exit 1; }
EXPECTED=$(command_step source-fingerprint fingerprint "$WORK/source.cert")
[[ $EXPECTED =~ ^[0-9A-Fa-f]{64}$ ]] || { infra_error 'The source certificate fingerprint is invalid. Check the certificate file and OpenSSL before retrying.'; exit 1; }
# Publish only a complete rollback directory before the first in-place write.
mkdir -m 700 "$STAGING"
printf '%s\n' "$BINDING" | infra_atomic "$STAGING/binding"
for label in cert key; do
    if [[ $label == cert ]]; then target=$TARGET_CERT; else target=$TARGET_KEY; fi
    cp -- "$target" "$STAGING/$label.old"
    chmod 600 "$STAGING/$label.old"
    stat -c '%u %g %a %d:%i' -- "$target" >"$STAGING/$label.meta"
done
if [[ -e $PROOF || -L $PROOF ]]; then
    infra_private "$PROOF"
    cp -- "$PROOF" "$STAGING/proof.old"
    chmod 600 "$STAGING/proof.old"
    printf 'yes\n' >"$STAGING/proof-existed"
else printf 'no\n' >"$STAGING/proof-existed"; fi
printf 'ready\n' | infra_atomic "$STAGING/ready"
mv -T -- "$STAGING" "$PENDING"
infra_log "Installing the checked certificate for $CERT_HOSTNAME without replacing target inodes."
for label in cert key; do
    if [[ $label == cert ]]; then target=$TARGET_CERT; mode=644; else target=$TARGET_KEY; mode=600; fi
    # An atomic rename would leave a single-file Docker bind attached to the old inode.
    # PostgreSQL keeps its old SSL context until the reload; rollback also writes in place.
    cat "$WORK/source.$label" >"$target"
    # Restrict write access before PostgreSQL ownership so a killed job stays recoverable.
    chmod "$mode" "$target"
    chown "$postgres_uid:$postgres_gid" "$target"
    IFS=' ' read -r _uid _gid _mode inode <"$PENDING/$label.meta"
    [[ $(stat -c '%d:%i' -- "$target") == "$inode" ]] || { infra_error 'A target inode changed during installation. Inspect the Docker bind mount; recovery files were kept.'; exit 1; }
done
infra_log 'Reloading PostgreSQL and checking the certificate on its direct TLS port.'
reload
served_matches "$EXPECTED" || { infra_error 'PostgreSQL still serves a different certificate, or its TLS port could not be read. Check its SSL log and VERIFY_HOST/VERIFY_PORT. The job will try to restore the old files. Keep recovery data and retry after fixing the failed step.'; exit 1; }
printf 'infrakit-cert-v1\n%s\n%s\n%s\n' "$BINDING" "$EXPECTED" "$(date +%s)" | infra_atomic "$PROOF"
rm -rf -- "$PENDING"
infra_log "Certificate sync verified for $CERT_HOSTNAME. PostgreSQL was not restarted."
if ! openssl x509 -in "$WORK/source.cert" -noout -checkend "$((EXPIRY_WARN_DAYS * 86400))" >"$WORK/expiry-warning" 2>"$WORK/expiry-warning.details"; then
    expiry=$(command_step certificate-end openssl x509 -in "$WORK/source.cert" -noout -enddate)
    [[ -n ${ALERT_CONFIG:-} ]] || { infra_error "The certificate expires within $EXPIRY_WARN_DAYS days, and alert mail is not configured. Set ALERT_CONFIG and check Caddy renewal."; exit 1; }
    infra_alert "Certificate expires soon for $CERT_HOSTNAME" "The certificate expires at ${expiry#notAfter=}. Check Caddy renewal and run certificate sync again."
fi
