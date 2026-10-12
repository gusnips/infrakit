#!/usr/bin/env bash
# Validation chains fail when any condition fails.
# shellcheck disable=SC2015
set +x +v
set -euo pipefail
umask 077
export LC_ALL=C
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash backup.sh <private-job-file>\nProfiles: supabase-docker, postgres-docker, hosted-postgres, files, d1.\nA run encrypts and checks every offsite object before recording success or pruning.\nSee README.md for the private configuration fields.\n'
    exit 0
fi
infra_runtime
infra_require age rclone flock sha256sum tar gzip cmp sort find timeout comm
[[ $# == 1 ]] || { infra_error 'Pass one private job file. Use --help for the profile names.'; exit 2; }
JOB_FILE=$1
# These values must come from the job, never from an unrelated cron environment.
unset JOB_ID PROFILE ARCHIVE_DIR STATE_DIR R2_ENV REMOTE_PREFIX BACKUP_AGE_RECIPIENT
unset CONTAINER DB_USER GLOBALS_USER PG_SERVICE PG_SERVICE_FILE PG_PASS_FILE HOSTED_EXPORT_SCOPE
unset D1_ENV D1_DOWNLOAD_HOSTS REDIS_CONFIG REDIS_PASSWORD_FILE REDIS_PORT REDIS_RDB REDIS_SOCKET REDIS_CONTAINER REDIS_WAIT_SECONDS D1_TIMEOUT_SECONDS
unset ALERT_CONFIG HEARTBEAT_CONFIG LOCAL_REMOTE_DIR LOCAL_KEEP_DAYS REMOTE_KEEP_DAYS
BACKEND=r2
DB_NAMES=(); DUMP_ARGS=(); CONFIG_PATHS=(); CONTAINER_CONFIG_PATHS=(); STORAGE_PATHS=(); D1_DOWNLOAD_HOSTS=()
infra_source "$JOB_FILE"
for field in DB_NAMES DUMP_ARGS CONFIG_PATHS CONTAINER_CONFIG_PATHS STORAGE_PATHS D1_DOWNLOAD_HOSTS; do
    [[ $(declare -p "$field") == 'declare -a '* ]] || { infra_error "$field must be an indexed Bash array. Use parentheses in the job file."; exit 1; }
done
for field in JOB_ID PROFILE ARCHIVE_DIR STATE_DIR REMOTE_PREFIX BACKUP_AGE_RECIPIENT; do
    [[ -n ${!field:-} ]] || { infra_error "$field is missing. Set it in the job file and retry."; exit 1; }
done
infra_name "$JOB_ID" || { infra_error 'JOB_ID must use letters, digits, dots, underscores or hyphens, with no .. and at most 63 characters.'; exit 1; }
infra_prefix "$REMOTE_PREFIX" || {
    infra_error 'REMOTE_PREFIX must be a nonempty path below the bucket, using letters, digits, dots, slashes, underscores or hyphens. Remove dot segments, empty segments and trailing slashes.'; exit 1;
}
infra_single_line "$BACKUP_AGE_RECIPIENT" || { infra_error 'BACKUP_AGE_RECIPIENT is invalid. Set one public age recipient.'; exit 1; }
LOCAL_KEEP_DAYS=${LOCAL_KEEP_DAYS:-7}
REMOTE_KEEP_DAYS=${REMOTE_KEEP_DAYS:-30}
for field in LOCAL_KEEP_DAYS REMOTE_KEEP_DAYS; do
    [[ ${!field} =~ ^[1-9][0-9]{0,4}$ ]] && (( ${!field} <= 36500 )) || { infra_error "$field must be 1 to 36500 days. Fix the job file."; exit 1; }
done
for directory in "$ARCHIVE_DIR" "$STATE_DIR"; do
    case $directory in /root|/home|/var|/var/lib|/var/backups|/etc|/usr|/opt|/srv|/Users) infra_error 'A job directory is a shared system root. Choose a dedicated subdirectory.'; exit 1 ;; esac
    infra_dir "$directory"
done
[[ $ARCHIVE_DIR != "$STATE_DIR" && $ARCHIVE_DIR != "$STATE_DIR/"* && $STATE_DIR != "$ARCHIVE_DIR/"* ]] || {
    infra_error 'ARCHIVE_DIR and STATE_DIR overlap. Use separate directories.'; exit 1;
}
infra_lock "$STATE_DIR/job.lock"
RUN=''; VERIFIED=0; NOTIFY_FAILURE=0
finish() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        if [[ -n $RUN && $VERIFIED == 0 ]]; then printf 'This run did not finish. Fix the failed step and run a new snapshot.\n' >"$RUN/INCOMPLETE"; fi
        infra_error "Job $JOB_ID did not finish. Fix the reported step and retry; local artifacts remain${RUN:+ in $RUN}."
        infra_alert "Backup job $JOB_ID failed" "Backup job $JOB_ID did not finish. Read its private local log and fix the reported step before retrying. No older snapshot is pruned before a verified new copy." || true
        infra_heartbeat fail || true
    fi
    exit "$result"
}
trap finish EXIT
for field in ALERT_CONFIG HEARTBEAT_CONFIG; do
    [[ -z ${!field:-} ]] || infra_private "${!field}"
done

# Configure rclone through its environment. No credential appears in argv.
for field in ${!RCLONE_@}; do unset "$field"; done
export RCLONE_CONFIG=/dev/null
RCLONE_UP=(--transfers 1 --checkers 1)
case $BACKEND in
    r2)
        [[ $EUID == 0 && $(stat -c %u -- "$JOB_FILE") == 0 ]] || { infra_error 'R2 jobs must run as root with a root-owned job file. Fix the owner and run with sudo.'; exit 1; }
        [[ -n ${R2_ENV:-} ]] || { infra_error 'R2_ENV is missing. Point it at a root-owned private R2 file.'; exit 1; }
        unset R2_ACCOUNT_ID R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
        infra_source "$R2_ENV"
        [[ $(stat -c %u -- "$R2_ENV") == 0 ]] || { infra_error 'R2_ENV is not root-owned. Fix its owner before retrying.'; exit 1; }
        for field in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
            infra_single_line "${!field:-}" || { infra_error "$field is missing or invalid. Fix R2_ENV and retry."; exit 1; }
        done
        [[ $R2_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { infra_error 'R2_BUCKET must be a bucket name, not a path. Fix R2_ENV.'; exit 1; }
        if [[ -z ${R2_ENDPOINT:-} ]]; then
            [[ ${R2_ACCOUNT_ID:-} =~ ^[a-fA-F0-9]{32}$ ]] || { infra_error 'Set a valid R2_ACCOUNT_ID or HTTPS R2_ENDPOINT in R2_ENV.'; exit 1; }
            R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
        fi
        [[ $R2_ENDPOINT =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || { infra_error 'R2_ENDPOINT must be a bare HTTPS origin without credentials. Fix R2_ENV.'; exit 1; }
        export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Cloudflare
        export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
        export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
        export RCLONE_CONFIG_BACKUP_ENDPOINT="$R2_ENDPOINT" RCLONE_CONFIG_BACKUP_ACL=private
        REMOTE_ROOT="backup:$R2_BUCKET/$REMOTE_PREFIX"
        RCLONE_UP+=(--s3-no-check-bucket --s3-no-head --s3-chunk-size 5M --s3-upload-concurrency 1)
        ;;
    local)
        [[ -n ${LOCAL_REMOTE_DIR:-} ]] || { infra_error 'The local test backend needs LOCAL_REMOTE_DIR. Use a dedicated private directory.'; exit 1; }
        infra_dir "$LOCAL_REMOTE_DIR"
        [[ $LOCAL_REMOTE_DIR != "$ARCHIVE_DIR" && $LOCAL_REMOTE_DIR != "$STATE_DIR" && $LOCAL_REMOTE_DIR != "$ARCHIVE_DIR/"* && $LOCAL_REMOTE_DIR != "$STATE_DIR/"* && $ARCHIVE_DIR != "$LOCAL_REMOTE_DIR/"* && $STATE_DIR != "$LOCAL_REMOTE_DIR/"* ]] || {
            infra_error 'The local remote overlaps a job directory. Use a separate directory.'; exit 1;
        }
        export RCLONE_CONFIG_BACKUP_TYPE=local
        REMOTE_ROOT="backup:$LOCAL_REMOTE_DIR/$REMOTE_PREFIX"
        ;;
    *) infra_error 'BACKEND must be r2 or local. Local is only for isolated checks.'; exit 1 ;;
esac
OWNER=$(printf 'infrakit-owner-v1\n%s\n%s\n%s\n' "$JOB_ID" "$ARCHIVE_DIR" "$REMOTE_ROOT")
for directory in "$ARCHIVE_DIR" "$STATE_DIR"; do
    if [[ -e $directory/.infrakit-owner || -L $directory/.infrakit-owner ]]; then
        infra_private "$directory/.infrakit-owner"
        [[ $(<"$directory/.infrakit-owner") == "$OWNER" ]] || { infra_error 'A job directory belongs to another job or remote. Use a new directory; do not replace its ownership marker.'; exit 1; }
    else
        # Adopt only empty directories (apart from the lock just opened). Never claim old files.
        entry=$(find "$directory" -mindepth 1 -maxdepth 1 ! -name job.lock -print -quit 2>/dev/null) || {
            infra_error 'A job directory could not be read. Check its access and retry; its ownership marker was not written.'; exit 1;
        }
        if [[ -n $entry ]]; then
            infra_error 'A job directory is not empty and has no ownership marker. Choose a new empty directory.'; exit 1
        fi
        printf '%s\n' "$OWNER" | infra_atomic "$directory/.infrakit-owner"
    fi
done
infra_dir "$STATE_DIR/receipts"
STARTED=$(date +%s)
RUN=$(mktemp -d "$ARCHIVE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
SNAPSHOT=${RUN##*/}
infra_snapshot_name "$SNAPSHOT" || { infra_error 'Snapshot naming failed. Check GNU mktemp and retry.'; exit 1; }
[[ ! -e $STATE_DIR/receipts/$SNAPSHOT && ! -L $STATE_DIR/receipts/$SNAPSHOT ]] || { infra_error 'The snapshot name has a saved receipt. Run again to choose a new name; no receipt was replaced.'; exit 1; }
REMOTE="$REMOTE_ROOT/$SNAPSHOT"
mkdir -m 700 "$RUN/plain" "$RUN/sealed" "$RUN/details"
infra_log "Job $JOB_ID started: $SNAPSHOT."
VERSION=$(rclone version 2>"$RUN/details/rclone-version" | sed -n '1s/^rclone v\([0-9][0-9.]*\).*/\1/p')
[[ -n $VERSION && $(printf '%s\n' 1.75.2 "$VERSION" | sort -V | head -1) == 1.75.2 ]] || { infra_error 'rclone 1.75.2 or newer is required. Install it and retry.'; exit 1; }
infra_heartbeat start || NOTIFY_FAILURE=1

step() { # step <safe diagnostic name> <command...>, stdout belongs to the caller
    local label=$1; shift
    "$@" 2>"$RUN/details/$label" || { infra_error "$label failed. Check the private details in $RUN/details/$label and retry."; return 1; }
}
INCOMPLETE=0
artifact_failed() { INCOMPLETE=1; infra_error "$1 was not collected. Fix its source and run a new snapshot."; }
# Arguments are deliberately limited to exclusions. An output/connection/password flag must
# never redirect a dump or override the private libpq service.
for argument in "${DUMP_ARGS[@]}"; do
    case $argument in --exclude-table=*|--exclude-table-data=*) infra_single_line "$argument" || exit 1 ;; *) infra_error 'DUMP_ARGS only accepts --exclude-table= and --exclude-table-data=. Keep connection and output settings in the profile.'; exit 1 ;; esac
done
collect_docker() {
    local database index=0 destination
    infra_require docker || return 1
    [[ -n ${CONTAINER:-} && -n ${DB_USER:-} && ${#DB_NAMES[@]} -gt 0 ]] && infra_name "$CONTAINER" && infra_name "$DB_USER" || {
        infra_error 'The Docker profile needs CONTAINER, DB_USER and a nonempty DB_NAMES array.'; return 1;
    }
    if [[ $PROFILE == supabase-docker ]]; then
        [[ " ${DB_NAMES[*]} " == *' postgres '* && " ${DB_NAMES[*]} " == *' _supabase '* && ( ${#CONFIG_PATHS[@]} -gt 0 || ${#CONTAINER_CONFIG_PATHS[@]} -gt 0 ) ]] || {
            infra_error 'The Supabase profile needs postgres and _supabase in DB_NAMES, plus init files and the pgsodium key in CONFIG_PATHS or CONTAINER_CONFIG_PATHS.'; return 1;
        }
    fi
    GLOBALS_USER=${GLOBALS_USER:-$DB_USER}
    infra_name "$GLOBALS_USER" || return 1
    if step globals docker exec "$CONTAINER" pg_dumpall --no-password -U "$GLOBALS_USER" --globals-only >"$RUN/globals.partial.sql" &&
        [[ -s $RUN/globals.partial.sql ]] && grep -q '^-- PostgreSQL database cluster dump complete' "$RUN/globals.partial.sql" &&
        step globals-gzip gzip -c "$RUN/globals.partial.sql" >"$RUN/plain/globals.sql.gz.partial" &&
        mv "$RUN/plain/globals.sql.gz.partial" "$RUN/plain/globals.sql.gz"; then
        :
    else artifact_failed 'PostgreSQL globals'; fi
    for database in "${DB_NAMES[@]}"; do
        index=$((index + 1)); destination=$(printf '%s/plain/db-%03d.dump' "$RUN" "$index")
        if ! infra_name "$database"; then artifact_failed "Database $index has an unsafe name"; continue; fi
        if step "db-$index" docker exec "$CONTAINER" pg_dump --no-password -U "$DB_USER" -Fc "${DUMP_ARGS[@]}" -- "$database" >"$destination.partial" &&
            [[ -s $destination.partial ]] && step "db-$index-list" docker exec -i "$CONTAINER" pg_restore --list <"$destination.partial" >"$RUN/details/db-$index-list.txt" &&
            mv "$destination.partial" "$destination"; then
            :
        else artifact_failed "PostgreSQL database $index"; fi
    done
}
collect_hosted() {
    infra_require pg_dump pg_restore || return 1
    [[ -n ${PG_SERVICE:-} && -n ${PG_SERVICE_FILE:-} && -n ${PG_PASS_FILE:-} && -n ${HOSTED_EXPORT_SCOPE:-} ]] && infra_name "$PG_SERVICE" && infra_single_line "$HOSTED_EXPORT_SCOPE" || {
        infra_error 'The hosted profile needs PG_SERVICE, PG_SERVICE_FILE, PG_PASS_FILE and HOSTED_EXPORT_SCOPE. Document what the available role can export.'; return 1;
    }
    infra_private "$PG_SERVICE_FILE" && infra_private "$PG_PASS_FILE" || return 1
    (
        # A cron environment must not override the private service's connection settings.
        for field in ${!PG@}; do
            case $field in PG_SERVICE|PG_SERVICE_FILE|PG_PASS_FILE) ;; *) unset "$field" ;; esac
        done
        export PGSERVICE="$PG_SERVICE" PGSERVICEFILE="$PG_SERVICE_FILE" PGPASSFILE="$PG_PASS_FILE" PGCONNECT_TIMEOUT=15
        step hosted-dump pg_dump --no-password -Fc "${DUMP_ARGS[@]}" >"$RUN/plain/database.dump.partial" &&
            [[ -s $RUN/plain/database.dump.partial ]] && step hosted-list pg_restore --list "$RUN/plain/database.dump.partial" >"$RUN/details/hosted-list.txt" &&
            mv "$RUN/plain/database.dump.partial" "$RUN/plain/database.dump"
    )
}
collect_paths() {
    local label=$1; shift
    local path
    local -a relative=()
    (( $# > 0 )) || return 0
    for path in "$@"; do
        infra_source_path "$path" && [[ -e $path && ! -L $path && $path != "$ARCHIVE_DIR" && $path != "$STATE_DIR" && $path != "$ARCHIVE_DIR/"* && $path != "$STATE_DIR/"* && $ARCHIVE_DIR != "$path/"* && $STATE_DIR != "$path/"* ]] || {
            infra_error "$label contains a missing path, symlink, root or job directory. List only required absolute source paths."; return 1;
        }
        relative+=("${path#/}")
    done
    step "$label-tar" tar -czf "$RUN/plain/$label.tar.gz.partial" -C / -- "${relative[@]}" &&
        step "$label-list" tar -tzf "$RUN/plain/$label.tar.gz.partial" >"$RUN/details/$label-list.txt" &&
        mv "$RUN/plain/$label.tar.gz.partial" "$RUN/plain/$label.tar.gz"
}
# Only explicit regular files can be copied from a container. Canonical-path checking
# rejects symlinked files and parents; the container needs readlink with -f support.
container_file() { # container_file <container> <absolute source> <local destination> <label>
    local container=$1 source=$2 destination=$3 label=$4 resolved
    infra_name "$container" && infra_absolute "$source" || { infra_error 'A container file needs a safe container name and a clean absolute path.'; return 1; }
    resolved=$(step "$label-path" docker exec "$container" readlink -f -- "$source") || return 1
    [[ $resolved == "$source" ]] && step "$label-type" docker exec "$container" test -f "$source" || {
        infra_error 'A required container file is missing, not a regular file or uses a symlink. List its real absolute file path.'; return 1;
    }
    step "$label-copy" docker cp "$container:$source" "$destination.partial" &&
        [[ -f $destination.partial && ! -L $destination.partial ]] &&
        chmod 600 "$destination.partial" && mv "$destination.partial" "$destination"
}
collect_container_configs() {
    (( ${#CONTAINER_CONFIG_PATHS[@]} > 0 )) || return 0
    infra_require docker || return 1
    [[ -n ${CONTAINER:-} ]] && infra_name "$CONTAINER" || { infra_error 'CONTAINER_CONFIG_PATHS needs CONTAINER. Set one explicit source container.'; return 1; }
    local path index=0 result=0
    mkdir -m 700 "$RUN/container-configs"
    for path in "${CONTAINER_CONFIG_PATHS[@]}"; do
        index=$((index + 1))
        if ! infra_absolute "$path"; then
            infra_error 'A container recovery path is not a clean absolute file path. Fix CONTAINER_CONFIG_PATHS.'; result=1; continue
        fi
        mkdir -p -- "$RUN/container-configs${path%/*}"
        container_file "$CONTAINER" "$path" "$RUN/container-configs$path" "container-config-$index" || result=1
    done
    if (( result != 0 )); then return 1; fi
    step container-config-tar tar -czf "$RUN/plain/container-configs.tar.gz.partial" -C "$RUN/container-configs" . &&
        step container-config-list tar -tzf "$RUN/plain/container-configs.tar.gz.partial" >"$RUN/details/container-config-list.txt" &&
        mv "$RUN/plain/container-configs.tar.gz.partial" "$RUN/plain/container-configs.tar.gz"
}
redis_command() {
    if [[ -n ${REDIS_CONTAINER:-} ]]; then
        # Docker reads the value from this process's environment; argv contains only its name.
        timeout 20 docker exec --env REDISCLI_AUTH "$REDIS_CONTAINER" redis-cli "${REDIS_ARGS[@]}" --raw "$@"
    else
        timeout 20 redis-cli "${REDIS_ARGS[@]}" --raw "$@"
    fi
}
redis_info() {
    step redis-info redis_command INFO persistence | tr -d '\r'
}
collect_redis() (
    if [[ -n ${REDIS_CONTAINER:-} ]]; then
        infra_require docker || return 1
        infra_name "$REDIS_CONTAINER" || { infra_error 'REDIS_CONTAINER is not a safe container name. Fix the job file.'; return 1; }
    else
        infra_require redis-cli || return 1
    fi
    [[ -n ${REDIS_RDB:-} && -n ${REDIS_CONFIG:-}${REDIS_PASSWORD_FILE:-} ]] || { infra_error 'Redis needs REDIS_RDB and either REDIS_CONFIG or REDIS_PASSWORD_FILE. Set its snapshot path and private authentication file.'; return 1; }
    [[ -z ${REDIS_CONFIG:-} ]] || infra_private "$REDIS_CONFIG" || return 1
    infra_absolute "$REDIS_RDB" || { infra_error 'REDIS_RDB must be a clean absolute file path. Fix the job file.'; return 1; }
    local password='' line token before info saves in_progress result deadline reply settings directory='' filename='' index
    local -a configured=()
    if [[ -n ${REDIS_PASSWORD_FILE:-} ]]; then
        infra_private "$REDIS_PASSWORD_FILE" || return 1
        password=$(<"$REDIS_PASSWORD_FILE")
    else
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^[[:space:]]*requirepass[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
                token=${BASH_REMATCH[1]}
                [[ $token != *[\"\'\\]* ]] || { infra_error 'Redis uses a quoted or escaped password. Put its exact value in REDIS_PASSWORD_FILE, a private 0600 file.'; return 1; }
                password=$token
            fi
        done <"$REDIS_CONFIG"
    fi
    infra_single_line "$password" || { infra_error 'Redis authentication is missing. Set requirepass or REDIS_PASSWORD_FILE; no unauthenticated snapshot is attempted.'; return 1; }
    export REDISCLI_AUTH="$password"
    REDIS_ARGS=()
    if [[ -n ${REDIS_SOCKET:-} ]]; then
        infra_absolute "$REDIS_SOCKET" || return 1
        if [[ -z ${REDIS_CONTAINER:-} ]]; then
            infra_source_path "$REDIS_SOCKET" && [[ -S $REDIS_SOCKET ]] || { infra_error 'The Redis socket is missing or unsafe. Fix REDIS_SOCKET.'; return 1; }
        fi
        REDIS_ARGS=(-s "$REDIS_SOCKET")
    else
        REDIS_PORT=${REDIS_PORT:-6379}
        [[ $REDIS_PORT =~ ^[0-9]{1,5}$ ]] && (( 10#$REDIS_PORT >= 1 && 10#$REDIS_PORT <= 65535 )) || { infra_error 'REDIS_PORT must be 1 to 65535. Fix the job file.'; return 1; }
        REDIS_ARGS=(-h 127.0.0.1 -p "$REDIS_PORT")
    fi
    REDIS_WAIT_SECONDS=${REDIS_WAIT_SECONDS:-120}
    [[ $REDIS_WAIT_SECONDS =~ ^[1-9][0-9]{0,3}$ ]] || { infra_error 'REDIS_WAIT_SECONDS must be 1 to 9999. Fix the job file.'; return 1; }
    # A successful save counter says nothing about a different, stale RDB at a listed path.
    settings=$(step redis-settings redis_command CONFIG GET dir dbfilename) || return 1
    mapfile -t configured <<<"$settings"
    [[ ${#configured[@]} == 4 ]] || { infra_error 'Redis did not return its snapshot settings. Allow CONFIG GET for dir and dbfilename, then retry.'; return 1; }
    for ((index=0; index<4; index+=2)); do
        case ${configured[index]} in
            dir) directory=${configured[index+1]} ;;
            dbfilename) filename=${configured[index+1]} ;;
            *) infra_error 'Redis returned unknown snapshot settings. Check its configuration before retrying.'; return 1 ;;
        esac
    done
    infra_single_line "$filename" && [[ $filename != */* && $REDIS_RDB == "${directory%/}/$filename" ]] || {
        infra_error 'REDIS_RDB does not match the running Redis snapshot path. Set it to the current dir and dbfilename before retrying; no old file was copied.'; return 1;
    }
    info=$(redis_info) || return 1
    before=$(sed -n 's/^rdb_saves://p' <<<"$info")
    in_progress=$(sed -n 's/^rdb_bgsave_in_progress://p' <<<"$info")
    [[ $before =~ ^[0-9]{1,12}$ && $in_progress == 0 ]] || { infra_error 'Redis does not expose rdb_saves or is already saving. Use Redis 7 or newer and retry after its save finishes.'; return 1; }
    reply=$(step redis-bgsave redis_command BGSAVE) || return 1
    [[ $reply == 'Background saving started' ]] || { infra_error 'Redis did not start BGSAVE. Check its private log and retry.'; return 1; }
    deadline=$(( $(date +%s) + REDIS_WAIT_SECONDS ))
    while (( $(date +%s) <= deadline )); do
        info=$(redis_info) || return 1
        saves=$(sed -n 's/^rdb_saves://p' <<<"$info")
        in_progress=$(sed -n 's/^rdb_bgsave_in_progress://p' <<<"$info")
        result=$(sed -n 's/^rdb_last_bgsave_status://p' <<<"$info")
        [[ $saves =~ ^[0-9]{1,12}$ && $in_progress =~ ^[01]$ && $result =~ ^(ok|err)$ ]] || return 1
        if [[ $in_progress == 0 ]]; then
            [[ $result == ok ]] || { infra_error 'Redis BGSAVE failed. Check disk space and its private log, then retry.'; return 1; }
            if (( 10#$saves > 10#$before )); then
                if [[ -n ${REDIS_CONTAINER:-} ]]; then
                    container_file "$REDIS_CONTAINER" "$REDIS_RDB" "$RUN/redis-candidate" redis-rdb || return 1
                else
                    infra_source_path "$REDIS_RDB" && [[ -f $REDIS_RDB ]] &&
                        step redis-copy cp -- "$REDIS_RDB" "$RUN/redis-candidate" || return 1
                fi
                [[ $(head -c 5 "$RUN/redis-candidate") == REDIS ]] || { infra_error 'Redis returned an invalid RDB file. Check REDIS_RDB and retry.'; return 1; }
                mv "$RUN/redis-candidate" "$RUN/plain/redis.rdb" || return 1
                return 0
            fi
        fi
        sleep 1
    done
    infra_error 'Redis BGSAVE did not finish within REDIS_WAIT_SECONDS. Check its log and retry; the old RDB was not copied.'
    return 1
)
collect_d1() {
    infra_require jq sqlite3 || return 1
    [[ -n ${D1_ENV:-} && ${#D1_DOWNLOAD_HOSTS[@]} -gt 0 ]] || { infra_error 'D1 needs D1_ENV and D1_DOWNLOAD_HOSTS. Set its private API file and the exact allowed export hosts.'; return 1; }
    unset CF_ACCOUNT_ID CF_DATABASE_ID CF_API_TOKEN
    infra_source "$D1_ENV" || return 1
    [[ ${CF_ACCOUNT_ID:-} =~ ^[a-fA-F0-9]{32}$ && ${CF_DATABASE_ID:-} =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] && infra_single_line "${CF_API_TOKEN:-}" || {
        infra_error 'D1 API settings are missing or invalid. Set CF_ACCOUNT_ID, CF_DATABASE_ID and CF_API_TOKEN in D1_ENV.'; return 1;
    }
    local host url status bookmark allowed=0 candidate sentinel
    for host in "${D1_DOWNLOAD_HOSTS[@]}"; do
        [[ $host =~ ^[A-Za-z0-9.-]+$ && ( $host == *.cloudflare.com || $host == *.r2.cloudflarestorage.com ) ]] || { infra_error 'D1_DOWNLOAD_HOSTS must list exact Cloudflare HTTPS hosts, not wildcards or other providers.'; return 1; }
    done
    D1_TIMEOUT_SECONDS=${D1_TIMEOUT_SECONDS:-600}
    [[ $D1_TIMEOUT_SECONDS =~ ^[1-9][0-9]{0,3}$ ]] || return 1
    printf '{"output_format":"polling"}\n' >"$RUN/d1-request.json"
    {
        printf 'silent\nshow-error\nfail\nproto = "=https"\nconnect-timeout = 10\nmax-time = 30\nrequest = "POST"\n'
        infra_curl_field url "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/d1/database/$CF_DATABASE_ID/export"
        infra_curl_field header "Authorization: Bearer $CF_API_TOKEN"
        infra_curl_field header 'Content-Type: application/json'
        infra_curl_field data-binary "@$RUN/d1-request.json"
    } >"$RUN/d1-api.conf"
    # The documented asynchronous API uses the same POST endpoint to poll current_bookmark.
    # https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/export/
    local deadline=$(( $(date +%s) + D1_TIMEOUT_SECONDS ))
    while (( $(date +%s) <= deadline )); do
        infra_curl "$RUN/d1-api.conf" "$RUN/d1-response.json" "$RUN/details/d1-api" || return 1
        step d1-response jq -e '
            .success == true and
            (.errors | type == "array" and length == 0) and
            (.result | type == "object") and
            (.result | if has("type") then .type == "export" else true end) and
            (.result | if has("success") then .success == true else true end) and
            (.result | if has("at_bookmark") then (.at_bookmark | type == "string" and length > 0) else true end) and
            (.result | if has("result") then (.result | type == "object") else true end) and
            (.result | if has("status") then .status == "complete" or .status == "error" else true end) and
            (.result | has("error") | not)
        ' "$RUN/d1-response.json" >/dev/null || return 1
        status=$(step d1-status jq -er '.result | if has("status") then .status else "pending" end' "$RUN/d1-response.json") || return 1
        case $status in
            complete)
                step d1-complete jq -e '.result.result | type == "object" and (.signed_url | type == "string" and length > 0)' "$RUN/d1-response.json" >/dev/null || return 1
                url=$(step d1-url jq -er '.result.result.signed_url' "$RUN/d1-response.json") || return 1
                infra_https "$url" && [[ $url =~ ^https://([A-Za-z0-9.-]+)/ ]] || { infra_error 'D1 returned an unsafe download URL. Check the export host; no download was attempted.'; return 1; }
                host=${BASH_REMATCH[1]}
                for candidate in "${D1_DOWNLOAD_HOSTS[@]}"; do [[ $host != "$candidate" ]] || allowed=1; done
                (( allowed )) || { infra_error 'D1 returned a host outside D1_DOWNLOAD_HOSTS. Confirm the host from the official export and update the private allowlist.'; return 1; }
                {
                    printf 'silent\nshow-error\nfail\nproto = "=https"\nconnect-timeout = 10\nmax-time = 600\n'
                    infra_curl_field url "$url"
                } >"$RUN/d1-download.conf"
                # A separate curl process and config keep the bearer token off the object request.
                infra_curl "$RUN/d1-download.conf" "$RUN/plain/database.sql.partial" "$RUN/details/d1-download" || return 1
                [[ -s $RUN/plain/database.sql.partial ]] && grep -Eq '^(CREATE TABLE|INSERT INTO|PRAGMA)' "$RUN/plain/database.sql.partial" || { infra_error 'D1 returned empty or unrecognized SQL. Start a new export; this file will not be uploaded.'; return 1; }
                # Safe mode refuses ATTACH, load_extension and filesystem access. A trailing
                # query proves the full input was read, including past a possible .quit command.
                # Bail and timeout bound failures in this new scratch database.
                sentinel=$(mktemp "$RUN/d1-sentinel.XXXXXX") || return 1
                sentinel="$SNAPSHOT-${sentinel##*/}"
                {
                    cat "$RUN/plain/database.sql.partial" && printf "\nSELECT '%s';\n" "$sentinel"
                } | step d1-sql timeout 600 sqlite3 -batch -bail -safe "$RUN/d1-validation.sqlite" >"$RUN/details/d1-sql-result" || return 1
                [[ $(tail -n 1 "$RUN/details/d1-sql-result") == "$sentinel" ]] || {
                    infra_error 'D1 SQL validation stopped before the end of the export. Start a new export; this file will not be uploaded.'; return 1;
                }
                mv "$RUN/plain/database.sql.partial" "$RUN/plain/database.sql" || return 1
                return 0
                ;;
            error) infra_error 'D1 export failed. Check the private API response and retry later.'; return 1 ;;
            pending) ;;
            *) infra_error 'D1 returned an unknown export status. Check the private response before retrying.'; return 1 ;;
        esac
        bookmark=$(step d1-bookmark jq -er '.result.at_bookmark | select(type == "string" and length > 0)' "$RUN/d1-response.json") || return 1
        infra_single_line "$bookmark" || return 1
        printf '%s' "$bookmark" | step d1-poll-body jq -Rs '{output_format:"polling",current_bookmark:.}' >"$RUN/d1-request.json" || return 1
        sleep 2
    done
    infra_error 'D1 export timed out. Check its private response and retry later, or raise D1_TIMEOUT_SECONDS.'
    return 1
}
case $PROFILE in
    supabase-docker|postgres-docker) collect_docker || artifact_failed 'PostgreSQL' ;;
    hosted-postgres) collect_hosted || artifact_failed 'Hosted PostgreSQL' ;;
    files) [[ ${#CONFIG_PATHS[@]} -gt 0 || ${#CONTAINER_CONFIG_PATHS[@]} -gt 0 || ${#STORAGE_PATHS[@]} -gt 0 || -n ${REDIS_CONFIG:-}${REDIS_PASSWORD_FILE:-} ]] || artifact_failed 'The empty files profile' ;;
    d1) collect_d1 || artifact_failed 'D1' ;;
    *) infra_error 'Unknown PROFILE. Use one of the profile names printed by --help.'; exit 1 ;;
esac
# All trusted profile config has loaded. Tar must include every selected recovery file.
unset TAR_OPTIONS
collect_paths configs "${CONFIG_PATHS[@]}" || artifact_failed 'Config paths'
collect_paths storage "${STORAGE_PATHS[@]}" || artifact_failed 'Storage paths'
collect_container_configs || artifact_failed 'Container recovery files'
if [[ -n ${REDIS_CONFIG:-}${REDIS_RDB:-}${REDIS_PASSWORD_FILE:-}${REDIS_SOCKET:-}${REDIS_CONTAINER:-} ]]; then collect_redis || artifact_failed 'Redis'; fi
(( INCOMPLETE == 0 )) || { infra_error "Snapshot $SNAPSHOT is incomplete. Successful artifacts remain locally; nothing is uploaded or pruned."; exit 1; }
shopt -s nullglob
ARTIFACTS=("$RUN/plain/"*)
(( ${#ARTIFACTS[@]} > 0 )) || { infra_error 'No artifacts were collected. Add source paths or fix the profile; nothing was uploaded.'; exit 1; }
{
    printf 'infrakit-manifest-v1\njob=%s\nprofile=%s\nsnapshot=%s\ncreated_at=%s\n' "$JOB_ID" "$PROFILE" "$SNAPSHOT" "$STARTED"
    if [[ $PROFILE == hosted-postgres ]]; then printf 'export_scope=%s\n' "$HOSTED_EXPORT_SCOPE"; fi
    if [[ $PROFILE == postgres-docker || $PROFILE == supabase-docker ]]; then
        for ((index=0; index<${#DB_NAMES[@]}; index++)); do printf 'db-%03d.dump=%s\n' "$((index + 1))" "${DB_NAMES[index]}"; done
    fi
    for artifact in "${ARTIFACTS[@]}"; do
        hash=$(step artifact-hash sha256sum "$artifact"); printf '%s  %s\n' "${hash%% *}" "${artifact##*/}"
    done
} >"$RUN/manifest.txt.partial"
mv "$RUN/manifest.txt.partial" "$RUN/plain/manifest.txt"
ARTIFACTS+=("$RUN/plain/manifest.txt")
for artifact in "${ARTIFACTS[@]}"; do
    filename=${artifact##*/}
    infra_name "$filename" || { infra_error 'An artifact has an unsafe name. Check the collector before retrying.'; exit 1; }
    step seal age -r "$BACKUP_AGE_RECIPIENT" -o "$RUN/sealed/$filename.age.partial" "$artifact"
    [[ -s $RUN/sealed/$filename.age.partial ]]
    mv "$RUN/sealed/$filename.age.partial" "$RUN/sealed/$filename.age"
done
printf 'infrakit-snapshot-v1\n%s\n%s\n%s\n%s\n' "$JOB_ID" "$SNAPSHOT" "$STARTED" "$REMOTE_ROOT" >"$RUN/proof.txt"
step seal-proof age -r "$BACKUP_AGE_RECIPIENT" -o "$RUN/sealed/complete.age.partial" "$RUN/proof.txt"
mv "$RUN/sealed/complete.age.partial" "$RUN/sealed/complete.age"
infra_log "Collected ${#ARTIFACTS[@]} artifacts including the manifest. Uploading encrypted files."
# Create only the dedicated prefix so a listing failure is never treated as absence.
step remote-prefix rclone mkdir "$REMOTE_ROOT" >"$RUN/details/remote-prefix-output"
step collision-list rclone lsf "$REMOTE_ROOT" --dirs-only >"$RUN/existing-snapshots"
if grep -Fxq "$SNAPSHOT/" "$RUN/existing-snapshots"; then
    infra_error 'The snapshot name already exists offsite. Run again to choose a new name; no object was replaced.'; exit 1
fi
# The completion marker must not reach the remote before the payload is verified.
step upload rclone copy "$RUN/sealed" "$REMOTE" --exclude /complete.age "${RCLONE_UP[@]}" >"$RUN/details/upload-output"
step read-back rclone check "$RUN/sealed" "$REMOTE" --exclude /complete.age --download --one-way --transfers 1 --checkers 1 >"$RUN/details/read-back-output"
for sealed in "$RUN/sealed/"*; do printf '%s\n' "${sealed##*/}"; done | sort >"$RUN/expected-files"
grep -Fxv complete.age "$RUN/expected-files" >"$RUN/expected-payload-files"
step payload-list rclone lsf "$REMOTE" --recursive --files-only | sort >"$RUN/remote-files"
cmp -s "$RUN/expected-payload-files" "$RUN/remote-files" || { infra_error 'The offsite file paths do not match the sealed set. Check the bucket and retry; nothing is pruned.'; exit 1; }
step completion-upload rclone copyto "$RUN/sealed/complete.age" "$REMOTE/complete.age" "${RCLONE_UP[@]}" >"$RUN/details/completion-upload-output"
step completion-read-back rclone check "$RUN/sealed" "$REMOTE" --download --one-way --transfers 1 --checkers 1 >"$RUN/details/completion-read-back-output"
step remote-list rclone lsf "$REMOTE" --recursive --files-only | sort >"$RUN/remote-files"
cmp -s "$RUN/expected-files" "$RUN/remote-files" || { infra_error 'The offsite file paths do not match the sealed set. Check the bucket and retry; nothing is pruned.'; exit 1; }
# An encrypted marker and a local receipt bind retention to exactly this job's verified objects.
RECEIPT=$(mktemp -d "$STATE_DIR/receipts/.partial-$SNAPSHOT-XXXXXX")
cp "$RUN/proof.txt" "$RECEIPT/proof"
cp "$RUN/expected-files" "$RECEIPT/files"
HASH=$(sha256sum "$RUN/sealed/complete.age"); printf '%s\n' "${HASH%% *}" >"$RECEIPT/complete.sha256"
mv -T "$RECEIPT" "$STATE_DIR/receipts/$SNAPSHOT"
printf '%s\n' "$(<"$RUN/proof.txt")" | infra_atomic "$RUN/COMPLETE"
printf '%s\n' "$(<"$RUN/proof.txt")" | infra_atomic "$STATE_DIR/last-success"
printf '%s\n' "$REMOTE" | infra_atomic "$STATE_DIR/offsite-enabled"
VERIFIED=1
COUNT=$(wc -l <"$RUN/expected-files" | tr -d '[:space:]')
infra_log "Offsite verified: $SNAPSHOT, $COUNT encrypted files."
# Do not prune during an outside-monitor outage, even though the backup proof is valid.
infra_heartbeat success || NOTIFY_FAILURE=1
(( NOTIFY_FAILURE == 0 )) || { infra_error 'The backup is verified, but its heartbeat failed. Fix HEARTBEAT_CONFIG and retry; retention was skipped.'; exit 1; }

# ponytail: keep small receipts after local prune so offsite ownership can still be checked.
# This grows by one receipt per run. A future receipt sweep can remove ones gone on both sides.
NOW=$(date +%s)
for receipt in "$STATE_DIR/receipts/"*; do
    name=${receipt##*/}
    infra_snapshot_name "$name" && [[ $name != "$SNAPSHOT" && -d $receipt && ! -L $receipt ]] || continue
    infra_dir "$receipt"
    infra_read_proof "$receipt/proof" || continue
    infra_private "$receipt/files"; infra_private "$receipt/complete.sha256"
    [[ ${INFRA_PROOF[1]} == "$JOB_ID" && ${INFRA_PROOF[2]} == "$name" && ${INFRA_PROOF[4]} == "$REMOTE_ROOT" ]] || continue
    [[ $(<"$receipt/complete.sha256") =~ ^[0-9a-f]{64}$ ]] || { infra_error 'An old receipt has an invalid marker hash. Inspect its private files before retrying.'; exit 1; }
    sort -cu "$receipt/files"
    grep -Fxq complete.age "$receipt/files" || { infra_error 'An old receipt has no encrypted ownership marker. Inspect it before retrying.'; exit 1; }
    while IFS= read -r filename; do
        [[ $filename =~ ^[A-Za-z0-9_.-]+\.age$ && $filename != *..* ]] || { infra_error 'A receipt has an unsafe file name. Inspect it by hand; retention stopped.'; exit 1; }
    done <"$receipt/files"
    AGE_SECONDS=$(( NOW - INFRA_PROOF[3] ))
    if (( AGE_SECONDS > REMOTE_KEEP_DAYS * 86400 )); then
        # A failed listing is not an absence. Only a successful empty listing is skipped.
        step prune-list rclone lsf "$REMOTE_ROOT/$name" --recursive --files-only | sort >"$RUN/prune-files"
        if [[ -s $RUN/prune-files ]]; then
            # A subset is safe after an interrupted prune. Unknown objects always stop it.
            comm -23 "$RUN/prune-files" "$receipt/files" >"$RUN/unowned-files"
            [[ ! -s $RUN/unowned-files ]] || { infra_error 'An old snapshot has unexpected offsite files. Inspect it by hand; no file in that snapshot was deleted.'; exit 1; }
            step prune-proof rclone cat "$REMOTE_ROOT/$name/complete.age" >"$RUN/prune-proof.age"
            HASH=$(sha256sum "$RUN/prune-proof.age")
            [[ ${HASH%% *} == "$(<"$receipt/complete.sha256")" ]] || { infra_error 'An old snapshot has a different ownership marker. Inspect it by hand; it was not pruned.'; exit 1; }
            while IFS= read -r filename; do
                [[ $filename == complete.age ]] || step prune-object rclone deletefile "$REMOTE_ROOT/$name/$filename" >"$RUN/details/prune-output"
            done <"$RUN/prune-files"
            step prune-marker rclone deletefile "$REMOTE_ROOT/$name/complete.age" >"$RUN/details/prune-output"
            infra_log "Pruned offsite snapshot $name."
        fi
    fi
    if (( AGE_SECONDS > LOCAL_KEEP_DAYS * 86400 )) && [[ -d $ARCHIVE_DIR/$name && ! -L $ARCHIVE_DIR/$name ]]; then
        infra_dir "$ARCHIVE_DIR/$name"
        infra_private "$ARCHIVE_DIR/$name/COMPLETE"
        if cmp -s "$receipt/proof" "$ARCHIVE_DIR/$name/COMPLETE"; then
            rm -rf -- "${ARCHIVE_DIR:?}/${name:?}"
            infra_log "Pruned local snapshot $name."
        fi
    fi
done
infra_log "Job $JOB_ID finished."
