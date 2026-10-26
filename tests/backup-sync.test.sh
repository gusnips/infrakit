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
if [[ $1 == check ]]; then printf '%s\n' "$*" >>"$TEST_CHECK_LOG"; fi
if [[ ${TEST_FAIL:-} == nohash && $1 == check && $* != *--download* ]]; then
  printf 'NOTICE: 3 hashes could not be checked\n' >&2
  exit 0
fi
if [[ ${TEST_FAIL:-} == list && $1 == lsjson ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == copy && $1 == copy ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == verify && $1 == check ]]; then exit 1; fi
if [[ ${TEST_FAIL:-} == mutate && $1 == copy ]]; then
  "$REAL_RCLONE" "$@"
  printf 'late addition\n' >"$TEST_SOURCE/late.age"
  exit 0
fi
if [[ ${TEST_FAIL:-} == late-marker && $1 == check ]]; then
  "$REAL_RCLONE" "$@"
  mkdir -p "$TEST_SOURCE/late-snapshot"
  printf 'late payload\n' >"$TEST_SOURCE/late-snapshot/payload.age"
  printf 'late completion\n' >"$TEST_SOURCE/late-snapshot/complete.age"
  exit 0
fi
if [[ ${TEST_FAIL:-} == marker-pass && $1 == copy && $* == *'/marker-files'* ]]; then
  mkdir -p "$TEST_SOURCE/during-marker"
  printf 'new payload\n' >"$TEST_SOURCE/during-marker/payload.age"
  printf 'new completion\n' >"$TEST_SOURCE/during-marker/complete.age"
fi
exec "$REAL_RCLONE" "$@"
SH
chmod 700 "$WORK/bin/rclone"
export PATH="$WORK/bin:$PATH" TEST_SOURCE="$WORK/source" TEST_CHECK_LOG="$WORK/check.log"
: >"$TEST_CHECK_LOG"
newest_run() { find "$WORK/state" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-; }
new_files() { cat "$(newest_run)/new-files"; }
run() { bash "$ROOT/jobs/backup-sync.sh" "$WORK/sync.conf" >"$WORK/out" 2>&1; }
fails() { if run; then cat "$WORK/out"; printf 'Expected failure: %s\n' "$1" >&2; exit 1; fi; }
run
cmp "$WORK/source/a.age" "$WORK/target/a.age"
test -f "$WORK/target/keep.age"
[[ $(new_files) == a.age ]]
grep -q -- '--download' "$TEST_CHECK_LOG"
cp "$WORK/state/last-copy" "$WORK/proof"
before=$(stat -c %Y "$WORK/target/a.age")
: >"$TEST_CHECK_LOG"
run
[[ $(stat -c %Y "$WORK/target/a.age") == "$before" ]]
# A file that already passed the byte check is compared by size and hash, with no download.
[[ -z $(new_files) ]]
if grep -q -- '--download' "$TEST_CHECK_LOG"; then cat "$TEST_CHECK_LOG"; printf 'A proven file was downloaded again\n' >&2; exit 1; fi
grep -q 'compared by size and hash' "$WORK/out"
printf 'later backup\n' >"$WORK/source/b.age"
run
cmp "$WORK/source/b.age" "$WORK/target/b.age"
[[ $(new_files) == b.age ]]
# A proven file that vanished from the destination is copied and downloaded for the byte check again.
rm "$WORK/target/a.age"
run
cmp "$WORK/source/a.age" "$WORK/target/a.age"
[[ $(new_files) == a.age ]]
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
export TEST_FAIL=late-marker
cp "$WORK/state/last-copy" "$WORK/proof"
fails 'new snapshot between payload verification and marker copy'
[[ ! -e $WORK/target/late-snapshot/complete.age ]]
cmp "$WORK/proof" "$WORK/state/last-copy"
unset TEST_FAIL
run
cmp "$WORK/source/late-snapshot/payload.age" "$WORK/target/late-snapshot/payload.age"
cmp "$WORK/source/late-snapshot/complete.age" "$WORK/target/late-snapshot/complete.age"
export TEST_FAIL=marker-pass
cp "$WORK/state/last-copy" "$WORK/proof"
fails 'new snapshot after staged inventory, during the marker copy'
[[ ! -e $WORK/target/during-marker/complete.age ]]
cmp "$WORK/proof" "$WORK/state/last-copy"
unset TEST_FAIL
run
cmp "$WORK/source/during-marker/payload.age" "$WORK/target/during-marker/payload.age"
cmp "$WORK/source/during-marker/complete.age" "$WORK/target/during-marker/complete.age"
export TEST_FAIL=mutate
fails 'source changed during copy'
unset TEST_FAIL
run
printf 'physical repository\n' >"$WORK/source/backup.info"
fails 'pgBackRest repository'
rm "$WORK/source/backup.info"
# Without its list of proven files, every file is downloaded and checked again.
rm "$WORK/state/verified.json"
run
[[ $(new_files | wc -l) == "$(jq length "$(newest_run)/before.json")" ]]
# A provider pair that cannot compare hashes must not pass on a listing alone.
export TEST_FAIL=nohash
fails 'providers that cannot compare hashes'
grep -q 'VERIFY_ALL=1' "$WORK/out"
cp "$WORK/sync.conf" "$WORK/plain.conf"
printf 'VERIFY_ALL=1\n' >>"$WORK/sync.conf"
: >"$TEST_CHECK_LOG"
run
[[ $(new_files | wc -l) == "$(jq length "$(newest_run)/before.json")" ]]
if grep -q -v -- '--download' "$TEST_CHECK_LOG"; then cat "$TEST_CHECK_LOG"; printf 'VERIFY_ALL=1 must download every check\n' >&2; exit 1; fi
unset TEST_FAIL
cp "$WORK/plain.conf" "$WORK/sync.conf"
# Old run folders are removed; the newest 7 stay.
(( $(find "$WORK/state" -mindepth 1 -maxdepth 1 -type d -name 'run-*' | wc -l) <= 7 ))
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
# Equivalent endpoint spellings must identify the same store without making network calls.
config_id() {
  bash -c 'source "$1"; infra_runtime; infra_remote_config SOURCE source s3 test "$2"; printf "%s\n" "$INFRA_REMOTE_IDENTITY"' config-id "$ROOT/jobs/lib.sh" "$1"
}
cat >"$WORK/remote.conf" <<EOF
S3_PROVIDER=Cloudflare
S3_ACCESS_KEY_ID=fixture-key
S3_SECRET_ACCESS_KEY=fixture-secret
S3_BUCKET=fixture-bucket
S3_ENDPOINT=https://objects.example.com
EOF
chmod 600 "$WORK/remote.conf"
plain_id=$(config_id "$WORK/remote.conf")
printf 'S3_ENDPOINT=https://OBJECTS.example.com:443/\nS3_REGION=auto\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") == "$plain_id" ]]
printf 'S3_ENDPOINT=https://objects.example.com:00443\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") == "$plain_id" ]]
printf 'S3_ENDPOINT=https://objects.example.com:8443\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") != "$plain_id" ]]
printf 'S3_ENDPOINT=https://objects.example.com\nS3_PROVIDER=Other\nS3_REGION=custom\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") == "$plain_id" ]]
# AWS's inferred endpoint and an explicit regional endpoint are also one location.
cat >"$WORK/remote.conf" <<EOF
S3_PROVIDER=AWS
S3_ACCESS_KEY_ID=fixture-key
S3_SECRET_ACCESS_KEY=fixture-secret
S3_BUCKET=fixture-bucket
S3_REGION=sa-east-1
EOF
aws_id=$(config_id "$WORK/remote.conf")
printf 'S3_ENDPOINT=https://s3.sa-east-1.amazonaws.com:443/\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") == "$aws_id" ]]
printf 'S3_PROVIDER=Other\n' >>"$WORK/remote.conf"
[[ $(config_id "$WORK/remote.conf") == "$aws_id" ]]
cp "$WORK/remote.conf" "$WORK/equivalent.conf"
printf "S3_PROVIDER=AWS\nS3_ENDPOINT=''\n" >>"$WORK/equivalent.conf"
cat >"$WORK/sync.conf" <<EOF
SOURCE_ENV=$WORK/remote.conf
TARGET_ENV=$WORK/equivalent.conf
SOURCE_PREFIX=history
TARGET_PREFIX=history/nested
STATE_DIR=$WORK/overlap-state
EOF
# Even if a later remote listing would fail, overlap must be refused first without a request.
export TEST_FAIL=list
fails 'same bucket reached through equivalent AWS endpoints'
grep -q 'Source and target overlap' "$WORK/out"
unset TEST_FAIL
# Private configuration must be enforced before a transfer starts.
cp "$WORK/clean.conf" "$WORK/sync.conf"
chmod 644 "$WORK/sync.conf"
fails 'public config'
printf 'Backup copy checks passed: first copy, repeat without downloads, new files, corrupt bytes, failed commands, source changes, pgBackRest refusal, empty source and private configuration.\n'
