#!/usr/bin/env bash
# Shared functions only. Sourcing this file never reads configuration or sends a request.
# Validation chains intentionally fail when any condition fails.
# shellcheck disable=SC2015

infra_error() { printf 'infrakit: %s\n' "$*" >&2; }
infra_log() { printf 'infrakit: %s\n' "$*"; }
infra_require() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || { infra_error "$tool is missing. Install it and run the job again."; return 1; }
    done
}
infra_runtime() {
    (( BASH_VERSINFO[0] >= 4 )) || { infra_error 'Bash 4 or newer is required. Run this job with a newer Bash.'; return 1; }
    infra_require stat date readlink mktemp chmod mv curl || return 1
    stat --version >/dev/null 2>&1 && date --version >/dev/null 2>&1 || { infra_error 'GNU stat and date are required. Use GNU coreutils in PATH.'; return 1; }
    export LC_ALL=C
    umask 077
}
infra_uint() { [[ $1 =~ ^[1-9][0-9]{0,6}$ ]]; }
infra_single_line() { [[ -n $1 && $1 != *[$'\001'-$'\037'$'\177']* ]]; }
infra_name() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$ && $1 != *..* ]]; }
infra_snapshot_name() { [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]]; }
infra_prefix() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ && $1 != *..* && $1 != */ && $1 != *//* ]] || return 1
    [[ /$1/ != */./* ]]
}
infra_absolute() {
    [[ $1 == /* && $1 != / && $1 != */ && $1 != *//* && $1 != *[$'\001'-$'\037'$'\177']* ]] || return 1
    case "/${1#/}/" in */../*|*/./*) return 1 ;; esac
}
# Every ancestor must be root, this UID or an explicitly allowed data owner.
# Job config and writable state omit the second argument, keeping root/EUID trust.
# This deliberately refuses /tmp and symlinked paths, even for tests.
infra_path() {
    local path=$1 data_owner=${2:-$EUID} cursor=/ component owner mode
    infra_absolute "$path" || { infra_error 'A path is not an absolute, clean path. Remove relative segments, repeated slashes and control characters.'; return 1; }
    local -a components
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        cursor="${cursor%/}/$component"
        [[ ! -L $cursor ]] || { infra_error 'A path contains a symlink. Use its real path instead.'; return 1; }
        [[ -e $cursor ]] || continue
        owner=$(stat -c %u -- "$cursor") || return 1
        mode=$(stat -c %a -- "$cursor") || return 1
        [[ $owner == 0 || $owner == "$EUID" || $owner == "$data_owner" ]] && (( (8#$mode & 0022) == 0 )) || {
            infra_error 'A path has an unsafe owner or writable parent. Use directories owned by root or this user with no group or other write access.'; return 1;
        }
    done
}
infra_source_path() { # A collected artifact is read, never sourced. Its owner can be a service user.
    infra_absolute "$1" && [[ $(readlink -m -- "$1") == "$1" ]] || {
        infra_error 'An artifact path is relative, traverses a parent or uses a symlink. List its real absolute path.'; return 1;
    }
}
infra_private() {
    infra_path "$1" "${2:-$EUID}" || return 1
    [[ -f $1 && -r $1 && $(stat -c %a -- "$1") == 600 && $(stat -c %h -- "$1") == 1 ]] || {
        infra_error 'A private file is missing or not a single-link 0600 file. Create it, set its owner and run chmod 600.'; return 1;
    }
}
infra_source() {
    infra_private "$1" || return 1
    # Configuration is trusted Bash, not a dotenv parser. Keep accidental output private.
    local output result=0
    output=$(mktemp "${1%/*}/.infra-config.XXXXXX") || return 1
    # shellcheck disable=SC1090
    source "$1" >"$output" 2>&1 || result=$?
    set +x +v
    if (( result != 0 )); then
        infra_error "Configuration did not load. Check its Bash syntax; private details are in $output."
        return 1
    fi
    rm -f -- "$output"
}
infra_dir() {
    infra_path "$1" || return 1
    # infra_runtime sets umask 077, including for newly created parents.
    mkdir -p -- "$1" || return 1
    [[ -d $1 && $(stat -c %u -- "$1") == "$EUID" && $(stat -c %a -- "$1") == 700 ]] || {
        infra_error 'A job directory is not owned by this user at mode 0700. Fix its owner and mode before retrying.'; return 1;
    }
}
infra_atomic() { # infra_atomic <destination>, contents on stdin
    local temporary
    infra_path "$1" || return 1
    if [[ -e $1 || -L $1 ]]; then
        infra_private "$1" && [[ $(stat -c %u -- "$1") == "$EUID" ]] || {
            infra_error 'A state file is not a single-link 0600 file owned by this user. Choose a private state path; the existing target was not changed.'; return 1;
        }
    fi
    temporary=$(mktemp "${1%/*}/.infra-state.XXXXXX") || return 1
    if cat >"$temporary" && chmod 600 "$temporary" && mv -fT -- "$temporary" "$1"; then return 0; fi
    rm -f -- "$temporary"
    infra_error 'The state file could not be saved. Check directory access and free space, then retry.'
    return 1
}
infra_lock() {
    [[ ! -e $1 && ! -L $1 ]] || infra_private "$1" || return 1
    # The parent directory is private and checked before this function is called.
    exec 9>"$1"
    flock -n 9 || { infra_error 'This job is already running. Wait for it to finish before retrying.'; return 1; }
}
infra_read_proof() { # Read the one five-line proof format into INFRA_PROOF.
    infra_private "$1" "${2:-$EUID}" || return 1
    mapfile -t INFRA_PROOF <"$1"
    [[ ${#INFRA_PROOF[@]} == 5 && ${INFRA_PROOF[0]} == infrakit-snapshot-v1 ]] &&
        infra_name "${INFRA_PROOF[1]}" &&
        infra_snapshot_name "${INFRA_PROOF[2]}" &&
        [[ ${INFRA_PROOF[3]} =~ ^[1-9][0-9]{0,11}$ ]] &&
        infra_single_line "${INFRA_PROOF[4]}"
}
infra_backup_fresh() {
    local directory=$1 maximum=$2 now
    local -a INFRA_PROOF=() owner=()
    infra_uint "$maximum" && infra_read_proof "$directory/last-success" &&
        infra_private "$directory/.infrakit-owner" && infra_private "$directory/offsite-enabled" || return 1
    mapfile -t owner <"$directory/.infrakit-owner"
    [[ ${#owner[@]} == 4 && ${owner[0]} == infrakit-owner-v1 && ${owner[1]} == "${INFRA_PROOF[1]}" && ${owner[3]} == "${INFRA_PROOF[4]}" ]] || return 1
    infra_private "$directory/receipts/${INFRA_PROOF[2]}/proof" || return 1
    cmp -s "$directory/last-success" "$directory/receipts/${INFRA_PROOF[2]}/proof" &&
        [[ $(cat "$directory/offsite-enabled") == "${INFRA_PROOF[4]}/${INFRA_PROOF[2]}" ]] || return 1
    now=$(date +%s) || return 1
    (( INFRA_PROOF[3] <= now && now - INFRA_PROOF[3] <= maximum )) || {
        infra_error 'A required backup has no recent verified proof. Run that backup and fix its failed step before the host can report healthy.'; return 1;
    }
}
infra_curl_value() { # One curl config value; never pass a credential to a command.
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}
infra_curl_field() { printf '%s = ' "$1"; infra_curl_value "$2"; printf '\n'; }
infra_https() { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]\"\\]*)?$ && $1 != *'@'* && $1 != *[$'\001'-$'\037'$'\177']* ]]; }
infra_curl() { # infra_curl <private curl file> <private output> <private diagnostics>
    curl -q --config "$1" >"$2" 2>"$3" || {
        infra_error "Request failed. Check the connection and private configuration, then retry. Private details are in $3."; return 1;
    }
}
infra_alert() { # Only authored summaries, never arbitrary logs.
    [[ -n ${ALERT_CONFIG:-} ]] || return 0
    printf '%s\n' "$2" | ALERT_CONFIG="$ALERT_CONFIG" bash "${INFRA_JOBS}/alert.sh" "$1"
}
infra_heartbeat() {
    [[ -n ${HEARTBEAT_CONFIG:-} ]] || return 0
    bash "${INFRA_JOBS}/heartbeat.sh" "$HEARTBEAT_CONFIG" "$1"
}
# Sets INFRA_REMOTE_ROOT for the caller.
# shellcheck disable=SC2034
infra_remote_config() { # infra_remote_config <rclone_section> <remote_alias> <backend> <remote_prefix> [env_file] [local_dir]
    local section=$1 alias=$2 backend=$3 prefix=$4 env_file=${5:-} local_dir=${6:-${LOCAL_REMOTE_DIR:-}}
    local access_key secret_key bucket endpoint region provider field
    if [[ -z $env_file ]]; then
        env_file=${S3_ENV:-${R2_ENV:-}}
        if [[ $backend == r2 && -n ${R2_ENV:-} ]]; then env_file=$R2_ENV; fi
    fi
    case $backend in
        r2|s3)
            [[ $(stat -c %u -- "$JOB_FILE") == "$EUID" ]] || { infra_error 'The job file must be owned by the user running the job. Fix its owner before retrying.'; return 1; }
            [[ -n $env_file ]] || { infra_error 'S3_ENV or R2_ENV is missing. Point it at a private remote file.'; return 1; }
            unset R2_ACCOUNT_ID R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
            unset S3_PROVIDER S3_REGION S3_ENDPOINT S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET
            infra_source "$env_file" || return 1
            [[ $(stat -c %u -- "$env_file") == "$EUID" ]] || { infra_error 'The remote file is not owned by the user running the job. Fix its owner before retrying.'; return 1; }
            access_key=${S3_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}
            secret_key=${S3_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}
            bucket=${S3_BUCKET:-${R2_BUCKET:-}}
            endpoint=${S3_ENDPOINT:-${R2_ENDPOINT:-}}
            region=${S3_REGION:-}
            provider=${S3_PROVIDER:-}
            for field in access_key secret_key bucket; do
                infra_single_line "${!field:-}" || { infra_error 'Remote credentials or bucket are missing or invalid. Fix S3_ENV or R2_ENV and retry.'; return 1; }
            done
            [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ && $bucket != *..* ]] || { infra_error 'S3_BUCKET or R2_BUCKET must be a bucket name, not a path. Fix S3_ENV or R2_ENV.'; return 1; }
            if [[ -z $provider ]]; then
                if [[ ( $backend == r2 && -z $region ) || ( -n ${R2_ACCOUNT_ID:-} && -z $region ) ]]; then
                    provider=Cloudflare
                else
                    provider=AWS
                fi
            fi
            [[ $provider =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || { infra_error 'S3_PROVIDER is invalid. Use AWS, Cloudflare or another rclone S3 provider name.'; return 1; }
            if [[ $provider == Cloudflare ]]; then
                if [[ -z $endpoint ]]; then
                    [[ ${R2_ACCOUNT_ID:-} =~ ^[a-fA-F0-9]{32}$ ]] || { infra_error 'Set a valid R2_ACCOUNT_ID or HTTPS S3_ENDPOINT/R2_ENDPOINT in S3_ENV or R2_ENV.'; return 1; }
                    endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
                fi
            elif [[ $provider == AWS ]]; then
                [[ $region =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { infra_error 'S3_REGION is missing or invalid. Set an AWS region such as sa-east-1 or us-east-1.'; return 1; }
            else
                [[ -n $endpoint ]] || { infra_error 'S3_ENDPOINT is required when S3_PROVIDER is not AWS or Cloudflare.'; return 1; }
                [[ -z $region || $region =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { infra_error 'S3_REGION is invalid. Fix S3_ENV and retry.'; return 1; }
            fi
            if [[ -n $endpoint ]]; then
                [[ $endpoint =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || { infra_error 'S3_ENDPOINT or R2_ENDPOINT must be a bare HTTPS origin without credentials or a path.'; return 1; }
            fi
            export "RCLONE_CONFIG_${section}_TYPE=s3" "RCLONE_CONFIG_${section}_PROVIDER=$provider"
            export "RCLONE_CONFIG_${section}_ACCESS_KEY_ID=$access_key"
            export "RCLONE_CONFIG_${section}_SECRET_ACCESS_KEY=$secret_key"
            export "RCLONE_CONFIG_${section}_ACL=private"
            if [[ -n $endpoint ]]; then export "RCLONE_CONFIG_${section}_ENDPOINT=$endpoint"; else unset "RCLONE_CONFIG_${section}_ENDPOINT"; fi
            if [[ -n $region ]]; then
                export "RCLONE_CONFIG_${section}_REGION=$region"
                if [[ $provider == AWS && $region != us-east-1 && $region != auto ]]; then
                    export "RCLONE_CONFIG_${section}_LOCATION_CONSTRAINT=$region"
                else
                    unset "RCLONE_CONFIG_${section}_LOCATION_CONSTRAINT"
                fi
            else
                unset "RCLONE_CONFIG_${section}_REGION" "RCLONE_CONFIG_${section}_LOCATION_CONSTRAINT"
            fi
            INFRA_REMOTE_ROOT="$alias:$bucket/$prefix"
            ;;
        local)
            [[ -n $local_dir ]] || { infra_error 'The local test backend needs LOCAL_REMOTE_DIR. Use a dedicated private directory.'; return 1; }
            infra_dir "$local_dir" || return 1
            [[ $local_dir != "$ARCHIVE_DIR" && $local_dir != "$STATE_DIR" && $local_dir != "$ARCHIVE_DIR/"* && $local_dir != "$STATE_DIR/"* && $ARCHIVE_DIR != "$local_dir/"* && $STATE_DIR != "$local_dir/"* ]] || {
                infra_error 'The local remote overlaps a job directory. Use a separate directory.'; return 1;
            }
            export "RCLONE_CONFIG_${section}_TYPE=local"
            INFRA_REMOTE_ROOT="$alias:$local_dir/$prefix"
            ;;
        *) infra_error 'BACKEND must be s3, r2 or local. Local is only for isolated checks.'; return 1 ;;
    esac
}
