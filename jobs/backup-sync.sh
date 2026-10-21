#!/usr/bin/env bash
# Validation chains fail when any condition fails.
# shellcheck disable=SC2015,SC2034
set +x +v
set -euo pipefail
umask 077
export LC_ALL=C
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash backup-sync.sh <private-job-file> [--from-env <private-remote-file> | --from-local <local-remote-dir>] [--rerun]\nSyncs verified encrypted snapshots to the configured S3 or R2 remote, updates local receipts and optionally runs a fresh backup.\nSee README.md for provider switching and smart sync options.\n'
    exit 0
fi
infra_runtime
infra_require age rclone flock sha256sum cmp sort find comm
(( $# >= 1 )) || { infra_error 'Pass a private job file. Use --help for sync options.'; exit 2; }
JOB_FILE=$1
shift
FROM_ENV=''
FROM_LOCAL=''
RERUN=0
while (( $# > 0 )); do
    case $1 in
        --from-env)
            (( $# >= 2 )) && [[ -n $2 ]] || { infra_error '--from-env needs a private remote configuration file.'; exit 2; }
            [[ -z $FROM_ENV && -z $FROM_LOCAL ]] || { infra_error 'Pass at most one --from-env or --from-local source.'; exit 2; }
            FROM_ENV=$2
            shift 2
            ;;
        --from-local)
            (( $# >= 2 )) && [[ -n $2 ]] || { infra_error '--from-local needs an absolute private directory.'; exit 2; }
            [[ -z $FROM_ENV && -z $FROM_LOCAL ]] || { infra_error 'Pass at most one --from-env or --from-local source.'; exit 2; }
            FROM_LOCAL=$2
            shift 2
            ;;
        --rerun)
            RERUN=1
            shift
            ;;
        *)
            infra_error 'Unknown option. Run backup-sync.sh --help for usage.'
            exit 2
            ;;
    esac
done

unset JOB_ID PROFILE ARCHIVE_DIR STATE_DIR R2_ENV S3_ENV REMOTE_PREFIX BACKUP_AGE_RECIPIENT
unset LOCAL_REMOTE_DIR LOCAL_KEEP_DAYS REMOTE_KEEP_DAYS
BACKEND=''
DB_NAMES=(); DUMP_ARGS=(); CONFIG_PATHS=(); CONTAINER_CONFIG_PATHS=(); STORAGE_PATHS=(); D1_DOWNLOAD_HOSTS=()
infra_source "$JOB_FILE"
for field in DB_NAMES DUMP_ARGS CONFIG_PATHS CONTAINER_CONFIG_PATHS STORAGE_PATHS D1_DOWNLOAD_HOSTS; do
    [[ $(declare -p "$field") == 'declare -a '* ]] || { infra_error "$field must be an indexed Bash array. Use parentheses in the job file."; exit 1; }
done
if [[ -z ${BACKEND:-} ]]; then
    if [[ -n ${S3_ENV:-} && -z ${R2_ENV:-} ]]; then BACKEND=s3; else BACKEND=r2; fi
fi
for field in JOB_ID PROFILE ARCHIVE_DIR STATE_DIR REMOTE_PREFIX BACKUP_AGE_RECIPIENT; do
    [[ -n ${!field:-} ]] || { infra_error "$field is missing. Set it in the job file and retry."; exit 1; }
done
infra_name "$JOB_ID" || { infra_error 'JOB_ID must use letters, digits, dots, underscores or hyphens, with no .. and at most 63 characters.'; exit 1; }
infra_prefix "$REMOTE_PREFIX" || {
    infra_error 'REMOTE_PREFIX must be a nonempty path below the bucket, using letters, digits, dots, slashes, underscores or hyphens. Remove dot segments, empty segments and trailing slashes.'; exit 1;
}
infra_single_line "$BACKUP_AGE_RECIPIENT" || { infra_error 'BACKUP_AGE_RECIPIENT is invalid. Set one public age recipient.'; exit 1; }
for directory in "$ARCHIVE_DIR" "$STATE_DIR"; do
    case $directory in /root|/home|/var|/var/lib|/var/backups|/etc|/usr|/opt|/srv|/Users) infra_error 'A job directory is a shared system root. Choose a dedicated subdirectory.'; exit 1 ;; esac
    infra_dir "$directory"
done
[[ $ARCHIVE_DIR != "$STATE_DIR" && $ARCHIVE_DIR != "$STATE_DIR/"* && $STATE_DIR != "$ARCHIVE_DIR/"* ]] || {
    infra_error 'ARCHIVE_DIR and STATE_DIR overlap. Use separate directories.'; exit 1;
}
infra_lock "$STATE_DIR/job.lock"
SYNC_WORK=''
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n $SYNC_WORK && -d $SYNC_WORK ]]; then rm -rf -- "$SYNC_WORK"; fi
    if (( result != 0 )); then
        infra_error "Sync for job $JOB_ID did not finish. Fix the reported step and retry."
    fi
    exit "$result"
}
trap cleanup EXIT

for field in ${!RCLONE_@}; do unset "$field"; done
export RCLONE_CONFIG=/dev/null
RCLONE_UP=(--transfers 1 --checkers 1)
infra_remote_config BACKUP backup "$BACKEND" "$REMOTE_PREFIX"
REMOTE_ROOT=$INFRA_REMOTE_ROOT
[[ $BACKEND == local ]] || RCLONE_UP+=(--s3-no-check-bucket --s3-no-head --s3-chunk-size 5M --s3-upload-concurrency 1)

SOURCE_ROOT=''
if [[ -n $FROM_ENV ]]; then
    infra_remote_config SOURCE source s3 "$REMOTE_PREFIX" "$FROM_ENV"
    SOURCE_ROOT=$INFRA_REMOTE_ROOT
elif [[ -n $FROM_LOCAL ]]; then
    infra_remote_config SOURCE source local "$REMOTE_PREFIX" '' "$FROM_LOCAL"
    SOURCE_ROOT=$INFRA_REMOTE_ROOT
fi
if [[ -n $SOURCE_ROOT && $SOURCE_ROOT == "${REMOTE_ROOT/#backup:/source:}" ]]; then
    infra_error 'The source and target remotes point to the same location. Choose a different source or omit --from-env/--from-local.'; exit 1
fi

OWNER=$(printf 'infrakit-owner-v1\n%s\n%s\n%s\n' "$JOB_ID" "$ARCHIVE_DIR" "$REMOTE_ROOT")
for directory in "$ARCHIVE_DIR" "$STATE_DIR"; do
    if [[ -e $directory/.infrakit-owner || -L $directory/.infrakit-owner ]]; then
        infra_private "$directory/.infrakit-owner"
        mapfile -t existing_owner <"$directory/.infrakit-owner"
        [[ ${#existing_owner[@]} == 4 && ${existing_owner[0]} == infrakit-owner-v1 && ${existing_owner[1]} == "$JOB_ID" && ${existing_owner[2]} == "$ARCHIVE_DIR" ]] || {
            infra_error 'A job directory belongs to another job. Use a dedicated directory; do not replace its ownership marker.'; exit 1;
        }
    else
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
SYNC_WORK=$(mktemp -d "$STATE_DIR/.sync-XXXXXX")
chmod 700 "$SYNC_WORK"
mkdir -m 700 "$SYNC_WORK/details" "$SYNC_WORK/stage"

VERSION=$(rclone version 2>"$SYNC_WORK/details/rclone-version" | sed -n '1s/^rclone v\([0-9][0-9.]*\).*/\1/p')
[[ -n $VERSION && $(printf '%s\n' 1.75.2 "$VERSION" | sort -V | head -1) == 1.75.2 ]] || { infra_error 'rclone 1.75.2 or newer is required. Install it and retry.'; exit 1; }

step() {
    local label=$1; shift
    "$@" 2>"$SYNC_WORK/details/$label" || { infra_error "$label failed. Check the private details in $SYNC_WORK/details/$label and retry."; return 1; }
}

step remote-prefix rclone mkdir "$REMOTE_ROOT" >"$SYNC_WORK/details/remote-prefix-output"
step target-snapshots rclone lsf "$REMOTE_ROOT" --dirs-only >"$SYNC_WORK/target-snapshots"

shopt -s nullglob
RECEIPTS=("$STATE_DIR/receipts/"*)
SYNCED=0
ALREADY_SYNCED=0
LATEST_SNAPSHOT=''
LATEST_STARTED=0
LATEST_PROOF=''

for receipt in "${RECEIPTS[@]}"; do
    name=${receipt##*/}
    infra_snapshot_name "$name" && [[ -d $receipt && ! -L $receipt ]] || continue
    infra_dir "$receipt"
    infra_read_proof "$receipt/proof" || { infra_error "Receipt $name has an invalid proof. Inspect it before syncing."; exit 1; }
    infra_private "$receipt/files"
    infra_private "$receipt/complete.sha256"
    [[ ${INFRA_PROOF[1]} == "$JOB_ID" && ${INFRA_PROOF[2]} == "$name" ]] || {
        infra_error "Receipt $name belongs to another job. Inspect $receipt before syncing."; exit 1;
    }
    EXPECTED_HASH=$(<"$receipt/complete.sha256")
    [[ $EXPECTED_HASH =~ ^[0-9a-f]{64}$ ]] || { infra_error "Receipt $name has an invalid marker hash."; exit 1; }
    sort -cu "$receipt/files"
    grep -Fxq complete.age "$receipt/files" || { infra_error "Receipt $name has no encrypted ownership marker."; exit 1; }
    while IFS= read -r filename; do
        [[ $filename =~ ^[A-Za-z0-9_.-]+\.age$ && $filename != *..* ]] || { infra_error "Receipt $name has an unsafe file name."; exit 1; }
    done <"$receipt/files"
    grep -Fxv complete.age "$receipt/files" >"$SYNC_WORK/expected-payload-$name"

    TARGET_SNAP="$REMOTE_ROOT/$name"
    NEED_UPLOAD=1
    if grep -Fxq "$name/" "$SYNC_WORK/target-snapshots"; then
        step "target-list-$name" rclone lsf "$TARGET_SNAP" --recursive --files-only | sort >"$SYNC_WORK/target-files-$name"
        if cmp -s "$receipt/files" "$SYNC_WORK/target-files-$name"; then
            step "target-proof-$name" rclone cat "$TARGET_SNAP/complete.age" >"$SYNC_WORK/target-complete-$name.age"
            HASH=$(sha256sum "$SYNC_WORK/target-complete-$name.age")
            [[ ${HASH%% *} == "$EXPECTED_HASH" ]] || {
                infra_error "Snapshot $name on the target remote has a different ownership marker. Inspect the target bucket before retrying."; exit 1;
            }
            NEED_UPLOAD=0
            ALREADY_SYNCED=$((ALREADY_SYNCED + 1))
        fi
    fi

    if (( NEED_UPLOAD )); then
        STAGE_DIR=''
        LOCAL_SEALED="$ARCHIVE_DIR/$name/sealed"
        if [[ -d $LOCAL_SEALED && ! -L $LOCAL_SEALED ]]; then
            LOCAL_OK=1
            while IFS= read -r filename; do
                [[ -f $LOCAL_SEALED/$filename && ! -L $LOCAL_SEALED/$filename ]] || { LOCAL_OK=0; break; }
            done <"$receipt/files"
            if (( LOCAL_OK )); then
                HASH=$(sha256sum "$LOCAL_SEALED/complete.age")
                if [[ ${HASH%% *} == "$EXPECTED_HASH" ]]; then
                    STAGE_DIR=$LOCAL_SEALED
                fi
            fi
        fi

        if [[ -z $STAGE_DIR ]]; then
            [[ -n $SOURCE_ROOT ]] || {
                infra_error "Snapshot $name is no longer in the local archive. Pass --from-env or --from-local to copy it from the previous remote."; exit 1;
            }
            STAGE_DIR="$SYNC_WORK/stage/$name/sealed"
            mkdir -m 700 "$SYNC_WORK/stage/$name" "$STAGE_DIR"
            step "source-list-$name" rclone lsf "$SOURCE_ROOT/$name" --recursive --files-only | sort >"$SYNC_WORK/source-files-$name"
            cmp -s "$receipt/files" "$SYNC_WORK/source-files-$name" || {
                infra_error "Snapshot $name on the source remote does not match its receipt. Check the source remote before retrying."; exit 1;
            }
            step "source-download-$name" rclone copy "$SOURCE_ROOT/$name" "$STAGE_DIR" --transfers 1 --checkers 1 >"$SYNC_WORK/details/source-download-$name-output"
            step "source-check-$name" rclone check "$STAGE_DIR" "$SOURCE_ROOT/$name" --download --one-way --transfers 1 --checkers 1 >"$SYNC_WORK/details/source-check-$name-output"
            HASH=$(sha256sum "$STAGE_DIR/complete.age")
            [[ ${HASH%% *} == "$EXPECTED_HASH" ]] || {
                infra_error "Snapshot $name from the source remote has a different ownership marker."; exit 1;
            }
        fi

        step "upload-$name" rclone copy "$STAGE_DIR" "$TARGET_SNAP" --exclude /complete.age "${RCLONE_UP[@]}" >"$SYNC_WORK/details/upload-$name-output"
        step "read-back-$name" rclone check "$STAGE_DIR" "$TARGET_SNAP" --exclude /complete.age --download --one-way --transfers 1 --checkers 1 >"$SYNC_WORK/details/read-back-$name-output"
        step "payload-list-$name" rclone lsf "$TARGET_SNAP" --recursive --files-only | sort >"$SYNC_WORK/remote-files-$name"
        cmp -s "$SYNC_WORK/expected-payload-$name" "$SYNC_WORK/remote-files-$name" || {
            infra_error "The offsite payload paths for $name do not match the receipt."; exit 1;
        }
        step "completion-upload-$name" rclone copyto "$STAGE_DIR/complete.age" "$TARGET_SNAP/complete.age" "${RCLONE_UP[@]}" >"$SYNC_WORK/details/completion-upload-$name-output"
        step "completion-read-back-$name" rclone check "$STAGE_DIR" "$TARGET_SNAP" --download --one-way --transfers 1 --checkers 1 >"$SYNC_WORK/details/completion-read-back-$name-output"
        step "remote-list-$name" rclone lsf "$TARGET_SNAP" --recursive --files-only | sort >"$SYNC_WORK/remote-files-$name"
        cmp -s "$receipt/files" "$SYNC_WORK/remote-files-$name" || {
            infra_error "The offsite file paths for $name do not match the receipt."; exit 1;
        }
        SYNCED=$((SYNCED + 1))
        infra_log "Synced snapshot $name to $REMOTE_ROOT."
    fi

    NEW_PROOF=$(printf 'infrakit-snapshot-v1\n%s\n%s\n%s\n%s\n' "$JOB_ID" "$name" "${INFRA_PROOF[3]}" "$REMOTE_ROOT")
    printf '%s\n' "$NEW_PROOF" | infra_atomic "$receipt/proof"
    if [[ -d $ARCHIVE_DIR/$name && ! -L $ARCHIVE_DIR/$name && -f $ARCHIVE_DIR/$name/COMPLETE ]]; then
        printf '%s\n' "$NEW_PROOF" | infra_atomic "$ARCHIVE_DIR/$name/COMPLETE"
    fi
    if (( INFRA_PROOF[3] >= LATEST_STARTED )); then
        LATEST_STARTED=${INFRA_PROOF[3]}
        LATEST_SNAPSHOT=$name
        LATEST_PROOF=$NEW_PROOF
    fi
done

for directory in "$ARCHIVE_DIR" "$STATE_DIR"; do
    printf '%s\n' "$OWNER" | infra_atomic "$directory/.infrakit-owner"
done
if [[ -n $LATEST_SNAPSHOT ]]; then
    printf '%s\n' "$LATEST_PROOF" | infra_atomic "$STATE_DIR/last-success"
    printf '%s\n' "$REMOTE_ROOT/$LATEST_SNAPSHOT" | infra_atomic "$STATE_DIR/offsite-enabled"
fi
infra_log "Sync verified: $SYNCED uploaded, $ALREADY_SYNCED already present on $REMOTE_ROOT."

if (( RERUN )); then
    rm -rf -- "$SYNC_WORK"
    SYNC_WORK=''
    trap - EXIT
    exec 9>&-
    exec bash "$INFRA_JOBS/backup.sh" "$JOB_FILE"
fi
