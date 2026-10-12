#!/usr/bin/env bash
# A local-only restore check. No Docker daemon, network database or cloud account is used.
set +x +v
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../jobs/lib.sh
source "$ROOT/jobs/lib.sh"
infra_runtime
infra_require initdb pg_ctl createdb psql pg_dump pg_restore age age-keygen rclone redis-server redis-cli sha256sum
[[ $EUID != 0 ]] || { infra_error 'Run this local check as a non-root user. initdb refuses root.'; exit 1; }
# Refuse inherited connection settings. Every connection below uses our own Unix socket.
for variable in ${!PG@} ${!RCLONE_@}; do unset "$variable"; done
WORK=$(mktemp -d "$HOME/.infrakit-integration.XXXXXX")
PG_STARTED=0
REDIS_PID='' RESTORED_REDIS_PID=''
cleanup() {
    local result=$?
    trap - EXIT
    for pid in "$REDIS_PID" "$RESTORED_REDIS_PID"; do
        if [[ -n $pid ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    done
    if (( PG_STARTED )) && [[ -f $WORK/cluster/postmaster.pid ]]; then
        if ! pg_ctl -D "$WORK/cluster" -m immediate -w stop >"$WORK/stop.log" 2>&1; then
            infra_error "The test cluster did not stop. Stop only the cluster in $WORK/cluster; private logs are kept in $WORK."
            exit 1
        fi
    fi
    if (( result == 0 )); then
        rm -rf -- "$WORK"
    else
        infra_error "The local check failed. Read the private logs in $WORK and retry. No production service was used."
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$WORK/socket" "$WORK/restore" "$WORK/source with spaces"
printf 'setting=fixture\n' >"$WORK/source with spaces/settings.conf"
initdb -D "$WORK/cluster" -A trust --no-instructions --locale=en_US.UTF-8 >"$WORK/initdb.log" 2>&1
PG_STARTED=1
pg_ctl -D "$WORK/cluster" -l "$WORK/postgres.log" -w start \
    -o "-c listen_addresses='' -c unix_socket_directories='$WORK/socket' -c lc_messages=C" >"$WORK/start.log" 2>&1
PGUSER=$(id -un)
export PGHOST="$WORK/socket" PGPORT=5432 PGUSER PGDATABASE=postgres PGCONNECT_TIMEOUT=5
suffix="$(date +%s)_$$"
SOURCE_DB="infra_source_$suffix" RESTORE_DB="infra_restore_$suffix"
createdb "$SOURCE_DB" >"$WORK/create-source.log" 2>&1
createdb "$RESTORE_DB" >"$WORK/create-restore.log" 2>&1
psql -X -v ON_ERROR_STOP=1 -d "$SOURCE_DB" -c "CREATE TABLE public.sample (id integer PRIMARY KEY, value text NOT NULL); INSERT INTO public.sample VALUES (1, 'restored fixture'); CREATE SCHEMA extra; CREATE TABLE extra.sample (value text); INSERT INTO extra.sample VALUES ('non-public schema fixture');" >"$WORK/seed.log" 2>&1
age-keygen -o "$WORK/identity" >"$WORK/keygen.log" 2>&1
RECIPIENT=$(age-keygen -y "$WORK/identity")
{
    printf '[backup]\nhost=%s\nport=5432\nuser=%s\ndbname=%s\nsslmode=disable\n' "$WORK/socket" "$PGUSER" "$SOURCE_DB"
} >"$WORK/pg_service.conf"
printf '# This isolated trust-auth cluster needs no password.\n' >"$WORK/pgpass"
field() { printf '%s=%q\n' "$1" "$2"; }
{
    printf 'JOB_ID=host-check\nPROFILE=hosted-postgres\nBACKEND=local\nREMOTE_PREFIX=test/host\nPG_SERVICE=backup\n'
    field ARCHIVE_DIR "$WORK/archive"
    field STATE_DIR "$WORK/state"
    field LOCAL_REMOTE_DIR "$WORK/offsite"
    field BACKUP_AGE_RECIPIENT "$RECIPIENT"
    field PG_SERVICE_FILE "$WORK/pg_service.conf"
    field PG_PASS_FILE "$WORK/pgpass"
    field HOSTED_EXPORT_SCOPE 'All schemas in this isolated database; no globals or service keys.'
    printf 'CONFIG_PATHS=(%q)\n' "$WORK/source with spaces/settings.conf"
} >"$WORK/job.conf"
chmod 600 "$WORK/pg_service.conf" "$WORK/pgpass" "$WORK/job.conf"
# A misleading cron connection must not override the private service.
PGHOST=/nonexistent-test-socket PGPASSWORD=Test-only-secret-unrelated-cron bash "$ROOT/jobs/backup.sh" "$WORK/job.conf" >"$WORK/backup.log" 2>&1
mapfile -t proof <"$WORK/state/last-success"
[[ ${#proof[@]} == 5 && ${proof[0]} == infrakit-snapshot-v1 && ${proof[1]} == host-check ]]
SNAPSHOT=${proof[2]}
export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_BACKUP_TYPE=local
rclone copy "backup:$WORK/offsite/test/host/$SNAPSHOT" "$WORK/restore" >"$WORK/download.log" 2>&1
for artifact in manifest.txt database.dump configs.tar.gz; do
    age -d -i "$WORK/identity" -o "$WORK/restore/$artifact" "$WORK/restore/$artifact.age" >"$WORK/decrypt-$artifact.log" 2>&1
    if [[ $artifact != manifest.txt ]]; then
        expected=$(awk -v name="$artifact" '$2 == name {print $1}' "$WORK/restore/manifest.txt")
        actual=$(sha256sum "$WORK/restore/$artifact")
        [[ ${actual%% *} == "$expected" ]]
    fi
 done
pg_restore --exit-on-error --no-owner --no-privileges --dbname="$RESTORE_DB" "$WORK/restore/database.dump" >"$WORK/restore.log" 2>&1
[[ $(psql -X -At -v ON_ERROR_STOP=1 -d "$RESTORE_DB" -c 'SELECT value FROM public.sample WHERE id = 1') == 'restored fixture' ]]
[[ $(psql -X -At -v ON_ERROR_STOP=1 -d "$RESTORE_DB" -c 'SELECT value FROM extra.sample') == 'non-public schema fixture' ]]
tar -xzf "$WORK/restore/configs.tar.gz" -C "$WORK/restore"
cmp "$WORK/source with spaces/settings.conf" "$WORK/restore/${WORK#/}/source with spaces/settings.conf"
# Real pg_dump failure: keep the old proof and both local/offsite objects.
cp "$WORK/state/last-success" "$WORK/proof-before-failure"
sed "s/dbname=$SOURCE_DB/dbname=infra_missing_$suffix/" "$WORK/pg_service.conf" >"$WORK/service-broken.conf"
chmod 600 "$WORK/service-broken.conf"
cp "$WORK/job.conf" "$WORK/broken-job.conf"
field PG_SERVICE_FILE "$WORK/service-broken.conf" >>"$WORK/broken-job.conf"
if bash "$ROOT/jobs/backup.sh" "$WORK/broken-job.conf" >"$WORK/expected-failure.log" 2>&1; then
    infra_error 'The planted pg_dump failure passed. Fix the backup failure check.'; exit 1
fi
cmp "$WORK/proof-before-failure" "$WORK/state/last-success"
[[ -s $WORK/offsite/test/host/$SNAPSHOT/database.dump.age && -s $WORK/archive/$SNAPSHOT/plain/database.dump ]]
# Real authenticated BGSAVE and RDB restore, in two local socket-only Redis processes.
mkdir -m 700 "$WORK/redis" "$WORK/redis-restore"
redis_config() {
    printf 'port 0\nunixsocket %s\nunixsocketperm 700\ndir %s\ndbfilename dump.rdb\nsave ""\nappendonly no\nrequirepass Test-only-secret-do-not-log\n' "$1" "$2"
}
redis_config "$WORK/redis.sock" "$WORK/redis" >"$WORK/redis.conf"
printf '%s\n' Test-only-secret-do-not-log >"$WORK/redis-password"
redis-server "$WORK/redis.conf" >"$WORK/redis.log" 2>&1 &
REDIS_PID=$!
export REDISCLI_AUTH=Test-only-secret-do-not-log
for ((attempt=0; attempt<100; attempt++)); do
    if [[ -S $WORK/redis.sock ]] && redis-cli -s "$WORK/redis.sock" PING >"$WORK/redis-ready" 2>&1; then break; fi
    sleep 0.1
 done
[[ $(<"$WORK/redis-ready") == PONG ]]
redis-cli -s "$WORK/redis.sock" SET sample 'redis restored fixture' >"$WORK/redis-seed.log" 2>&1
{
    printf 'JOB_ID=redis-check\nPROFILE=files\nBACKEND=local\nREMOTE_PREFIX=test/redis\n'
    field ARCHIVE_DIR "$WORK/redis-archive"
    field STATE_DIR "$WORK/redis-state"
    field LOCAL_REMOTE_DIR "$WORK/offsite"
    field BACKUP_AGE_RECIPIENT "$RECIPIENT"
    field REDIS_PASSWORD_FILE "$WORK/redis-password"
    field REDIS_SOCKET "$WORK/redis.sock"
    field REDIS_RDB "$WORK/redis/dump.rdb"
} >"$WORK/redis-job.conf"
bash "$ROOT/jobs/backup.sh" "$WORK/redis-job.conf" >"$WORK/redis-backup.log" 2>&1
mapfile -t redis_proof <"$WORK/redis-state/last-success"
age -d -i "$WORK/identity" -o "$WORK/redis-restore/dump.rdb" "$WORK/offsite/test/redis/${redis_proof[2]}/redis.rdb.age" >"$WORK/redis-decrypt.log" 2>&1
redis_config "$WORK/restored.sock" "$WORK/redis-restore" >"$WORK/redis-restore.conf"
redis-server "$WORK/redis-restore.conf" >"$WORK/redis-restore.log" 2>&1 &
RESTORED_REDIS_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
    if [[ -S $WORK/restored.sock ]] && redis-cli -s "$WORK/restored.sock" PING >"$WORK/restored-ready" 2>&1; then break; fi
    sleep 0.1
 done
[[ $(redis-cli --raw -s "$WORK/restored.sock" GET sample) == 'redis restored fixture' ]]
# A valid but unrelated old RDB must not be mistaken for this server's completed save.
cp "$WORK/redis-state/last-success" "$WORK/redis-proof-before-failure"
cp "$WORK/redis/dump.rdb" "$WORK/stale.rdb"
cp "$WORK/redis-job.conf" "$WORK/stale-redis-job.conf"
field REDIS_RDB "$WORK/stale.rdb" >>"$WORK/stale-redis-job.conf"
if bash "$ROOT/jobs/backup.sh" "$WORK/stale-redis-job.conf" >"$WORK/redis-expected-failure.log" 2>&1; then
    infra_error 'The planted stale Redis path passed. Fix the snapshot path check.'; exit 1
fi
cmp "$WORK/redis-proof-before-failure" "$WORK/redis-state/last-success"
grep -Fq 'does not match the running Redis snapshot path' "$WORK/redis-expected-failure.log"
[[ -s $WORK/offsite/test/redis/${redis_proof[2]}/redis.rdb.age ]]
if grep -Fq Test-only-secret "$WORK/backup.log" "$WORK/expected-failure.log" "$WORK/redis-backup.log" "$WORK/redis-expected-failure.log"; then
    infra_error 'A test credential leaked into a job log. Fix redaction before releasing.'; exit 1
fi
infra_log 'Local integration passed: public and non-public PostgreSQL data restored, root-relative files matched, Redis RDB restored, and failed dump and stale Redis path kept their previous proofs.'
