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
# Sets the remote path and a credential-free storage identity for the caller.
# shellcheck disable=SC2034
infra_remote_config() { # <section> <alias> <backend> <prefix> [env_file] [local_dir]
    local section=$1 alias=$2 backend=$3 prefix=$4 env_file=${5:-} local_dir=${6:-${LOCAL_REMOTE_DIR:-}}
    local provider region endpoint bucket access_key secret_key token field identity_endpoint port
    local S3_PROVIDER='' S3_REGION='' S3_ENDPOINT='' S3_BUCKET='' S3_ACCESS_KEY_ID='' S3_SECRET_ACCESS_KEY='' S3_SESSION_TOKEN=''
    local R2_ACCOUNT_ID='' R2_ENDPOINT='' R2_BUCKET='' R2_ACCESS_KEY_ID='' R2_SECRET_ACCESS_KEY=''
    [[ $section =~ ^[A-Z]+$ && $alias =~ ^[a-z]+$ ]] || return 1
    if [[ $backend == local ]]; then
        [[ -n $local_dir ]] || { infra_error 'The local backend needs a dedicated private directory.'; return 1; }
        infra_dir "$local_dir" || return 1
        for field in "${ARCHIVE_DIR:-}" "${STATE_DIR:-}"; do
            [[ -z $field || ( $field != "$local_dir" && $field != "$local_dir/"* && $local_dir != "$field/"* ) ]] || {
                infra_error 'The local remote overlaps an archive or state directory. Use separate directories.'; return 1;
            }
        done
        export "RCLONE_CONFIG_${section}_TYPE=local"
        INFRA_REMOTE_ROOT="$alias:$local_dir${prefix:+/$prefix}"
        INFRA_REMOTE_IDENTITY="local:$local_dir"
        return 0
    fi
    [[ $backend == s3 || $backend == r2 ]] || { infra_error 'BACKEND must be s3, r2 or local.'; return 1; }
    if [[ -z $env_file ]]; then
        env_file=${S3_ENV:-${R2_ENV:-}}
        if [[ $backend == r2 && -n ${R2_ENV:-} ]]; then env_file=$R2_ENV; fi
    fi
    [[ -n $env_file ]] || { infra_error 'S3_ENV or R2_ENV is missing. Set a private remote file and retry.'; return 1; }
    infra_source "$env_file" || return 1
    # Select one complete credential namespace. Never combine keys from two providers.
    if [[ -n $S3_PROVIDER$S3_REGION$S3_ENDPOINT$S3_BUCKET$S3_ACCESS_KEY_ID$S3_SECRET_ACCESS_KEY$S3_SESSION_TOKEN ]]; then
        provider=${S3_PROVIDER:-AWS}; region=$S3_REGION; endpoint=$S3_ENDPOINT
        bucket=$S3_BUCKET; access_key=$S3_ACCESS_KEY_ID; secret_key=$S3_SECRET_ACCESS_KEY; token=$S3_SESSION_TOKEN
    else
        provider=Cloudflare; region=auto; endpoint=$R2_ENDPOINT
        bucket=$R2_BUCKET; access_key=$R2_ACCESS_KEY_ID; secret_key=$R2_SECRET_ACCESS_KEY; token=''
    fi
    for field in access_key secret_key; do
        infra_single_line "${!field}" || { infra_error 'The selected provider needs both access and secret keys. Fix the remote file.'; return 1; }
    done
    [[ -z $token ]] || infra_single_line "$token" || return 1
    [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ && $bucket != *..* ]] || {
        infra_error 'The selected provider needs a bucket name, not a path. Fix the remote file.'; return 1;
    }
    [[ $provider =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || { infra_error 'S3_PROVIDER is invalid. Use an rclone S3 provider name.'; return 1; }
    if [[ $provider == Cloudflare ]]; then
        if [[ -z $endpoint ]]; then
            [[ $R2_ACCOUNT_ID =~ ^[a-fA-F0-9]{32}$ ]] || { infra_error 'Cloudflare needs R2_ACCOUNT_ID or an HTTPS endpoint.'; return 1; }
            endpoint="https://${R2_ACCOUNT_ID,,}.r2.cloudflarestorage.com"
        fi
        region=${region:-auto}
    elif [[ $provider == AWS ]]; then
        [[ $region =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || { infra_error 'Set S3_REGION to an AWS region such as sa-east-1.'; return 1; }
    else
        [[ -n $endpoint ]] || { infra_error 'This S3 provider needs S3_ENDPOINT. Set its HTTPS origin.'; return 1; }
    fi
    [[ -z $region || $region =~ ^[a-z0-9-]+$ ]] || { infra_error 'S3_REGION is invalid. Fix the remote file.'; return 1; }
    [[ -z $endpoint || $endpoint =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || {
        infra_error 'The endpoint must be a bare HTTPS origin with no credentials or path.'; return 1;
    }
    endpoint=${endpoint,,}
    endpoint=${endpoint%/}
    if [[ $endpoint =~ :([0-9]+)$ ]]; then
        [[ ${#BASH_REMATCH[1]} -le 5 ]] && (( 10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 65535 )) || {
            infra_error 'The HTTPS endpoint port must be 1 to 65535.'; return 1;
        }
        port=$((10#${BASH_REMATCH[1]}))
        endpoint=${endpoint%:*}
        if (( port != 443 )); then endpoint+=":$port"; fi
    fi
    identity_endpoint=$endpoint
    if [[ -z $identity_endpoint && $provider == AWS ]]; then
        if [[ $region == cn-* ]]; then
            identity_endpoint="https://s3.$region.amazonaws.com.cn"
        else
            identity_endpoint="https://s3.$region.amazonaws.com"
        fi
    fi
    # Region and signing-provider labels do not create a second copy at the same endpoint.
    # Standard AWS regional hosts share one bucket namespace within their partition.
    if [[ $identity_endpoint =~ ^https://s3([.-](dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com(\.cn)?$ ]]; then
        if [[ $identity_endpoint == *.amazonaws.com.cn ]]; then
            identity_endpoint=https://s3.amazonaws.com.cn
        elif [[ $identity_endpoint == *us-gov-* ]]; then
            identity_endpoint=https://s3.us-gov.amazonaws.com
        else
            identity_endpoint=https://s3.amazonaws.com
        fi
    fi
    for field in ${!RCLONE_CONFIG_@}; do
        [[ $field != "RCLONE_CONFIG_${section}_"* ]] || unset "$field"
    done
    export "RCLONE_CONFIG_${section}_TYPE=s3" "RCLONE_CONFIG_${section}_PROVIDER=$provider"
    export "RCLONE_CONFIG_${section}_ACCESS_KEY_ID=$access_key" "RCLONE_CONFIG_${section}_SECRET_ACCESS_KEY=$secret_key"
    export "RCLONE_CONFIG_${section}_REGION=$region" "RCLONE_CONFIG_${section}_ENDPOINT=$endpoint"
    export "RCLONE_CONFIG_${section}_SESSION_TOKEN=$token"
    if [[ $provider == AWS && $region != us-east-1 ]]; then export "RCLONE_CONFIG_${section}_LOCATION_CONSTRAINT=$region"; fi
    # AWS buckets normally have ACLs disabled. Omitting ACL also keeps other providers private by default.
    INFRA_REMOTE_ROOT="$alias:$bucket${prefix:+/$prefix}"
    INFRA_REMOTE_IDENTITY="s3|$identity_endpoint|$bucket"
}
