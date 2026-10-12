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
