#!/usr/bin/env bash
# A complete df scan and delivered mail precede every state update.
# shellcheck disable=SC2015
set +x +v
set -euo pipefail
umask 077
INFRA_JOBS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$INFRA_JOBS/lib.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash diskwatch.sh <private-config>\nChecks disk space, inodes and free space on a separate /boot filesystem.\nSends warnings and recovery mail only when a level changes.\n'
    exit 0
fi
infra_runtime
infra_require df flock sha256sum sort
[[ $# == 1 ]] || { infra_error 'Pass one private disk configuration file. Use --help for the command.'; exit 2; }
unset STATE_DIR ALERT_CONFIG DISK_LABEL DISK_WARN DISK_CRIT INODE_WARN INODE_CRIT MIN_FILESYSTEM_BYTES BOOT_MOUNT BOOT_WARN_FREE_BYTES BOOT_CRIT_FREE_BYTES
REQUIRED_MOUNTS=()
infra_source "$1"
[[ -n ${STATE_DIR:-} && -n ${ALERT_CONFIG:-} ]] || { infra_error 'Disk checks need STATE_DIR and ALERT_CONFIG. Set a private state directory and SMTP configuration file.'; exit 1; }
infra_dir "$STATE_DIR"
infra_lock "$STATE_DIR/disk.lock"
infra_private "$ALERT_CONFIG"
DISK_LABEL=${DISK_LABEL:-$(hostname)}
infra_single_line "$DISK_LABEL" || { infra_error 'DISK_LABEL must be one nonempty line. Fix the disk configuration.'; exit 1; }
DISK_WARN=${DISK_WARN:-80} DISK_CRIT=${DISK_CRIT:-90}
INODE_WARN=${INODE_WARN:-80} INODE_CRIT=${INODE_CRIT:-90}
MIN_FILESYSTEM_BYTES=${MIN_FILESYSTEM_BYTES:-1073741824}
BOOT_MOUNT=${BOOT_MOUNT:-/boot}
BOOT_WARN_FREE_BYTES=${BOOT_WARN_FREE_BYTES:-134217728}
BOOT_CRIT_FREE_BYTES=${BOOT_CRIT_FREE_BYTES:-67108864}
for field in DISK_WARN DISK_CRIT INODE_WARN INODE_CRIT; do
    [[ ${!field} =~ ^[1-9][0-9]?$|^100$ ]] || { infra_error "$field must be 1 to 100. Fix the disk configuration."; exit 1; }
done
(( DISK_WARN < DISK_CRIT && INODE_WARN < INODE_CRIT )) || { infra_error 'Warning percentages must be below critical percentages. Fix the disk configuration.'; exit 1; }
for field in MIN_FILESYSTEM_BYTES BOOT_WARN_FREE_BYTES BOOT_CRIT_FREE_BYTES; do
    [[ ${!field} =~ ^[1-9][0-9]{0,17}$ ]] || { infra_error "$field must be a positive byte count. Fix the disk configuration."; exit 1; }
done
(( BOOT_WARN_FREE_BYTES > BOOT_CRIT_FREE_BYTES )) || { infra_error 'BOOT_WARN_FREE_BYTES must exceed BOOT_CRIT_FREE_BYTES. Fix the disk configuration.'; exit 1; }
infra_absolute "$BOOT_MOUNT" || { infra_error 'BOOT_MOUNT must be an absolute mount path. Fix the disk configuration.'; exit 1; }
[[ $(declare -p REQUIRED_MOUNTS) == 'declare -a '* ]] || { infra_error 'REQUIRED_MOUNTS must be an indexed Bash array. Use parentheses in the disk configuration.'; exit 1; }
for mount in "${REQUIRED_MOUNTS[@]}"; do
    [[ $mount == / ]] || infra_absolute "$mount" || { infra_error 'A required mount path is not absolute. Fix REQUIRED_MOUNTS.'; exit 1; }
done
STATE="$STATE_DIR/disk-delivered.tsv"
WORK=$(mktemp -d "$STATE_DIR/.disk-scan.XXXXXX")
cleanup() {
    local result=$?
    trap - EXIT
    if (( result == 0 )); then rm -rf -- "$WORK"
    else infra_error "Disk check failed. Fix the reported step and retry. Private details remain in $WORK."; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Resolve trusted Bash once, then give the shared sender only literal values.
# The hash and delivery must refer to the same route even if the original file changes.
(
    unset SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM SMTP_TO SMTP_TRANSPORT
    SMTP_TO=()
    infra_source "$ALERT_CONFIG"
    for field in SMTP_HOST SMTP_USER SMTP_PASS SMTP_FROM; do
        infra_single_line "${!field:-}" || { infra_error "Mail is missing $field. Fix ALERT_CONFIG before scheduling disk checks."; exit 1; }
    done
    [[ $(declare -p SMTP_TO) == 'declare -a '* && ${#SMTP_TO[@]} -gt 0 ]] || { infra_error 'Mail needs a nonempty SMTP_TO array. Fix ALERT_CONFIG.'; exit 1; }
    for recipient in "${SMTP_TO[@]}"; do
        infra_single_line "$recipient" || { infra_error 'SMTP_TO has an empty address or control character. Use bare email addresses and retry.'; exit 1; }
    done
    SMTP_PORT=${SMTP_PORT:-587} SMTP_TRANSPORT=${SMTP_TRANSPORT:-starttls}
    {
        for field in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM SMTP_TRANSPORT; do
            printf '%s=%q\n' "$field" "${!field}"
        done
        printf 'SMTP_TO=('
        printf ' %q' "${SMTP_TO[@]}"
        printf ' )\n'
    } >"$WORK/alert.conf"
    {
        # SMTP_HOST and SMTP_FROM are loaded and checked indirectly above.
        # shellcheck disable=SC2153
        printf '%s\n' "$SMTP_HOST" "$SMTP_PORT" "$SMTP_FROM" "$SMTP_TRANSPORT"
        printf '%s\n' "${SMTP_TO[@]}" | sort
    } | sha256sum >"$WORK/channel"
)
CHANNEL=$(<"$WORK/channel")
CHANNEL=${CHANNEL%% *}
ALERT_CONFIG="$WORK/alert.conf"
infra_log "Checking disk space and inodes on $DISK_LABEL."
for kind in disk inode; do
    columns=size,pcent,avail,target
    [[ $kind != inode ]] || columns=itotal,ipcent,iavail,target
    if ! df -B1 --local --output="$columns" -x tmpfs -x devtmpfs -x overlay -x squashfs >"$WORK/$kind" 2>"$WORK/df-details"; then
        infra_error 'df could not read the local filesystems. Check mounts and permissions, then retry. Delivered alert state was kept.'
        exit 1
    fi
done
declare -A sizes=() percentages=() free_bytes=() inode_percentages=() seen=()
MOUNTS=()
for kind in disk inode; do
    first=1 rows=0
    while IFS= read -r row || [[ -n $row ]]; do
        if (( first )); then
            first=0
            if [[ $kind == disk ]]; then header='^[[:space:]]*1B-blocks[[:space:]]+Use%[[:space:]]+Avail[[:space:]]+Mounted on[[:space:]]*$'
            else header='^[[:space:]]*Inodes[[:space:]]+IUse%[[:space:]]+IFree[[:space:]]+Mounted on[[:space:]]*$'; fi
            [[ $row =~ $header ]] || { infra_error 'df returned an unexpected header. Use GNU df, then retry. Delivered alert state was kept.'; exit 1; }
            continue
        fi
        pattern='^[[:space:]]*([0-9]{1,18})[[:space:]]+(0|[1-9][0-9]*)%[[:space:]]+(-?[0-9]{1,18})[[:space:]]+(/.*)$'
        [[ $row =~ $pattern ]] || { infra_error 'df returned an empty or malformed filesystem row. Check GNU df and mounts, then retry. Delivered alert state was kept.'; exit 1; }
        size=${BASH_REMATCH[1]} percent=${BASH_REMATCH[2]} available=${BASH_REMATCH[3]} mount=${BASH_REMATCH[4]}
        # GNU df can exceed 100% when nonroot availability is negative.
        # Keep its usage percentage; zero is the free-byte floor.
        if [[ $available == -* ]]; then available=0; else available=$((10#$available)); fi
        infra_single_line "$mount" && (( 10#$size > 0 && available <= 10#$size )) || {
            infra_error 'df returned invalid sizes, percentages or a mount path. Check the filesystem, then retry. Delivered alert state was kept.'; exit 1;
        }
        [[ -z ${seen[$kind:$mount]:-} ]] || { infra_error 'df returned a duplicate mount. Check the mount table, then retry. Delivered alert state was kept.'; exit 1; }
        seen[$kind:$mount]=1
        rows=$((rows + 1))
        if [[ $kind == disk ]]; then
            sizes[$mount]=$((10#$size)); percentages[$mount]=$percent; free_bytes[$mount]=$available; MOUNTS+=("$mount")
        else inode_percentages[$mount]=$percent; fi
    done <"$WORK/$kind"
    (( rows > 0 )) || { infra_error 'df returned no filesystems. Check mounts and GNU df, then retry. Delivered alert state was kept.'; exit 1; }
done
for mount in "${MOUNTS[@]}"; do
    [[ -n ${inode_percentages[$mount]:-} ]] || { infra_error 'Disk and inode scans disagree. A mount may have changed during the scan; retry. Delivered alert state was kept.'; exit 1; }
done
(( ${#MOUNTS[@]} == ${#inode_percentages[@]} )) || { infra_error 'Disk and inode scans disagree. Retry after the mount table is stable; delivered alert state was kept.'; exit 1; }
for mount in "${REQUIRED_MOUNTS[@]}"; do
    [[ -n ${sizes[$mount]:-} ]] || { infra_error "Required filesystem $mount is missing. Restore its mount before retrying. Delivered alert state was kept."; exit 1; }
done
declare -A previous=()
active_channel=''
if [[ -e $STATE || -L $STATE ]]; then
    infra_private "$STATE"
    {
        IFS= read -r version && IFS= read -r active_channel &&
            [[ $version == infrakit-disk-v1 && $active_channel =~ ^[0-9a-f]{64}$ ]] || {
            infra_error 'Delivered disk state is malformed. Inspect its private TSV file before retrying; it was not replaced.'; exit 1;
        }
        while IFS=$'\t' read -r level mount extra || [[ -n $level$mount${extra:-} ]]; do
            [[ $level =~ ^(ok|warn|crit)$ && $mount == /* && -z ${extra:-} && -z ${previous[$mount]:-} ]] && infra_single_line "$mount" || {
                infra_error 'Delivered disk state is malformed. Inspect its private TSV file before retrying; it was not replaced.'; exit 1;
            }
            previous[$mount]=$level
        done
    } <"$STATE"
fi
# There is one active route, not a history of routes whose old levels can revive.
if [[ $active_channel != "$CHANNEL" ]]; then previous=(); fi
watched=0 changes=0
printf 'infrakit-disk-v1\n%s\n' "$CHANNEL" >"$WORK/current"
: >"$WORK/message"
for mount in "${MOUNTS[@]}"; do
    # Bash 5.1 can execute text in an arithmetic associative-array subscript.
    # Read every numeric mount value through parameter expansion first.
    size=${sizes[$mount]} percent=${percentages[$mount]}
    inode_percent=${inode_percentages[$mount]} available=${free_bytes[$mount]}
    if (( size < MIN_FILESYSTEM_BYTES )) && [[ $mount != "$BOOT_MOUNT" ]]; then continue; fi
    watched=$((watched + 1))
    level=ok
    # Canonical percentages of three or more digits are always critical.
    # Compare their length before arithmetic so a real high value cannot overflow.
    if [[ ${#percent} -ge 3 || ${#inode_percent} -ge 3 ]] || (( percent >= DISK_CRIT || inode_percent >= INODE_CRIT )); then level=crit
    elif (( percent >= DISK_WARN || inode_percent >= INODE_WARN )); then level=warn; fi
    if [[ $mount == "$BOOT_MOUNT" ]]; then
        if (( available <= BOOT_CRIT_FREE_BYTES )); then level=crit
        elif (( available <= BOOT_WARN_FREE_BYTES )) && [[ $level == ok ]]; then level=warn; fi
    fi
    printf '%s\t%s\n' "$level" "$mount" >>"$WORK/current"
    [[ $level != "${previous[$mount]:-ok}" ]] || continue
    changes=$((changes + 1))
    {
        case $level in crit) printf 'Disk critical: %s\n' "$mount" ;; warn) printf 'Disk warning: %s\n' "$mount" ;; ok) printf 'Disk recovered: %s\n' "$mount" ;; esac
        printf 'Space used: %s%%. Free: %s bytes of %s bytes. Inodes used: %s%%.\n' "$percent" "$available" "$size" "$inode_percent"
        if [[ $level != ok ]]; then
            printf 'Free space or remove files you no longer need on this filesystem. Do not delete live database files.\n'
            [[ $mount != "$BOOT_MOUNT" ]] || printf 'Check old kernels with your package manager; a full boot filesystem can block updates.\n'
        fi
        printf '\n'
    } >>"$WORK/message"
done
(( watched > 0 )) || { infra_error 'No filesystem meets the disk size floor, and no separate boot filesystem was found. Check MIN_FILESYSTEM_BYTES and mounts; delivered alert state was kept.'; exit 1; }
if (( changes > 0 )); then
    if ! infra_alert "Disk changes on $DISK_LABEL" "$(<"$WORK/message")"; then
        infra_error 'Disk alert mail did not send. Check ALERT_CONFIG and retry; delivered state was kept so the next run tries again.'
        exit 1
    fi
fi
# A complete healthy scan can change the active route without claiming a delivery.
if [[ $active_channel != "$CHANNEL" ]] && (( changes == 0 )); then
    printf 'infrakit-disk-v1\n%s\n' "$CHANNEL" | infra_atomic "$STATE"
else infra_atomic "$STATE" <"$WORK/current"; fi
infra_log "Disk check finished: $watched filesystems checked, $changes changes delivered."
