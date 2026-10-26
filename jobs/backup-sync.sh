#!/usr/bin/env bash
# Copy only: no remote deletion and no changes to backup proofs or active job settings.
set +x +v
set -euo pipefail
umask 077
export LC_ALL=C
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash backup-sync.sh <private-sync-file>\nCopies existing backups and checks every source file against the target.\nNo deletes, provider switch or backup receipt changes. See README.md for configuration.\n'
    exit 0
fi
[[ $# == 1 ]] || { infra_error 'Pass one private sync file. Run with --help for usage.'; exit 2; }
infra_runtime
infra_require rclone jq flock sha256sum cmp find sort
unset SOURCE_ENV TARGET_ENV SOURCE_PREFIX TARGET_PREFIX SOURCE_LOCAL_DIR TARGET_LOCAL_DIR STATE_DIR VERIFY_ALL
JOB_FILE=$1
infra_source "$JOB_FILE"
[[ -n ${STATE_DIR:-} ]] || { infra_error 'STATE_DIR is missing. Use a dedicated private sync directory.'; exit 1; }
for field in SOURCE_PREFIX TARGET_PREFIX; do
    [[ ${!field+x} ]] || { infra_error "$field is missing. Set a prefix or explicitly set an empty value for a whole bucket."; exit 1; }
    [[ -z ${!field} ]] || infra_prefix "${!field}" || { infra_error "$field is unsafe. Remove dot segments, globs and trailing slashes."; exit 1; }
done
[[ -n ${SOURCE_ENV:-}${SOURCE_LOCAL_DIR:-} && -n ${TARGET_ENV:-}${TARGET_LOCAL_DIR:-} ]] || {
    infra_error 'Set SOURCE_ENV and TARGET_ENV. Local directories are only for isolated checks.'; exit 1;
}
[[ -z ${SOURCE_ENV:-} || -z ${SOURCE_LOCAL_DIR:-} ]] && [[ -z ${TARGET_ENV:-} || -z ${TARGET_LOCAL_DIR:-} ]] || {
    infra_error 'Choose one source and one target type, not both an env file and a local directory.'; exit 1;
}
case $STATE_DIR in /root|/home|/var|/var/lib|/var/backups|/etc|/usr|/opt|/srv|/Users) infra_error 'STATE_DIR is a shared root. Choose a dedicated subdirectory.'; exit 1 ;; esac
infra_dir "$STATE_DIR"
infra_lock "$STATE_DIR/job.lock"
for field in ${!RCLONE_@}; do unset "$field"; done
export RCLONE_CONFIG=/dev/null
if [[ -n ${SOURCE_LOCAL_DIR:-} ]]; then
    infra_remote_config SOURCE source local "$SOURCE_PREFIX" '' "$SOURCE_LOCAL_DIR"
else
    infra_remote_config SOURCE source s3 "$SOURCE_PREFIX" "$SOURCE_ENV"
fi
SOURCE=$INFRA_REMOTE_ROOT
SOURCE_ID=$INFRA_REMOTE_IDENTITY
if [[ -n ${TARGET_LOCAL_DIR:-} ]]; then
    infra_remote_config TARGET target local "$TARGET_PREFIX" '' "$TARGET_LOCAL_DIR"
else
    infra_remote_config TARGET target s3 "$TARGET_PREFIX" "$TARGET_ENV"
fi
TARGET=$INFRA_REMOTE_ROOT
TARGET_ID=$INFRA_REMOTE_IDENTITY
if [[ -n ${SOURCE_LOCAL_DIR:-} && -n ${TARGET_LOCAL_DIR:-} ]]; then
    source_path=${SOURCE#source:}
    target_path=${TARGET#target:}
    [[ $source_path != "$target_path" && $source_path != "$target_path/"* && $target_path != "$source_path/"* ]] || {
        infra_error 'Local source and target overlap. Use separate directories.'; exit 1;
    }
fi
if [[ $SOURCE_ID == "$TARGET_ID" && ( -z $SOURCE_PREFIX || -z $TARGET_PREFIX || $SOURCE_PREFIX == "$TARGET_PREFIX" || $SOURCE_PREFIX == "$TARGET_PREFIX/"* || $TARGET_PREFIX == "$SOURCE_PREFIX/"* ) ]]; then
    infra_error 'Source and target overlap. Use separate buckets or nonoverlapping prefixes.'; exit 1
fi
OWNER=$(printf 'infrakit-copy-v1\n%s\n%s\n%s\n%s\n' "$SOURCE_ID" "$SOURCE_PREFIX" "$TARGET_ID" "$TARGET_PREFIX")
if [[ -e $STATE_DIR/.infrakit-sync-owner || -L $STATE_DIR/.infrakit-sync-owner ]]; then
    infra_private "$STATE_DIR/.infrakit-sync-owner"
    [[ $(<"$STATE_DIR/.infrakit-sync-owner") == "$OWNER" ]] || { infra_error 'This state directory belongs to another transfer. Choose a new state directory.'; exit 1; }
else
    entry=$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name job.lock -print -quit) || exit 1
    [[ -z $entry ]] || { infra_error 'The sync state directory is not empty. Choose a new private directory.'; exit 1; }
    printf '%s\n' "$OWNER" | infra_atomic "$STATE_DIR/.infrakit-sync-owner"
fi
RUN=$(mktemp -d "$STATE_DIR/run-XXXXXX")
# Keep the newest 7 run folders (inventories and private error output). Older ones only fill the disk.
find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -printf '%T@ %p\0' | sort -z -rn | tail -z -n +8 | cut -z -d' ' -f2- | xargs -0 -r rm -rf --
step() {
    local label=$1; shift
    "$@" 2>"$RUN/$label.err" || { infra_error "$label failed. Read private details in $RUN/$label.err and retry. Existing backup proofs were not changed."; return 1; }
}
check_listed() { # <label> <list file> [rclone flags]: an empty list has nothing to check
    [[ -s $2 ]] || return 0
    step "$1" rclone check "$SOURCE" "$TARGET" --files-from-raw "$2" --one-way --checkers 1 "${@:3}" >"$RUN/$1.out"
}
trap 'infra_error "Copy interrupted. Retry the same config; private details remain in $RUN."; exit 130' INT
trap 'infra_error "Copy interrupted. Retry the same config; private details remain in $RUN."; exit 143' TERM
VERSION=$(step version rclone version | sed -n '1s/^rclone v\([0-9][0-9.]*\).*/\1/p')
[[ -n $VERSION && $(printf '%s\n' 1.75.2 "$VERSION" | sort -V | head -1) == 1.75.2 ]] || {
    infra_error 'rclone 1.75.2 or newer is required. Install it and retry.'; exit 1;
}
inventory() {
    local phase=$1
    step "$phase-list" rclone lsjson "$SOURCE" --recursive --files-only --hash >"$RUN/$phase.raw.json"
    step "$phase-validate" jq -e '
        type == "array" and length > 0 and all(.[];
          (.Path | type == "string" and length > 0 and (explode | all(. >= 32 and . != 127))) and
          (.Size | type == "number" and . >= 0) and (.ModTime | type == "string"))
    ' "$RUN/$phase.raw.json" >/dev/null || {
        infra_error 'Source listing is empty or invalid. Check the source prefix and permissions; nothing is reported as synced.'; return 1;
    }
    step "$phase-normalize" jq -S 'sort_by(.Path) | map({Path,Size,ModTime,Hashes})' "$RUN/$phase.raw.json" >"$RUN/$phase.json"
    if jq -e 'any(.[]; .Path | test("(^|/)(backup\\.info|archive\\.info)(\\.copy)?$|(^|/)pgbackrest(/|$)"))' "$RUN/$phase.json" >/dev/null; then
        infra_error 'This is a pgBackRest repository. Use a reviewed pgBackRest and WAL migration, not a generic copy.'; return 1
    fi
}
case /$SOURCE_PREFIX/ in */pgbackrest/*) infra_error 'Use pgBackRest tooling for physical repository migration.'; exit 1 ;; esac
inventory before
step payload-list jq -r '.[] | select((.Path | split("/") | last) != "complete.age") | .Path' "$RUN/before.json" >"$RUN/payload-files"
step marker-list jq -r '.[] | select((.Path | split("/") | last) == "complete.age") | .Path' "$RUN/before.json" >"$RUN/marker-files"
# A download from S3 is billed as outbound traffic, so a file is downloaded for the byte check only until
# it has passed once. STATE_DIR/verified.json lists the files that passed; one counts as proven only while
# the destination still holds it at the same size. Proven files are compared by size and hash, which needs
# no download. VERIFY_ALL=1 in the job file, or no verified.json, makes every file count as new.
step target-list rclone lsjson "$TARGET" --recursive --files-only >"$RUN/target.json"
if [[ ${VERIFY_ALL:-} != 1 && ( -e $STATE_DIR/verified.json || -L $STATE_DIR/verified.json ) ]]; then
    infra_private "$STATE_DIR/verified.json"
    cp -- "$STATE_DIR/verified.json" "$RUN/proven.json"
else
    printf '[]\n' >"$RUN/proven.json"
fi
step proven-validate jq -e 'type == "array" and all(.[]; (.Path | type == "string") and (.Size | type == "number"))' "$RUN/proven.json" >/dev/null
# shellcheck disable=SC2016
PROVEN_FILTER='($dest[0] | map({key: .Path, value: .Size}) | from_entries) as $present
    | ($proven[0] | map({key: .Path, value: .Size}) | from_entries) as $done
    | .[] | select((($present[.Path] == .Size) and ($done[.Path] == .Size)) == $want) | .Path'
step new-list jq -r --argjson want false --slurpfile dest "$RUN/target.json" --slurpfile proven "$RUN/proven.json" "$PROVEN_FILTER" "$RUN/before.json" >"$RUN/new-files"
step old-list jq -r --argjson want true --slurpfile dest "$RUN/target.json" --slurpfile proven "$RUN/proven.json" "$PROVEN_FILTER" "$RUN/before.json" >"$RUN/old-files"
step new-payload-list jq -R -r 'select((split("/") | last) != "complete.age")' "$RUN/new-files" >"$RUN/new-payload-files"
step new-marker-list jq -R -r 'select((split("/") | last) == "complete.age")' "$RUN/new-files" >"$RUN/new-marker-files"
infra_log 'Copying missing backup files. Existing files will not be replaced.'
# Every pass uses exact paths from the same inventory. A late snapshot cannot add a marker
# to the marker pass after its payload was excluded from the verified payload set.
step copy rclone copy "$SOURCE" "$TARGET" --files-from-raw "$RUN/payload-files" --immutable --checksum --transfers 1 --checkers 1 --s3-no-check-bucket --s3-no-head >"$RUN/copy.out"
check_listed verify-payload "$RUN/new-payload-files" --download
inventory staged
cmp -s "$RUN/before.json" "$RUN/staged.json" || {
    infra_error 'The source changed before completion markers could be copied. Pause its writers and retry; no success record was saved.'; exit 1;
}
step copy-markers rclone copy "$SOURCE" "$TARGET" --files-from-raw "$RUN/marker-files" --immutable --checksum --transfers 1 --checkers 1 --s3-no-check-bucket --s3-no-head >"$RUN/copy-markers.out"
check_listed verify "$RUN/new-marker-files" --download
check_listed verify-proven "$RUN/old-files"
if [[ -f $RUN/verify-proven.err ]] && grep -qi 'could not be checked' "$RUN/verify-proven.err"; then
    infra_error 'These providers cannot compare hashes for some files, so a listing cannot prove them. Add VERIFY_ALL=1 to the job file to download every file on every run.'; exit 1
fi
inventory after
cmp -s "$RUN/before.json" "$RUN/after.json" || {
    infra_error 'The source changed during the copy. Pause its writers and retry; no success record was saved.'; exit 1;
}
COUNT=$(jq length "$RUN/after.json")
NEW=$(wc -l <"$RUN/new-files")
jq 'map({Path, Size})' "$RUN/after.json" | infra_atomic "$STATE_DIR/verified.json"
printf 'infrakit-copy-v1\n%s\n%s\n%s\n%s\n' "$(date +%s)" "$SOURCE_ID/$SOURCE_PREFIX" "$TARGET_ID/$TARGET_PREFIX" "$COUNT" | infra_atomic "$STATE_DIR/last-copy"
infra_log "Copy verified: $COUNT source files checked ($NEW downloaded and compared byte for byte, $((COUNT - NEW)) compared by size and hash). Destination-only files and backup receipts were left unchanged."
