#!/usr/bin/env bash
# Local-only proof of both backup formats. No database, cloud account or retained age key.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/infrakit
mkdir -p "$CACHE"
WORK=$(mktemp -d "$CACHE/backup-encryption-XXXXXX")
trap 'rc=$?; if (( rc != 0 )); then cat "$WORK/out" 2>/dev/null || true; printf "Private test files kept in %s\n" "$WORK" >&2; else rm -rf -- "$WORK"; fi' EXIT
mkdir -m 700 "$WORK/bin"
REAL_RCLONE=$(command -v rclone)
REAL_AGE=$(command -v age)
export REAL_RCLONE REAL_AGE
age-keygen -o "$WORK/identity" >"$WORK/keygen.log" 2>&1
RECIPIENT=$(age-keygen -y "$WORK/identity")
cat >"$WORK/bin/age" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'age\n' >>"$TEST_TRACE"
[[ $TEST_ENCRYPTION == age ]] || exit 90
exec "$REAL_AGE" "$@"
SH
cat >"$WORK/bin/rclone" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_TRACE"
if [[ $TEST_OPERATION == backup ]]; then
  if [[ $1 == copy && ${TEST_FAIL:-} == payload ]]; then
    "$REAL_RCLONE" "$@"
    exit 91
  fi
  if [[ $1 == check && $* == *'--exclude '* ]]; then
    [[ ! -e ${3#backup:}/$TEST_MARKER ]]
    "$REAL_RCLONE" "$@"
    printf 'payload-verified\n' >>"$TEST_TRACE"
    exit 0
  fi
  if [[ $1 == copyto ]]; then grep -Fxq payload-verified "$TEST_TRACE"; fi
  if [[ $1 == deletefile ]]; then
    case $2 in
      */complete|*/complete.age)
        path=${2#backup:}
        [[ -z $(find "${path%/*}" -type f ! -name "${path##*/}" -print -quit) ]]
        ;;
      *)
        if [[ ${TEST_FAIL:-} == partial-prune ]]; then
          "$REAL_RCLONE" "$@"
          exit 92
        fi
        ;;
    esac
  fi
else
  if [[ $1 == copy && $* == *'/marker-files'* ]]; then
    grep -Fxq payload-verified "$TEST_TRACE"
  fi
  if [[ $1 == copy && $* == *'/payload-files'* && ${TEST_FAIL:-} == payload ]]; then
    "$REAL_RCLONE" "$@"
    exit 93
  fi
  if [[ $1 == check && $* == *'/new-payload-files'* ]]; then
    [[ ! -e $TEST_TARGET/$TEST_MARKER ]]
    "$REAL_RCLONE" "$@"
    printf 'payload-verified\n' >>"$TEST_TRACE"
    if [[ ${TEST_FAIL:-} == late-marker ]]; then
      mkdir -p "$TEST_SOURCE/late"
      printf 'late payload\n' >"$TEST_SOURCE/late/payload"
      printf 'late marker\n' >"$TEST_SOURCE/late/$TEST_MARKER"
    fi
    exit 0
  fi
fi
exec "$REAL_RCLONE" "$@"
SH
chmod 700 "$WORK/bin/age" "$WORK/bin/rclone"
export PATH="$WORK/bin:$PATH" TEST_TRACE="$WORK/trace" TEST_OPERATION=backup
run_backup() { : >"$TEST_TRACE"; BACKUP_ENCRYPTION=none bash "$ROOT/jobs/backup.sh" "$JOB" >"$WORK/out" 2>&1; }
fails_backup() { if run_backup; then printf 'Expected backup failure: %s\n' "$1" >&2; exit 1; fi; }
inspect_backup() (
  # shellcheck source=../jobs/lib.sh
  source "$ROOT/jobs/lib.sh"
  # shellcheck source=../jobs/inspect.sh
  source "$ROOT/jobs/inspect.sh"
  probe_clock clock >/dev/null
  probe_backup backup "$STATE" 86400 nightly "$ARCHIVE" "$REMOTE_ROOT" "$EUID"
)
old_snapshot() {
  OLD=20000101T010101Z-AbCd12
  OLD_REMOTE="$REMOTE/$OLD"; OLD_LOCAL="$ARCHIVE/$OLD"; OLD_RECEIPT="$STATE/receipts/$OLD"
  mkdir -p "$OLD_REMOTE" "$OLD_LOCAL" "$OLD_RECEIPT"
  cp "$FIRST_REMOTE/"* "$OLD_REMOTE/"
  printf 'infrakit-snapshot-v1\nnightly\n%s\n%s\n%s\n' "$OLD" "$(( $(date +%s) - 40 * 86400 ))" "$REMOTE_ROOT" >"$OLD_RECEIPT/proof"
  cp "$OLD_RECEIPT/proof" "$OLD_LOCAL/COMPLETE"
  cp "$FIRST_RECEIPT/files" "$OLD_RECEIPT/files"
  rm "$OLD_REMOTE/$OLD_MARKER"
  if [[ $MODE == age ]]; then
    "$REAL_AGE" -r "$RECIPIENT" -o "$OLD_REMOTE/$OLD_MARKER" "$OLD_RECEIPT/proof"
  else
    cp "$OLD_RECEIPT/proof" "$OLD_REMOTE/$OLD_MARKER"
  fi
  local hash
  hash=$(sha256sum "$OLD_REMOTE/$OLD_MARKER")
  printf '%s\n' "${hash%% *}" >"$OLD_RECEIPT/complete.sha256"
}
for MODE in none age; do
  BASE="$WORK/$MODE"; ARCHIVE="$BASE/archive"; STATE="$BASE/state"; JOB="$BASE/job.conf"
  REMOTE="$BASE/offsite/test/nightly"; REMOTE_ROOT="backup:$REMOTE"
  mkdir -m 700 "$BASE"
  printf 'recovery fixture\n' >"$BASE/settings.conf"
  {
    printf 'JOB_ID=nightly\nPROFILE=files\nBACKEND=local\nREMOTE_PREFIX=test/nightly\n'
    printf 'ARCHIVE_DIR=%q\nSTATE_DIR=%q\nLOCAL_REMOTE_DIR=%q\nCONFIG_PATHS=(%q)\n' "$ARCHIVE" "$STATE" "$BASE/offsite" "$BASE/settings.conf"
    if [[ $MODE == none ]]; then printf 'BACKUP_ENCRYPTION=none\n'; else printf 'BACKUP_AGE_RECIPIENT=%q\n' "$RECIPIENT"; fi
  } >"$JOB"
  TEST_ENCRYPTION=$MODE; TEST_MARKER=complete
  [[ $MODE != age ]] || TEST_MARKER=complete.age
  export TEST_ENCRYPTION TEST_MARKER
  run_backup
  mapfile -t proof <"$STATE/last-success"
  [[ ${#proof[@]} == 5 && ${proof[0]} == infrakit-snapshot-v1 ]]
  FIRST_REMOTE="$REMOTE/${proof[2]}"; FIRST_RECEIPT="$STATE/receipts/${proof[2]}"; OLD_MARKER=$TEST_MARKER
  [[ $(find "$FIRST_REMOTE" -type f | wc -l) == 3 ]]
  if [[ $MODE == none ]]; then
    cmp "$STATE/last-success" "$FIRST_REMOTE/complete"
    cmp "$ARCHIVE/${proof[2]}/plain/configs.tar.gz" "$FIRST_REMOTE/configs.tar.gz"
    if grep -Fxq age "$TEST_TRACE"; then printf 'Raw mode called age\n' >&2; exit 1; fi
  else
    "$REAL_AGE" -d -i "$WORK/identity" -o "$BASE/restored-proof" "$FIRST_REMOTE/complete.age"
    cmp "$STATE/last-success" "$BASE/restored-proof"
  fi
  [[ $(inspect_backup) == $'pass\tbackup\t'* ]]
  cp "$FIRST_RECEIPT/files" "$BASE/files"
  for invalid in missing unknown mixed incomplete; do
    case $invalid in
      missing) grep -Fxv "$OLD_MARKER" "$BASE/files" >"$FIRST_RECEIPT/files" ;;
      unknown) { grep -Fxv "$OLD_MARKER" "$BASE/files"; printf 'complete.unknown\n'; } | sort >"$FIRST_RECEIPT/files" ;;
      mixed) { cat "$BASE/files"; printf 'complete\ncomplete.age\n'; } | sort -u >"$FIRST_RECEIPT/files" ;;
      incomplete) printf '%s\nmanifest.txt%s\n' "$OLD_MARKER" "${OLD_MARKER#complete}" >"$FIRST_RECEIPT/files" ;;
    esac
    [[ $(inspect_backup) == $'finding\tbackup\t'* ]]
  done
  cp "$BASE/files" "$FIRST_RECEIPT/files"
  cp "$STATE/last-success" "$BASE/previous-proof"
  export TEST_FAIL=payload
  fails_backup 'payload transfer did not finish'
  cmp "$STATE/last-success" "$BASE/previous-proof"
  [[ $(find "$REMOTE" -name "$TEST_MARKER" | wc -l) == 1 ]]
  unset TEST_FAIL

  old_snapshot
  # New raw runs must still safely prune receipts from earlier encrypted runs.
  if [[ $MODE == age ]]; then
    printf 'BACKUP_ENCRYPTION=none\n' >>"$JOB"
    TEST_ENCRYPTION=none; TEST_MARKER=complete
  fi
  printf 'unowned\n' >"$OLD_REMOTE/unknown"
  fails_backup 'unowned remote object'
  [[ -e $OLD_REMOTE/$OLD_MARKER && -e $OLD_LOCAL/COMPLETE ]]
  if grep -q '^deletefile ' "$TEST_TRACE"; then exit 1; fi
  rm "$OLD_REMOTE/unknown"
  cp "$OLD_REMOTE/$OLD_MARKER" "$BASE/marker"
  printf 'changed marker\n' >"$OLD_REMOTE/$OLD_MARKER"
  fails_backup 'ownership marker hash changed'
  if grep -q '^deletefile ' "$TEST_TRACE"; then exit 1; fi
  cp "$BASE/marker" "$OLD_REMOTE/$OLD_MARKER"
  cp "$OLD_RECEIPT/files" "$BASE/old-files"
  { grep -Fxv "$OLD_MARKER" "$BASE/old-files"; printf 'complete.unknown\n'; } | sort >"$OLD_RECEIPT/files"
  fails_backup 'unknown receipt marker'
  [[ -e $OLD_REMOTE/$OLD_MARKER && -e $OLD_LOCAL/COMPLETE ]]
  cp "$BASE/old-files" "$OLD_RECEIPT/files"
  export TEST_FAIL=partial-prune
  fails_backup 'interrupted prune'
  [[ -e $OLD_REMOTE/$OLD_MARKER && -e $OLD_LOCAL/COMPLETE ]]
  unset TEST_FAIL
  run_backup
  [[ ! -e $OLD_REMOTE/$OLD_MARKER && ! -e $OLD_LOCAL ]]
  [[ $(grep '^deletefile ' "$TEST_TRACE" | tail -1) == *"/$OLD_MARKER" ]]
  [[ $(inspect_backup) == $'pass\tbackup\t'* ]]

  TEST_OPERATION=sync; TEST_MARKER=$OLD_MARKER
  TEST_SOURCE=$FIRST_REMOTE; TEST_TARGET="$BASE/copy"
  export TEST_OPERATION TEST_SOURCE TEST_TARGET
  {
    printf 'SOURCE_LOCAL_DIR=%q\nTARGET_LOCAL_DIR=%q\nSTATE_DIR=%q\nSOURCE_PREFIX=\x27\x27\nTARGET_PREFIX=\x27\x27\n' "$TEST_SOURCE" "$TEST_TARGET" "$BASE/copy-state"
  } >"$BASE/sync.conf"
  run_sync() { : >"$TEST_TRACE"; bash "$ROOT/jobs/backup-sync.sh" "$BASE/sync.conf" >"$WORK/out" 2>&1; }
  for TEST_FAIL in payload late-marker; do
    export TEST_FAIL
    if run_sync; then printf 'Expected copy failure: %s\n' "$TEST_FAIL" >&2; exit 1; fi
    [[ ! -e $TEST_TARGET/$TEST_MARKER && ! -e $BASE/copy-state/last-copy ]]
    [[ ! -e $TEST_TARGET/late/$TEST_MARKER ]]
    rm -rf -- "$TEST_SOURCE/late"
  done
  unset TEST_FAIL
  run_sync
  cmp "$TEST_SOURCE/$TEST_MARKER" "$TEST_TARGET/$TEST_MARKER"
  [[ -s $BASE/copy-state/last-copy ]]
  TEST_OPERATION=backup
  printf '%s backup format passed publication, inspection, retention and copy ordering.\n' "$MODE"
done
# A missing recipient or inherited raw setting must never silently disable default encryption.
printf 'unset BACKUP_ENCRYPTION BACKUP_AGE_RECIPIENT\n' >>"$JOB"
fails_backup 'default encryption without a recipient'
printf 'BACKUP_ENCRYPTION=unknown\n' >>"$JOB"
fails_backup 'unknown encryption setting'
printf 'Backup encryption checks passed.\n'
