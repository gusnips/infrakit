#!/usr/bin/env bash
# Local-only rclone proof: missing files, repeat runs and failures. No cloud account.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "$HOME/.infrakit-sync-test-XXXXXX")
chmod 700 "$WORK"
trap 'rc=$?; if (( rc != 0 )); then cat "$WORK/out" 2>/dev/null || true; printf "Private test files kept in %s\n" "$WORK" >&2; else rm -rf -- "$WORK"; fi' EXIT
mkdir -m 700 "$WORK/source" "$WORK/target" "$WORK/bin"
printf 'first backup\n' >"$WORK/source/a.age"
printf 'target only\n' >"$WORK/target/keep.age"
cat >"$WORK/sync.conf" <<EOF
SOURCE_LOCAL_DIR=$WORK/source
TARGET_LOCAL_DIR=$WORK/target
SOURCE_PREFIX=''
TARGET_PREFIX=''
STATE_DIR=$WORK/state
EOF
chmod 600 "$WORK/sync.conf"
REAL_RCLONE=$(command -v rclone)
export REAL_RCLONE
cat >"$WORK/bin/rclone" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${TEST_FAIL:-} == list && $1 == lsjson ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == copy && $1 == copy ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == verify && $1 == check ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == mutate && $1 == copy ]]; then
  "$REAL_RCLONE" "$@"
  printf 'late addition\n' >"$TEST_SOURCE/late.age"
  exit 0
fi
exec "$REAL_RCLONE" "$@"
SH
chmod 700 "$WORK/bin/rclone"
export PATH="$WORK/bin:$PATH" TEST_SOURCE="$WORK/source"
run() { bash "$ROOT/jobs/backup-sync.sh" "$WORK/sync.conf" >"$WORK/out" 2>&1; }
fails() { if run; then cat "$WORK/out"; printf 'Expected failure: %s\n' "$1" >&2; exit 1; fi; }
run
cmp "$WORK/source/a.age" "$WORK/target/a.age"
test -f "$WORK/target/keep.age"
cp "$WORK/state/last-copy" "$WORK/proof"
before=$(stat -c %Y "$WORK/target/a.age")
run
[[ $(stat -c %Y "$WORK/target/a.age") == "$before" ]]
printf 'later backup\n' >"$WORK/source/b.age"
run
cmp "$WORK/source/b.age" "$WORK/target/b.age"
cp "$WORK/state/last-copy" "$WORK/proof"
printf 'wrong bytes!\n' >"$WORK/target/b.age"
fails 'same-size corrupt destination'
cmp "$WORK/proof" "$WORK/state/last-copy"
[[ $(<"$WORK/target/b.age") == 'wrong bytes!' ]]
rm "$WORK/target/b.age"
run
for failure in list copy verify; do
  mkdir -p "$WORK/source/pending"
  printf 'new payload\n' >"$WORK/source/pending/payload.age"
  printf 'completion\n' >"$WORK/source/pending/complete.age"
  export TEST_FAIL=$failure
  cp "$WORK/state/last-copy" "$WORK/proof"
  fails "$failure"
  cmp "$WORK/proof" "$WORK/state/last-copy"
  [[ ! -e $WORK/target/pending/complete.age ]]
done
unset TEST_FAIL
run
cmp "$WORK/source/pending/complete.age" "$WORK/target/pending/complete.age"
export TEST_FAIL=mutate
fails 'source changed during copy'
unset TEST_FAIL
run
printf 'physical repository\n' >"$WORK/source/backup.info"
fails 'pgBackRest repository'
rm "$WORK/source/backup.info"
# Empty source is not a completed migration.
mv "$WORK/source" "$WORK/source-full"
mkdir -m 700 "$WORK/source"
fails 'empty source'
rmdir "$WORK/source"
mv "$WORK/source-full" "$WORK/source"
# Changing the transfer target cannot reuse the previous transfer state.
cp "$WORK/sync.conf" "$WORK/clean.conf"
printf 'TARGET_PREFIX=other\n' >>"$WORK/sync.conf"
fails 'different transfer state'
cp "$WORK/clean.conf" "$WORK/sync.conf"
printf 'TARGET_LOCAL_DIR=%s/source\n' "$WORK" >>"$WORK/sync.conf"
fails 'same source and target'
cp "$WORK/clean.conf" "$WORK/sync.conf"
printf 'SOURCE_PREFIX=../unsafe\n' >>"$WORK/sync.conf"
fails 'unsafe prefix'
# Private configuration must be enforced before a transfer starts.
cp "$WORK/clean.conf" "$WORK/sync.conf"
chmod 644 "$WORK/sync.conf"
fails 'public config'
printf 'Backup copy checks passed: first copy, repeat, new files, corrupt bytes, failed commands, source changes, pgBackRest refusal, empty source and private configuration.\n'
