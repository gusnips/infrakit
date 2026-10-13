#!/usr/bin/env bash
# Local fakes only. Nothing reads real disks or sends mail.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "$ROOT/tests/.diskwatch-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
export TEST_WORK=$WORK
export PATH="$WORK/bin:$PATH"
fail() { printf 'diskwatch check failed: %s\n' "$*" >&2; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "Expected $2 in ${1##*/}"; }
mail_count() { local count=0; [[ ! -f $WORK/mail-count ]] || read -r count <"$WORK/mail-count"; printf '%s' "$count"; }
assert_mail() { [[ $(mail_count) == "$1" ]] || fail "Expected $1 mail attempts, got $(mail_count)"; }
run_job() {
    local result=0
    bash "$ROOT/jobs/diskwatch.sh" "$WORK/disk.conf" >"$WORK/stdout" 2>"$WORK/stderr" || result=$?
    if [[ $1 == pass ]]; then
        (( result == 0 )) || { cat "$WORK/stderr" >&2; fail 'Disk job should pass'; }
    else
        (( result != 0 )) || fail 'Disk job should fail closed'
    fi
}
state_file() {
    [[ -f $WORK/state/disk-delivered.tsv ]] || fail 'Expected one active delivered state file'
    printf '%s' "$WORK/state/disk-delivered.tsv"
}
scan() {
    local disk=${1:-20} inode=${2:-20} boot=${3:-200000000} root_free=${4:-4000000000}
    printf '1B-blocks Use%% Avail Mounted on\n5000000000 %s%% %s /\n2000000000 %s%% 500000000 /data with spaces\n500000000 20%% %s /boot\n10000000 99%% 10000 /small\n' "$disk" "$root_free" "$disk" "$boot" >"$WORK/disk"
    printf 'Inodes IUse%% IFree Mounted on\n100000 %s%% 50000 /\n100000 %s%% 50000 /data with spaces\n10000 20%% 8000 /boot\n1000 99%% 10 /small\n' "$inode" "$inode" >"$WORK/inode"
}
mail_config() {
    local sender=$1; shift
    {
        printf "SMTP_HOST='smtp.example.com'\nSMTP_USER='test'\nSMTP_PASS='fixture-secret'\nSMTP_FROM='%s'\nSMTP_TO=(" "$sender"
        printf ' %q' "$@"
        printf ' )\n'
    } >"$WORK/alert.conf"
}
cat >"$WORK/bin/df" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f $TEST_WORK/df-fail ]]; then printf 'fixture df error\n' >&2; exit 1; fi
if [[ -f $TEST_WORK/change-route ]]; then
    cp -- "$TEST_WORK/replacement.conf" "$TEST_WORK/alert.conf"
    rm -- "$TEST_WORK/change-route"
fi
for arg in "$@"; do
    case $arg in
        --output=size,pcent,avail,target) cat "$TEST_WORK/disk"; exit ;;
        --output=itotal,ipcent,iavail,target) cat "$TEST_WORK/inode"; exit ;;
    esac
done
printf 'Unexpected df arguments\n' >&2
exit 1
SH
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && $1 == -q && $2 == --config ]] || exit 90
[[ $(stat -c %a -- "$3") == 600 ]] || exit 91
[[ $(stat -c %a -- "${3%/*}") == 700 ]] || exit 92
count=0
[[ ! -f $TEST_WORK/mail-count ]] || read -r count <"$TEST_WORK/mail-count"
printf '%s\n' "$((count + 1))" >"$TEST_WORK/mail-count"
upload=''
while IFS= read -r line; do
    case $line in 'upload-file = '*) upload=${line#*\"}; upload=${upload%\"} ;; esac
done <"$3"
[[ -n $upload ]] || exit 93
cp -- "$upload" "$TEST_WORK/last-message"
cp -- "$3" "$TEST_WORK/last-curl.conf"
printf '%s\n' "${3%/*}" >"$TEST_WORK/mail-work"
[[ ! -f $TEST_WORK/mail-fail ]] || exit 1
SH
chmod 700 "$WORK/bin/df" "$WORK/bin/curl"
{
    printf 'STATE_DIR=%q\nALERT_CONFIG=%q\n' "$WORK/state" "$WORK/alert.conf"
    printf "DISK_LABEL='fixture server'\nREQUIRED_MOUNTS=('/' '/data with spaces')\n"
} >"$WORK/disk.conf"
mail_config 'ops@example.com' 'one@example.com' 'two@example.com'

# Healthy scans create private state, but never send a fake recovery.
scan
run_job pass
assert_mail 0
STATE=$(state_file)
[[ $(stat -c %a -- "$STATE") == 600 && $(stat -c %a -- "$WORK/state") == 700 ]] || fail 'State permissions are not private'
contains "$STATE" 'infrakit-disk-v1'
mapfile -t state_lines <"$STATE"
[[ ${#state_lines[@]} == 2 ]] || fail 'First healthy route claimed delivered levels'
run_job pass
assert_mail 0
contains "$STATE" $'ok\t/data with spaces'
if grep -F '/small' "$STATE" >/dev/null; then fail 'The size floor did not skip a small filesystem'; fi

# Warning, critical and recovery each send once. Spaces are part of the mount key.
scan 80
old_inode=$(stat -c '%d:%i' -- "$STATE")
run_job pass
[[ $(stat -c '%d:%i' -- "$STATE") != "$old_inode" ]] || fail 'Delivered state was not replaced atomically'
assert_mail 1
contains "$WORK/last-message" 'Disk warning: /data with spaces'
run_job pass
assert_mail 1
scan 90
run_job pass
assert_mail 2
contains "$WORK/last-message" 'Disk critical: /'
scan 79
run_job pass
assert_mail 3
contains "$WORK/last-message" 'Disk recovered: /data with spaces'
scan 20 90
run_job pass
assert_mail 4
contains "$WORK/last-message" 'Inodes used: 90%'
scan 20 79
run_job pass
assert_mail 5

# /boot ignores the normal size floor and has inclusive free-byte thresholds.
scan 20 20 134217728
run_job pass
assert_mail 6
contains "$WORK/last-message" 'Disk warning: /boot'
scan 20 20 67108864
run_job pass
assert_mail 7
contains "$WORK/last-message" 'Disk critical: /boot'
scan
run_job pass
assert_mail 8
contains "$WORK/last-message" 'Disk recovered: /boot'

# A failed SMTP request must not acknowledge a change.
cp -- "$STATE" "$WORK/old-state"
scan 90
: >"$WORK/mail-fail"
run_job fail
assert_mail 9
cmp -s "$STATE" "$WORK/old-state" || fail 'SMTP failure replaced delivered state'
contains "$WORK/stderr" 'next run tries again'
rm -- "$WORK/mail-fail"
run_job pass
assert_mail 10
run_job pass
assert_mail 10
cp -- "$STATE" "$WORK/old-state"

# Every incomplete read leaves exactly the old state and sends no recovery.
: >"$WORK/df-fail"
run_job fail
rm -- "$WORK/df-fail"
cmp -s "$STATE" "$WORK/old-state" || fail 'Failed df replaced state'
contains "$WORK/stderr" 'retry'
for malformed in empty header-only header bad-row percent inode-percent duplicate mismatch missing-required; do
    scan
    case $malformed in
        empty) : >"$WORK/disk" ;;
        header-only) printf '1B-blocks Use%% Avail Mounted on\n' >"$WORK/disk" ;;
        header) printf 'wrong header\n' >"$WORK/disk" ;;
        bad-row) printf 'bad row\n' >>"$WORK/disk" ;;
        percent) scan -1 ;;
        inode-percent) scan 20 malformed ;;
        duplicate) printf '5000000000 20%% 4000000000 /\n' >>"$WORK/disk" ;;
        mismatch) printf '100000 20%% 50000 /extra\n' >>"$WORK/inode" ;;
        missing-required)
            printf '1B-blocks Use%% Avail Mounted on\n5000000000 20%% 4000000000 /\n' >"$WORK/disk"
            printf 'Inodes IUse%% IFree Mounted on\n100000 20%% 50000 /\n' >"$WORK/inode"
            ;;
    esac
    run_job fail
    cmp -s "$STATE" "$WORK/old-state" || fail "$malformed df replaced state"
    contains "$WORK/stderr" 'kept'
    assert_mail 10
done

# GNU df can report more than 100% with negative availability.
scan
run_job pass
assert_mail 11
scan 101 20 200000000 -1
run_job pass
assert_mail 12
contains "$WORK/last-message" 'Space used: 101%'
contains "$WORK/last-message" 'Free: 0 bytes'
contains "$STATE" $'crit\t/data with spaces'

# Lock contention stops a run before any delivered-state write or mail.
cp -- "$STATE" "$WORK/old-state"
exec 7>"$WORK/state/disk.lock"
flock -n 7
run_job fail
contains "$WORK/stderr" 'already running'
cmp -s "$STATE" "$WORK/old-state" || fail 'Locked scan replaced state'
assert_mail 12
flock -u 7
exec 7>&-

# Recipient order is irrelevant, while a new recipient or sender gets critical mail.
scan 90
mail_config 'ops@example.com' 'two@example.com' 'one@example.com'
run_job pass
# The root went from 101% to 90%, but its level stayed critical.
assert_mail 12
printf "SMTP_PASS='changed-fixture-secret'\n" >>"$WORK/alert.conf"
run_job pass
assert_mail 12
mail_config 'ops@example.com' 'new@example.com' 'one@example.com'
run_job pass
assert_mail 13
contains "$WORK/last-message" 'new@example.com'
mail_config 'other@example.com' 'new@example.com' 'one@example.com'
run_job pass
assert_mail 14
contains "$WORK/last-message" 'From: other@example.com'

# Without configured mail there is no delivered state. Enabling it sends at once.
rm -rf -- "$WORK/state"
rm -- "$WORK/alert.conf"
run_job fail
[[ ! -e $WORK/state/disk-delivered.tsv ]] || fail 'Unconfigured mail created delivered state'
mail_config 'ops@example.com' 'one@example.com'
run_job pass
assert_mail 15
contains "$WORK/last-message" 'Disk critical: /'
STATE=$(state_file)
cp -- "$STATE" "$WORK/old-state"
printf 'broken state\n' >"$STATE"
run_job fail
contains "$WORK/stderr" 'malformed'
[[ $(<"$STATE") == 'broken state' ]] || fail 'Malformed state was overwritten'
cp -- "$WORK/old-state" "$STATE"
chmod 644 "$WORK/disk.conf"
run_job fail
contains "$WORK/stderr" '0600'
assert_mail 15
chmod 600 "$WORK/disk.conf"

# A-critical, B-healthy, A-critical is a new incident, not old A state.
mail_config 'ops@example.com' 'two@example.com'
scan
run_job pass
assert_mail 15
mapfile -t state_lines <"$STATE"
[[ ${#state_lines[@]} == 2 ]] || fail 'Changed healthy route claimed delivered levels'
mail_config 'ops@example.com' 'one@example.com'
scan 90
run_job pass
assert_mail 16
contains "$WORK/last-message" 'Disk critical: /'

# A failed healthy scan on B cannot clear A. Failed B SMTP cannot acknowledge B.
cp -- "$STATE" "$WORK/old-state"
mail_config 'ops@example.com' 'two@example.com'
scan
: >"$WORK/df-fail"
run_job fail
rm -- "$WORK/df-fail"
cmp -s "$STATE" "$WORK/old-state" || fail 'Failed route-changing scan cleared active levels'
assert_mail 16
scan 90
: >"$WORK/mail-fail"
run_job fail
assert_mail 17
cmp -s "$STATE" "$WORK/old-state" || fail 'Failed route-changing delivery acknowledged its levels'
mail_work=$(<"$WORK/mail-work")
[[ -f $mail_work/details && $(stat -c %a -- "$mail_work") == 700 && $(stat -c %a -- "$mail_work/curl.conf") == 600 ]] || fail 'Failed SMTP diagnostics were lost or exposed'
rm -- "$WORK/mail-fail"
run_job pass
assert_mail 18
scan
run_job pass
assert_mail 19
contains "$WORK/last-message" 'Disk recovered: /'
run_job pass
assert_mail 19

# Freeze scalars and arrays once, including shell characters in a password.
mail_config 'ops@example.com' 'one@example.com'
printf 'printf loaded >>%q\n' "$WORK/config-loads" >>"$WORK/alert.conf"
password="space '\$(touch $WORK/password-ran) \\ end"
printf 'SMTP_PASS=%q\n' "$password" >>"$WORK/alert.conf"
cp -- "$WORK/alert.conf" "$WORK/original.conf"
mail_config 'ops@example.com' 'two@example.com'
cp -- "$WORK/alert.conf" "$WORK/replacement.conf"
cp -- "$WORK/original.conf" "$WORK/alert.conf"
: >"$WORK/change-route"
scan 90
run_job pass
assert_mail 20
contains "$WORK/last-message" 'To: one@example.com'
contains "$WORK/last-curl.conf" "\$(touch $WORK/password-ran)"
[[ $(<"$WORK/config-loads") == loaded && ! -e $WORK/password-ran ]] || fail 'Trusted SMTP code was reloaded or literal values executed'
# Restoring A cannot suppress mail A never received: A actually received the first mail.
cp -- "$WORK/original.conf" "$WORK/alert.conf"
run_job pass
assert_mail 20
mail_config 'ops@example.com' 'two@example.com'
run_job pass
assert_mail 21
contains "$WORK/last-message" 'To: two@example.com'

# Valid literal command text and spaces must stay safe in every numeric lookup,
# including the boot free-byte branch, with Bash 5.1 arithmetic semantics.
mount="/\$(touch $WORK/mount-ran)/data with spaces"
{
    printf 'BOOT_MOUNT=%q\nREQUIRED_MOUNTS=(' "$mount"
    printf ' %q' / "$mount"
    printf ' )\n'
} >>"$WORK/disk.conf"
for level in healthy warning critical recovered; do
    case $level in healthy|recovered) percent=20; inode_percent=20; available=200000000 ;;
        warning) percent=80; inode_percent=80; available=134217728 ;;
        critical) percent=90; inode_percent=90; available=67108864 ;;
    esac
    printf '1B-blocks Use%% Avail Mounted on\n5000000000 20%% 4000000000 /\n500000000 %s%% %s %s\n' "$percent" "$available" "$mount" >"$WORK/disk"
    printf 'Inodes IUse%% IFree Mounted on\n100000 20%% 50000 /\n10000 %s%% 8000 %s\n' "$inode_percent" "$mount" >"$WORK/inode"
    BASH_COMPAT=51 run_job pass
    [[ ! -e $WORK/mount-ran ]] || fail "$level scan executed literal mount text"
    contains "$STATE" "$mount"
done
assert_mail 25
contains "$WORK/last-message" "Disk recovered: $mount"

# Preserve real high percentages, including more than four digits, in the mail.
printf "BOOT_MOUNT=/boot\nREQUIRED_MOUNTS=('/' '/data with spaces')\n" >>"$WORK/disk.conf"
scan
run_job pass
for percent in 100 101 10000 999999999999999999 1844674407370955161500; do
    count=$(mail_count)
    scan "$percent" 20 200000000 -1
    BASH_COMPAT=51 run_job pass
    assert_mail "$((count + 1))"
    contains "$WORK/last-message" "Space used: $percent%"
    contains "$WORK/last-message" 'Free: 0 bytes'
    contains "$STATE" $'crit\t/data with spaces'
    scan
    run_job pass
    assert_mail "$((count + 2))"
    contains "$WORK/last-message" 'Disk recovered: /data with spaces'
done
count=$(mail_count)
scan 20 101
run_job pass
assert_mail "$((count + 1))"
contains "$WORK/last-message" 'Inodes used: 101%'
scan
run_job pass
assert_mail "$((count + 2))"

# Negative boot availability uses a zero free-byte floor even with low usage.
count=$(mail_count)
scan 20 20 -1
run_job pass
assert_mail "$((count + 1))"
contains "$WORK/last-message" 'Disk critical: /boot'
contains "$WORK/last-message" 'Free: 0 bytes'
scan
run_job pass
assert_mail "$((count + 2))"

# SMTP failure cannot record a high-percentage incident as delivered.
count=$(mail_count)
cp -- "$STATE" "$WORK/old-state"
scan 101 20 200000000 -1
: >"$WORK/mail-fail"
run_job fail
assert_mail "$((count + 1))"
cmp -s "$STATE" "$WORK/old-state" || fail 'High-percentage SMTP failure replaced state'
rm -- "$WORK/mail-fail"
run_job pass
assert_mail "$((count + 2))"
contains "$WORK/last-message" 'Space used: 101%'
run_job pass
assert_mail "$((count + 2))"
printf 'diskwatch checks passed\n'
