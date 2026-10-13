#!/usr/bin/env bash
# Self-signed local fixtures exercise validation. Live sources are Caddy's public certificates.
# Docker, PostgreSQL TLS, chown and curl are fakes; no service or email is used.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d "$ROOT/tests/.cert-sync-test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
export TEST_WORK=$WORK REAL_OPENSSL REAL_FLOCK REAL_STAT REAL_MKDIR REAL_MKTEMP REAL_MV REAL_FIND REAL_CHMOD TEST_PLATFORM
REAL_OPENSSL=$(command -v openssl)
REAL_FLOCK=$(command -v flock)
REAL_STAT=$(command -v stat)
REAL_MKDIR=$(command -v mkdir)
REAL_MKTEMP=$(command -v mktemp)
REAL_MV=$(command -v mv)
REAL_FIND=$(command -v find)
REAL_CHMOD=$(command -v chmod)
TEST_PLATFORM=$(uname -s)
mkdir "$WORK/bin" "$WORK/fixtures"
fail() { printf 'cert-sync check failed: %s\n' "$*" >&2; exit 1; }
contains() {
    if ! grep -F -- "$2" "$1" >/dev/null; then
        [[ ! -f $WORK/stderr ]] || cat "$WORK/stderr" >&2
        fail "Expected $2 in ${1##*/}"
    fi
}
run_job() {
    local result=0
    bash "$ROOT/jobs/cert-sync.sh" "$WORK/cert.conf" >"$WORK/stdout" 2>"$WORK/stderr" || result=$?
    if [[ $1 == pass ]]; then
        (( result == 0 )) || { cat "$WORK/stderr" >&2; fail 'Certificate job should pass'; }
    else
        (( result != 0 )) || fail 'Certificate job should fail'
    fi
    if grep -F 'BEGIN PRIVATE KEY' "$WORK/stdout" "$WORK/stderr" >/dev/null; then fail 'A key reached the log'; fi
    JOB_STATUS=$result
}
make_cert() {
    "$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$2" -addext "subjectAltName=DNS:$2" \
        -keyout "$WORK/fixtures/$1.key" -out "$WORK/fixtures/$1.crt" >"$WORK/fixtures/$1.details" 2>&1 || {
        cat "$WORK/fixtures/$1.details" >&2; fail 'Could not create a local certificate fixture';
    }
}
make_cert old db.example.com
make_cert new db.example.com
make_cert wrong-host other.example.com
# OpenSSL ca supports fixed validity dates on both OpenSSL 1.1.1 and 3.x.
: >"$WORK/fixtures/index"
printf '1000\n' >"$WORK/fixtures/serial"
cat >"$WORK/fixtures/ca.conf" <<EOF
[ca]
default_ca=fixture
[fixture]
unique_subject=no
new_certs_dir=$WORK/fixtures
database=$WORK/fixtures/index
serial=$WORK/fixtures/serial
private_key=$WORK/fixtures/new.key
certificate=$WORK/fixtures/new.crt
default_md=sha256
default_days=30
policy=fixture_policy
copy_extensions=copy
[fixture_policy]
commonName=supplied
EOF
"$REAL_OPENSSL" req -new -key "$WORK/fixtures/new.key" -subj /CN=db.example.com -addext subjectAltName=DNS:db.example.com \
    -out "$WORK/fixtures/request.csr" >"$WORK/fixtures/request.details" 2>&1
for dated in expired future; do
    if [[ $dated == expired ]]; then start=20000101000000Z; end=20000102000000Z
    else start=20990101000000Z; end=21000101000000Z; fi
    "$REAL_OPENSSL" ca -batch -selfsign -notext -config "$WORK/fixtures/ca.conf" -in "$WORK/fixtures/request.csr" \
        -startdate "$start" -enddate "$end" -out "$WORK/fixtures/$dated.crt" >"$WORK/fixtures/$dated.details" 2>&1 || {
        cat "$WORK/fixtures/$dated.details" >&2; fail 'Could not create a dated certificate fixture';
    }
done
"$REAL_OPENSSL" pkey -in "$WORK/fixtures/new.key" -aes256 -passout pass:fixture -out "$WORK/fixtures/encrypted.key" >"$WORK/fixtures/encrypted.details" 2>&1
cat >"$WORK/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$TEST_WORK/commands"
printf '\n' >>"$TEST_WORK/commands"
case $1 in
    inspect) cat "$TEST_WORK/mounts.json" ;;
    cp) cp -- "${2#*:}" "$3" ;;
    exec)
        container=$2; shift 2
        if [[ $container == caddy-fixture ]]; then
            case $1 in find|readlink|test) "$@" ;; *) exit 91 ;; esac
            exit
        fi
        [[ $container == postgres-fixture ]] || exit 92
        case $1 in
            id) if [[ $2 == -u ]]; then printf '%s\n' "$TEST_PG_UID"; else printf '%s\n' "$TEST_PG_GID"; fi ;;
            psql)
                case ${!#} in
                    'SHOW ssl_cert_file;') printf '/tls/server.crt\n' ;;
                    'SHOW ssl_key_file;') printf '/tls/server.key\n' ;;
                    'SELECT pg_reload_conf();')
                        count=0
                        [[ ! -f $TEST_WORK/reloads ]] || read -r count <"$TEST_WORK/reloads"
                        count=$((count + 1))
                        printf '%s\n' "$count" >"$TEST_WORK/reloads"
                        if [[ -f $TEST_WORK/reload-fail || ( -f $TEST_WORK/reload-fail-once && $count == 1 ) ]]; then printf 'f\n'; exit; fi
                        # A real single-file bind keeps the original inode.
                        [[ $(stat -c '%d:%i' -- "$TEST_TARGET_CERT") == "$TEST_CERT_INODE" ]] || exit 93
                        [[ $(stat -c '%d:%i' -- "$TEST_TARGET_KEY") == "$TEST_KEY_INODE" ]] || exit 94
                        if [[ -f $TEST_WORK/serve-shadow ]]; then
                            cp -- "$TEST_WORK/case/shadow/server.crt" "$TEST_WORK/served.crt"
                        elif [[ ! -f $TEST_WORK/serve-old-on-new ]] || ! cmp -s "$TEST_TARGET_CERT" "$TEST_WORK/fixtures/new.crt"; then
                            cp -- "$TEST_TARGET_CERT" "$TEST_WORK/served.crt"
                        fi
                        printf 't\n'
                        ;;
                    *) exit 95 ;;
                esac
                ;;
            *) exit 96 ;;
        esac
        ;;
    *) exit 97 ;;
esac
SH
cat >"$WORK/bin/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == s_client ]]; then
    [[ ! -f $TEST_WORK/tls-fail ]] || exit 1
    cat "$TEST_WORK/served.crt"
    exit
fi
# Older x509 versions can print a hostname mismatch while exiting zero.
if [[ -f $TEST_WORK/legacy-host-status && $1 == x509 ]]; then
    for arg in "$@"; do
        if [[ $arg == -checkhost ]]; then "$REAL_OPENSSL" "$@" || true; exit 0; fi
    done
fi
exec "$REAL_OPENSSL" "$@"
SH
cat >"$WORK/bin/chown" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >>"$TEST_WORK/chown-log"
# Kill only the local job, after its first in-place write, to exercise crash recovery.
if [[ -f $TEST_WORK/interrupt-write ]]; then kill -KILL "$PPID"; exit; fi
[[ ! -f $TEST_WORK/chown-fail || $1 != "$TEST_PG_UID:$TEST_PG_GID" ]] || exit 1
# Ownership is recorded, not changed: these checks run without root.
if [[ -f $TEST_WORK/track-target-owners && ( $2 == "$TEST_TARGET_CERT" || $2 == "$TEST_TARGET_KEY" ) ]]; then
    label=cert; [[ $2 != "$TEST_TARGET_KEY" ]] || label=key
    printf '%s %s\n' "${1%:*}" "${1#*:}" >"$TEST_WORK/case/.synthetic-owner.$label"
    if [[ -f $TEST_WORK/interrupt-metadata && $(<"$TEST_WORK/interrupt-metadata") == "chown $label $1" ]]; then
        printf 'chown %s %s\n' "$label" "$1" >"$TEST_WORK/metadata-interrupted"
        kill -KILL "$PPID"
    fi
fi
SH
cat >"$WORK/bin/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f $TEST_WORK/check-read-only-lock && ${!#} == 8 ]]; then
    if { printf 'forbidden lock write\n' >&8; } 2>/dev/null; then
        printf 'The shared lock descriptor is writable\n' >&2
        exit 98
    fi
    printf 'read-only\n' >>"$TEST_WORK/lock-open-log"
fi
if [[ -f $TEST_WORK/replace-during-lock && ${!#} == 8 ]]; then
    "$REAL_MV" -- "$TEST_WORK/box.lock" "$TEST_WORK/box.lock.old"
    printf 'replacement fixture lock\n' >"$TEST_WORK/box.lock"
    "$REAL_CHMOD" 600 "$TEST_WORK/box.lock"
    "$REAL_FLOCK" "$@"
    "$REAL_FLOCK" -n "$TEST_WORK/box.lock" true
    printf 'split inodes\n' >"$TEST_WORK/lock-bypass"
    exit
fi
exec "$REAL_FLOCK" "$@"
SH
cat >"$WORK/bin/stat" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} != --version ]] || exec "$REAL_STAT" "$@"
format=${2:-} path=${!#}
case $format in
    '%F %u %g %a'|'%u %g %a'|'%u %g %a %h %d:%i'|'%u %g %a %d:%i') ;;
    *) exec "$REAL_STAT" "$@" ;;
esac
# Darwin's /dev/fd stat does not expose Linux descriptor metadata. fstat does,
# so this adapter measures the actual inherited inode, never the current pathname.
if [[ $path == /dev/fd/8 && $TEST_PLATFORM == Darwin ]]; then
    metadata=$(python3 -I - <<'PY'
import os, stat
s = os.fstat(8)
print(s.st_uid, s.st_gid, format(stat.S_IMODE(s.st_mode), 'o'), s.st_nlink, f'{s.st_dev}:{s.st_ino}')
PY
)
else
    if [[ -f $TEST_WORK/sticky-fixture && ( $path == /run || $path == /run/lock ) ]]; then
        mode=755; owner=0; group=0
        if [[ $path == /run/lock ]]; then
            read -r mode <"$TEST_WORK/sticky-mode"
            [[ ! -f $TEST_WORK/sticky-ids ]] || read -r owner group <"$TEST_WORK/sticky-ids"
        fi
        printf 'directory %s %s %s\n' "$owner" "$group" "$mode"
        exit
    fi
    metadata=$("$REAL_STAT" -c '%u %g %a %h %d:%i' -- "$path")
fi
read -r owner group mode links inode <<<"$metadata"
if [[ -f $TEST_WORK/track-target-owners && ( $path == "$TEST_TARGET_CERT" || $path == "$TEST_TARGET_KEY" ) ]]; then
    owner=1000; group=1000
    [[ $path != "$TEST_TARGET_KEY" ]] || { owner=0; group=$TEST_PG_GID; }
    label=cert; [[ $path != "$TEST_TARGET_KEY" ]] || label=key
    [[ ! -f $TEST_WORK/case/.synthetic-owner.$label ]] || read -r owner group <"$TEST_WORK/case/.synthetic-owner.$label"
fi
if [[ -f $TEST_WORK/deploy-lock-owner && ( $path == "$TEST_WORK/box.lock" || $path == /dev/fd/8 ) ]]; then owner=1000; group=1000; fi
if [[ -f $TEST_WORK/deployment-layout && $path == "$TEST_WORK/case/deployment"* && $format == '%F %u %g %a' ]]; then
    owner=1000; group=1000
    [[ $path != "${TEST_TARGET_CERT%/*}" ]] || { owner=0; group=0; }
    if [[ $path == "$TEST_WORK/case/deployment/app" ]]; then
        [[ ! -f $TEST_WORK/unsafe-owner ]] || owner=1001
        [[ ! -f $TEST_WORK/unsafe-group ]] || group=1001
    fi
fi
if [[ -f $TEST_WORK/service-directory && $path == "${TEST_TARGET_CERT%/*}" && $format == '%F %u %g %a' ]]; then owner=$TEST_PG_UID; group=$TEST_PG_GID; fi
if [[ -f $TEST_WORK/service-target && ( $path == "$TEST_TARGET_CERT" || $path == "$TEST_TARGET_KEY" ) && $format == '%u %g %a' ]]; then owner=$TEST_PG_UID; group=$TEST_PG_GID; fi
if [[ -f $TEST_WORK/unsafe-target-owner && $path == "$TEST_TARGET_KEY" && $format == '%u %g %a' ]]; then owner=1001; group=1001; fi
if [[ -f $TEST_WORK/short-mode && $path == "$TEST_TARGET_KEY" && $format == '%u %g %a %d:%i' ]]; then owner=0; group=$TEST_PG_GID; mode=40; fi
case $format in
    '%F %u %g %a') printf '%s %s %s %s\n' "$("$REAL_STAT" -c %F -- "$path")" "$owner" "$group" "$mode" ;;
    '%u %g %a') printf '%s %s %s\n' "$owner" "$group" "$mode" ;;
    '%u %g %a %h %d:%i') printf '%s %s %s %s %s\n' "$owner" "$group" "$mode" "$links" "$inode" ;;
    '%u %g %a %d:%i') printf '%s %s %s %s\n' "$owner" "$group" "$mode" "$inode" ;;
    *) exec "$REAL_STAT" "$@" ;;
esac
# Replace only this fixture after its inspected metadata is returned, before open.
if [[ -f $TEST_WORK/replace-before-open && $path == "$TEST_WORK/box.lock" && $format == '%u %g %a %h %d:%i' ]]; then
    rm -- "$TEST_WORK/replace-before-open"
    "$REAL_MV" -- "$path" "$path.old"
    printf 'replacement fixture lock\n' >"$path"
    "$REAL_CHMOD" 600 "$path"
fi
SH
cat >"$WORK/bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_MKDIR" "$@"
if [[ -f $TEST_WORK/interrupt-staging && ${!#} == "$TEST_WORK/case/state/staging" ]]; then kill -KILL "$PPID"; fi
SH
cat >"$WORK/bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f $TEST_WORK/fail-binding && ${1:-} == *'/staging/.infra-state.'* ]]; then
    rm -- "$TEST_WORK/fail-binding"
    exit 1
fi
exec "$REAL_MKTEMP" "$@"
SH
cat >"$WORK/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -T && ${!#} == "$TEST_WORK/case/state/pending" ]]; then
    if [[ -f $TEST_WORK/interrupt-ready-staging ]]; then kill -KILL "$PPID"; exit; fi
    "$REAL_MV" "$@"
    if [[ -f $TEST_WORK/interrupt-publish ]]; then kill -KILL "$PPID"; fi
else exec "$REAL_MV" "$@"; fi
SH
cat >"$WORK/bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f $TEST_WORK/find-fail && $1 == "$TEST_WORK/case/state" ]]; then exit 1; fi
exec "$REAL_FIND" "$@"
SH
cat >"$WORK/bin/chmod" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "${!#}" >>"$TEST_WORK/chmod-log"
# Emulate root restoring a group-readable 0040 key without denying fixture reads.
if [[ -f $TEST_WORK/short-mode && $1 == 40 && ${!#} == "$TEST_TARGET_KEY" ]]; then exit; fi
"$REAL_CHMOD" "$@"
if [[ -f $TEST_WORK/interrupt-metadata && ( ${!#} == "$TEST_TARGET_CERT" || ${!#} == "$TEST_TARGET_KEY" ) ]]; then
    label=cert; [[ ${!#} != "$TEST_TARGET_KEY" ]] || label=key
    if [[ $(<"$TEST_WORK/interrupt-metadata") == "chmod $label $1" ]]; then
        printf 'chmod %s %s\n' "$label" "$1" >"$TEST_WORK/metadata-interrupted"
        kill -KILL "$PPID"
    fi
fi
SH
cat >"$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && $1 == -q && $2 == --config ]] || exit 90
[[ $(stat -c %a -- "$3") == 600 ]] || exit 91
printf 'mail\n' >>"$TEST_WORK/mail-log"
[[ ! -f $TEST_WORK/mail-fail ]] || exit 1
SH
chmod 700 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export TEST_TARGET_CERT TEST_TARGET_KEY TEST_CERT_INODE TEST_KEY_INODE TEST_PG_UID TEST_PG_GID
TEST_PG_UID=$(($(id -u) + 100)) TEST_PG_GID=$(($(id -g) + 100))
setup() {
    rm -rf -- "$WORK/case"
    rm -f -- "$WORK/reloads" "$WORK/reload-fail" "$WORK/reload-fail-once" "$WORK/serve-old-on-new" \
        "$WORK/tls-fail" "$WORK/chown-fail" "$WORK/interrupt-write" "$WORK/mail-fail" "$WORK/mail-log" "$WORK/legacy-host-status" \
        "$WORK/check-read-only-lock" "$WORK/deploy-lock-owner" "$WORK/lock-open-log" \
        "$WORK/short-mode" "$WORK/interrupt-staging" "$WORK/interrupt-ready-staging" "$WORK/interrupt-publish" "$WORK/fail-binding" \
        "$WORK/find-fail" "$WORK/replace-before-open" "$WORK/replace-during-lock" "$WORK/lock-bypass" \
        "$WORK/deployment-layout" "$WORK/unsafe-owner" "$WORK/unsafe-group" "$WORK/unsafe-target-owner" \
        "$WORK/service-directory" "$WORK/service-target" "$WORK/sticky-fixture" "$WORK/serve-shadow" \
        "$WORK/track-target-owners" "$WORK/interrupt-metadata" "$WORK/metadata-interrupted"
    : >"$WORK/chmod-log"
    mkdir "$WORK/case" "$WORK/case/target"
    TEST_TARGET_CERT="$WORK/case/target/server.crt" TEST_TARGET_KEY="$WORK/case/target/server.key"
    cp -- "$WORK/fixtures/old.crt" "$TEST_TARGET_CERT"
    cp -- "$WORK/fixtures/old.key" "$TEST_TARGET_KEY"
    chmod 600 "$TEST_TARGET_CERT"
    chmod 640 "$TEST_TARGET_KEY"
    OLD_CERT_META=$(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_CERT")
    OLD_KEY_META=$(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_KEY")
    TEST_CERT_INODE=$(stat -c '%d:%i' -- "$TEST_TARGET_CERT")
    TEST_KEY_INODE=$(stat -c '%d:%i' -- "$TEST_TARGET_KEY")
    cp -- "$WORK/fixtures/old.crt" "$WORK/served.crt"
    : >"$WORK/commands"
    : >"$WORK/chown-log"
    : >"$WORK/box.lock"
    chmod 600 "$WORK/box.lock"
    jq -n --arg cert "$TEST_TARGET_CERT" --arg key "$TEST_TARGET_KEY" \
        '[{Type:"bind", Source:$cert, Destination:"/tls/server.crt"}, {Type:"bind", Source:$key, Destination:"/tls/server.key"}]' >"$WORK/mounts.json"
    {
        printf 'STATE_DIR=%q\nTARGET_CERT=%q\nTARGET_KEY=%q\nBOX_LOCK=%q\n' "$WORK/case/state" "$TEST_TARGET_CERT" "$TEST_TARGET_KEY" "$WORK/box.lock"
        printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/new.crt" "$WORK/fixtures/new.key"
        printf "CERT_HOSTNAME='db.example.com'\nDB_CONTAINER='postgres-fixture'\nCONTAINER_CERT='/tls/server.crt'\nCONTAINER_KEY='/tls/server.key'\n"
        printf 'VERIFY_ATTEMPTS=1\nVERIFY_TIMEOUT_SECONDS=1\nEXPIRY_WARN_DAYS=1\nBOX_LOCK_WAIT_SECONDS=1\n'
    } >"$WORK/cert.conf"
    chmod 600 "$WORK/cert.conf"
}
old_proof() {
    local binding old_fingerprint
    mkdir -p "$WORK/case/state"
    binding=$(printf '%s\n' db.example.com postgres-fixture postgres postgres "$TEST_TARGET_CERT" "$TEST_TARGET_KEY" /tls/server.crt /tls/server.key 127.0.0.1 5432 | sha256sum)
    binding=${binding%% *}
    printf '%s\n' "$binding" >"$WORK/case/state/.cert-owner"
    old_fingerprint=$("$REAL_OPENSSL" x509 -in "$WORK/fixtures/old.crt" -noout -fingerprint -sha256)
    old_fingerprint=${old_fingerprint#*=}; old_fingerprint=${old_fingerprint//:/}
    printf 'infrakit-cert-v1\n%s\n%s\n%s\n' "$binding" "$old_fingerprint" "$(date +%s)" >"$WORK/case/state/last-success"
    cp -- "$WORK/case/state/last-success" "$WORK/old-proof"
}
assert_restored() {
    cmp -s "$TEST_TARGET_CERT" "$WORK/fixtures/old.crt" || fail 'Previous certificate bytes were not restored'
    cmp -s "$TEST_TARGET_KEY" "$WORK/fixtures/old.key" || fail 'Previous key bytes were not restored'
    [[ $(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_CERT") == "$OLD_CERT_META" ]] || fail 'Previous certificate metadata was not restored'
    [[ $(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_KEY") == "$OLD_KEY_META" ]] || fail 'Previous key metadata was not restored'
    cmp -s "$WORK/case/state/last-success" "$WORK/old-proof" || fail 'Previous proof changed after a failure'
}
assert_verified() {
    cmp -s "$TEST_TARGET_CERT" "$WORK/fixtures/new.crt" || fail 'The checked certificate was not installed'
    cmp -s "$TEST_TARGET_KEY" "$WORK/fixtures/new.key" || fail 'The matching key was not installed'
    [[ $(stat -c %a -- "$TEST_TARGET_CERT") == 644 && $(stat -c %a -- "$TEST_TARGET_KEY") == 600 ]] || fail 'Installed file modes are wrong'
    [[ $(stat -c '%d:%i' -- "$TEST_TARGET_CERT") == "$TEST_CERT_INODE" && $(stat -c '%d:%i' -- "$TEST_TARGET_KEY") == "$TEST_KEY_INODE" ]] || fail 'A target inode changed'
    contains "$WORK/chown-log" "$TEST_PG_UID:$TEST_PG_GID $TEST_TARGET_KEY"
    if [[ -f $WORK/track-target-owners ]]; then
        [[ $(stat -c '%u %g %a' -- "$TEST_TARGET_CERT") == "$TEST_PG_UID $TEST_PG_GID 644" && $(stat -c '%u %g %a' -- "$TEST_TARGET_KEY") == "$TEST_PG_UID $TEST_PG_GID 600" ]] || fail 'Installed file ownership is wrong'
    fi
    contains "$WORK/case/state/last-success" 'infrakit-cert-v1'
    fingerprint=$("$REAL_OPENSSL" x509 -in "$WORK/fixtures/new.crt" -noout -fingerprint -sha256)
    fingerprint=${fingerprint#*=}; fingerprint=${fingerprint//:/}
    contains "$WORK/case/state/last-success" "$fingerprint"
    [[ $(stat -c %a -- "$WORK/case/state/last-success") == 600 && ! -e $WORK/case/state/pending ]] || fail 'Proof or pending state is unsafe'
    [[ -f $WORK/reloads && $(<"$WORK/reloads") -gt 0 ]] || fail 'No PostgreSQL reload was requested'
}

deployment_layout() {
    local root="$WORK/case/deployment" leaf="$WORK/case/deployment/app/infra/staging/volumes/ssl"
    mkdir -p "$leaf"
    chmod 755 "$root" "$leaf"
    chmod 775 "$root/app" "$root/app/infra" "$root/app/infra/staging" "$root/app/infra/staging/volumes"
    mv -- "$TEST_TARGET_CERT" "$leaf/server.crt"
    mv -- "$TEST_TARGET_KEY" "$leaf/server.key"
    TEST_TARGET_CERT="$leaf/server.crt" TEST_TARGET_KEY="$leaf/server.key"
    : >"$WORK/deployment-layout"
    : >"$WORK/deploy-lock-owner"
    chmod 664 "$WORK/box.lock"
    {
        printf 'TARGET_CERT=%q\nTARGET_KEY=%q\n' "$TEST_TARGET_CERT" "$TEST_TARGET_KEY"
        printf 'DEPLOY_UID=1000\nDEPLOY_GID=1000\n'
    } >>"$WORK/cert.conf"
    jq -n --arg cert "$TEST_TARGET_CERT" --arg key "$TEST_TARGET_KEY" '[
        {Type:"bind", Source:$cert, Destination:"/tls/server.crt", RW:false},
        {Type:"bind", Source:$key, Destination:"/tls/server.key", RW:false}
    ]' >"$WORK/mounts.json"
}

# Single-file binds keep the same inode and already-open file handles see new bytes.
setup
exec 5<"$TEST_TARGET_CERT"
run_job pass
assert_verified
cmp -s "$WORK/fixtures/new.crt" /dev/fd/5 || fail 'A single-file bind would still see old bytes'
exec 5<&-
run_job pass
assert_verified

# Identical disk bytes without a proof still need a reload and a served read-back.
setup
cp -- "$WORK/fixtures/new.crt" "$TEST_TARGET_CERT"
cp -- "$WORK/fixtures/new.key" "$TEST_TARGET_KEY"
run_job pass
assert_verified

# A reload refusal and a wrong served fingerprint restore old bytes, modes and proof.
setup
old_proof
: >"$WORK/reload-fail-once"
run_job fail
assert_restored
[[ ! -e $WORK/case/state/pending ]] || fail 'Successful rollback kept a pending change'
contains "$WORK/chown-log" "$(id -u):$(id -g) $TEST_TARGET_KEY"
setup
old_proof
: >"$WORK/short-mode"
OLD_KEY_META=$(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_KEY")
: >"$WORK/reload-fail-once"
run_job fail
assert_restored
contains "$WORK/chown-log" "0:$TEST_PG_GID $TEST_TARGET_KEY"
contains "$WORK/chmod-log" "40 $TEST_TARGET_KEY"
[[ ! -e $WORK/case/state/pending ]] || fail 'A valid short key mode blocked rollback'
setup
old_proof
: >"$WORK/serve-old-on-new"
run_job fail
assert_restored
contains "$WORK/stderr" 'different certificate'
setup
: >"$WORK/serve-old-on-new"
run_job fail
cmp -s "$TEST_TARGET_CERT" "$WORK/fixtures/old.crt" || fail 'First-run failure did not restore the certificate'
cmp -s "$TEST_TARGET_KEY" "$WORK/fixtures/old.key" || fail 'First-run failure did not restore the key'
[[ ! -e $WORK/case/state/last-success && ! -e $WORK/case/state/pending ]] || fail 'First-run failure created a proof or lost rollback verification'
setup
old_proof
: >"$WORK/chown-fail"
run_job fail
assert_restored
[[ ! -e $WORK/case/state/pending ]] || fail 'Failed ownership change was not rolled back'

# An unconfirmed rollback keeps private recovery files until the next run can verify it.
setup
old_proof
: >"$WORK/reload-fail"
run_job fail
assert_restored
[[ -f $WORK/case/state/pending/ready ]] || fail 'Failed recovery lost its pending files'
rm -- "$WORK/reload-fail"
run_job pass
assert_verified
setup
old_proof
: >"$WORK/tls-fail"
run_job fail
assert_restored
[[ -f $WORK/case/state/pending/ready ]] || fail 'Failed TLS read-back lost recovery state'
rm -- "$WORK/tls-fail"
run_job pass
assert_verified

# A killed job leaves a recoverable partial pair. The next run restores before installing.
setup
old_proof
: >"$WORK/interrupt-write"
run_job fail
[[ -f $WORK/case/state/pending/ready ]] || fail 'Interrupted writes have no durable recovery state'
rm -- "$WORK/interrupt-write"
printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/wrong-host.crt" "$WORK/fixtures/wrong-host.key" >>"$WORK/cert.conf"
run_job fail
assert_restored
[[ ! -e $WORK/case/state/pending ]] || fail 'Verified recovery retained pending files'
contains "$WORK/stdout" 'Recovering an interrupted certificate change'
contains "$WORK/stdout" 'Previous certificate files and served fingerprint restored'
printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/new.crt" "$WORK/fixtures/new.key" >>"$WORK/cert.conf"
run_job pass
assert_verified

# Deployment-owned group write is valid before installation, not after PostgreSQL
# takes ownership. Track both files' owners without changing any OS ownership.
setup
deployment_layout
: >"$WORK/track-target-owners"
chmod 664 "$TEST_TARGET_CERT"
old_proof
run_job pass
assert_verified

# Kill after every forward and rollback metadata operation. Each intermediate
# owner/mode pair must pass the unchanged target gate on the next bound recovery.
for transition in \
    "install cert chown $TEST_PG_UID:$TEST_PG_GID $TEST_PG_UID $TEST_PG_GID 644 0 $TEST_PG_GID 640" \
    "install cert chmod 644 1000 1000 644 0 $TEST_PG_GID 640" \
    "install key chmod 600 $TEST_PG_UID $TEST_PG_GID 644 0 $TEST_PG_GID 600" \
    "install key chown $TEST_PG_UID:$TEST_PG_GID $TEST_PG_UID $TEST_PG_GID 644 $TEST_PG_UID $TEST_PG_GID 600" \
    "restore cert chown 1000:1000 1000 1000 644 $TEST_PG_UID $TEST_PG_GID 600" \
    "restore cert chmod 664 1000 1000 664 $TEST_PG_UID $TEST_PG_GID 600" \
    "restore key chown 0:$TEST_PG_GID 1000 1000 664 0 $TEST_PG_GID 600" \
    "restore key chmod 640 1000 1000 664 0 $TEST_PG_GID 640"; do
    read -r direction label operation value cert_uid cert_gid cert_mode key_uid key_gid key_mode <<<"$transition"
    setup
    deployment_layout
    : >"$WORK/track-target-owners"
    chmod 664 "$TEST_TARGET_CERT"
    OLD_CERT_META=$(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_CERT")
    OLD_KEY_META=$(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_KEY")
    old_proof
    printf '%s %s %s\n' "$operation" "$label" "$value" >"$WORK/interrupt-metadata"
    prior_reloads=0
    if [[ $direction == restore ]]; then
        : >"$WORK/reload-fail-once"
        prior_reloads=1
    fi
    run_job fail
    (( JOB_STATUS == 137 )) || fail "$direction $label $operation did not SIGKILL the job"
    contains "$WORK/metadata-interrupted" "$operation $label $value"
    [[ -f $WORK/case/state/pending/ready && -f $WORK/case/state/pending/binding ]] || fail 'Metadata interruption lost bound recovery state'
    [[ $(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_CERT") == "$cert_uid $cert_gid $cert_mode $TEST_CERT_INODE" ]] || fail "$direction $label $operation left wrong certificate metadata"
    [[ $(stat -c '%u %g %a %d:%i' -- "$TEST_TARGET_KEY") == "$key_uid $key_gid $key_mode $TEST_KEY_INODE" ]] || fail "$direction $label $operation left wrong key metadata"
    cert_fixture=new; [[ $direction != restore ]] || cert_fixture=old
    key_fixture=old
    if [[ $direction:$label == install:key || $direction:$label == restore:cert ]]; then key_fixture=new; fi
    cmp -s "$TEST_TARGET_CERT" "$WORK/fixtures/$cert_fixture.crt" || fail 'Metadata interruption left unexpected certificate bytes'
    cmp -s "$TEST_TARGET_KEY" "$WORK/fixtures/$key_fixture.key" || fail 'Metadata interruption left unexpected key bytes'
    cmp -s "$WORK/case/state/last-success" "$WORK/old-proof" || fail 'Metadata interruption advanced the proof'
    if (( prior_reloads == 0 )); then [[ ! -f $WORK/reloads ]] || fail 'Interrupted installation reloaded early'
    else [[ $(<"$WORK/reloads") == 1 ]] || fail 'Interrupted rollback reloaded early'; fi
    rm -- "$WORK/interrupt-metadata"
    # Stop after recovery, so a fresh installation cannot hide a wrong old pair.
    printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/wrong-host.crt" "$WORK/fixtures/wrong-host.key" >>"$WORK/cert.conf"
    run_job fail
    assert_restored
    cmp -s "$WORK/served.crt" "$WORK/fixtures/old.crt" || fail 'Recovery did not serve the old certificate'
    [[ ! -e $WORK/case/state/pending && $(<"$WORK/reloads") == $((prior_reloads + 1)) ]] || fail 'Metadata recovery did not finish'
    contains "$WORK/stdout" 'Previous certificate files and served fingerprint restored'
    contains "$WORK/stderr" 'source certificate does not match CERT_HOSTNAME'
    printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/new.crt" "$WORK/fixtures/new.key" >>"$WORK/cert.conf"
    run_job pass
    assert_verified
done

# Preparation never publishes incomplete pending state. Retries keep the old proof
# until a full install is verified, even after SIGKILL before or after publication.
for interruption in interrupt-staging fail-binding interrupt-ready-staging interrupt-publish; do
    setup
    old_proof
    : >"$WORK/$interruption"
    run_job fail
    assert_restored
    [[ ! -f $WORK/reloads ]] || fail "$interruption preparation changed the running certificate"
    if [[ $interruption == interrupt-publish ]]; then
        [[ -f $WORK/case/state/pending/ready && -f $WORK/case/state/pending/binding ]] || fail 'Publication lost complete recovery state'
    else
        [[ -d $WORK/case/state/staging && ! -e $WORK/case/state/pending ]] || fail 'Incomplete preparation was published'
        if [[ $interruption == interrupt-staging || $interruption == fail-binding ]]; then
            [[ ! -e $WORK/case/state/staging/binding ]] || fail 'The pre-binding interruption was not reached'
        fi
    fi
    rm -f -- "$WORK/$interruption"
    printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/wrong-host.crt" "$WORK/fixtures/wrong-host.key" >>"$WORK/cert.conf"
    run_job fail
    assert_restored
    [[ ! -e $WORK/case/state/staging && ! -e $WORK/case/state/pending ]] || fail 'Unpublished staging or verified recovery blocked retry'
    printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/new.crt" "$WORK/fixtures/new.key" >>"$WORK/cert.conf"
    run_job pass
    assert_verified
 done

# Ready recovery never bypasses a missing or mismatched binding.
for binding_problem in missing different; do
    setup
    old_proof
    : >"$WORK/interrupt-write"
    run_job fail
    rm -- "$WORK/interrupt-write"
    case $binding_problem in
        missing) rm -- "$WORK/case/state/pending/binding" ;;
        different) printf '%064d\n' 0 >"$WORK/case/state/pending/binding" ;;
    esac
    cp -- "$TEST_TARGET_CERT" "$WORK/interrupted.cert"
    cp -- "$TEST_TARGET_KEY" "$WORK/interrupted.key"
    run_job fail
    if ! cmp -s "$TEST_TARGET_CERT" "$WORK/interrupted.cert" || ! cmp -s "$TEST_TARGET_KEY" "$WORK/interrupted.key"; then fail 'Unbound ready recovery touched targets'; fi
    cmp -s "$WORK/case/state/last-success" "$WORK/old-proof" || fail 'Unbound ready recovery changed the old proof'
    [[ -f $WORK/case/state/pending/ready && ! -f $WORK/reloads ]] || fail 'Unbound ready recovery ran or lost evidence'
done

# Old unready pending with no binding is harmless inside matching owner-bound state.
setup
old_proof
mkdir "$WORK/case/state/pending"
printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/wrong-host.crt" "$WORK/fixtures/wrong-host.key" >>"$WORK/cert.conf"
run_job fail
assert_restored
[[ ! -e $WORK/case/state/pending && ! -f $WORK/reloads ]] || fail 'Unready pre-binding pending blocked retry'

# A ready staging directory also needs its binding, though it cannot have written targets.
setup
old_proof
mkdir "$WORK/case/state/staging"
printf 'ready\n' >"$WORK/case/state/staging/ready"
run_job fail
assert_restored
[[ -f $WORK/case/state/staging/ready && ! -f $WORK/reloads ]] || fail 'Ready staging with no binding was discarded'

# A failed state read is never an empty directory, even without an owner marker.
for entry in last-success $'\n'; do
    setup
    mkdir "$WORK/case/state"
    printf 'previous state, not owned by this job\n' >"$WORK/case/state/$entry"
    cp -- "$WORK/case/state/$entry" "$WORK/unbound-proof"
    run_job fail
    [[ ! -e $WORK/case/state/.cert-owner ]] || fail 'Successful read adopted nonempty state'
    : >"$WORK/find-fail"
    run_job fail
    contains "$WORK/stderr" 'could not be read'
    cmp -s "$WORK/case/state/$entry" "$WORK/unbound-proof" || fail 'Failed read replaced prior state'
    [[ ! -e $WORK/case/state/.cert-owner && ! -f $WORK/reloads ]] || fail 'Failed read adopted state or reloaded'
done

# Invalid source pairs, hostnames and dates fail before any target write or reload.
for invalid in key-pair hostname legacy-hostname expiry future encrypted-key; do
    setup
    old_proof
    case $invalid in
        key-pair) printf 'SOURCE_KEY=%q\n' "$WORK/fixtures/old.key" >>"$WORK/cert.conf" ;;
        hostname|legacy-hostname)
            printf 'SOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$WORK/fixtures/wrong-host.crt" "$WORK/fixtures/wrong-host.key" >>"$WORK/cert.conf"
            [[ $invalid != legacy-hostname ]] || : >"$WORK/legacy-host-status"
            ;;
        expiry) printf 'SOURCE_CERT=%q\n' "$WORK/fixtures/expired.crt" >>"$WORK/cert.conf" ;;
        future) printf 'SOURCE_CERT=%q\n' "$WORK/fixtures/future.crt" >>"$WORK/cert.conf" ;;
        encrypted-key) printf 'SOURCE_KEY=%q\n' "$WORK/fixtures/encrypted.key" >>"$WORK/cert.conf" ;;
    esac
    run_job fail
    assert_restored
    [[ ! -f $WORK/reloads ]] || fail "$invalid source caused a reload"
done

# Directory binds work too, with exactly the same host/container relative paths.
setup
jq -n --arg dir "$WORK/case/target" '[{Type:"bind", Source:$dir, Destination:"/tls"}]' >"$WORK/mounts.json"
run_job pass
assert_verified
setup
old_proof
printf '[]\n' >"$WORK/mounts.json"
run_job fail
assert_restored
[[ ! -f $WORK/reloads ]] || fail 'Unmapped targets caused a reload'

# Docker supplies an explicit Source for named volumes; no data-root assumption.
setup
jq -n --arg dir "$WORK/case/target" '[{Type:"volume", Name:"tls-fixture", Source:$dir, Destination:"/tls"}]' >"$WORK/mounts.json"
: >"$WORK/service-directory"
: >"$WORK/service-target"
run_job pass
assert_verified

# A service-owned parent above a file bind is not inside the verified mount.
setup
old_proof
: >"$WORK/service-directory"
run_job fail
assert_restored
[[ ! -f $WORK/reloads ]] || fail 'Unverified service-owner ancestry caused a reload'
setup
old_proof
jq -n --arg dir "$WORK/case/target" '[{Type:"volume", Source:$dir, Destination:"/tls"}]' >"$WORK/mounts.json"
: >"$WORK/service-directory"
chmod 770 "$WORK/case/target"
run_job fail
assert_restored
[[ ! -f $WORK/reloads ]] || fail 'Service group write was trusted without deployment pins'

# A matching child bind is the effective map even when its parent maps elsewhere.
setup
jq -n --arg wrong "$WORK/fixtures" --arg cert "$TEST_TARGET_CERT" --arg key "$TEST_TARGET_KEY" '[
    {Type:"bind", Source:$wrong, Destination:"/tls"},
    {Type:"bind", Source:$cert, Destination:"/tls/server.crt"},
    {Type:"bind", Source:$key, Destination:"/tls/server.key"}
]' >"$WORK/mounts.json"
run_job pass
assert_verified

# Every more-specific mount type can mask the parent. Even a matching served
# fingerprint cannot turn writes to hidden host targets into a valid installation.
for shadow_type in bind volume tmpfs other; do
    setup
    old_proof
    mkdir "$WORK/case/shadow"
    cp -- "$WORK/fixtures/new.crt" "$WORK/case/shadow/server.crt"
    cp -- "$WORK/fixtures/new.key" "$WORK/case/shadow/server.key"
    cp -- "$WORK/fixtures/new.crt" "$WORK/served.crt"
    : >"$WORK/serve-shadow"
    jq -n --arg dir "$WORK/case/target" --arg shadow "$WORK/case/shadow" --arg type "$shadow_type" '[
        {Type:"bind", Source:$dir, Destination:"/tls"},
        {Type:$type, Source:$shadow, Destination:"/tls/server.crt"}
    ]' >"$WORK/mounts.json"
    run_job fail
    contains "$WORK/stderr" 'effective Docker mount'
    assert_restored
    [[ ! -f $WORK/reloads ]] || fail "$shadow_type shadow caused a reload"
done

# Duplicate effective mounts are ambiguous, not permission to pick one.
setup
old_proof
jq '[.[], .[0]]' "$WORK/mounts.json" >"$WORK/duplicate.json"
mv -- "$WORK/duplicate.json" "$WORK/mounts.json"
run_job fail
assert_restored
[[ ! -f $WORK/reloads ]] || fail 'Ambiguous effective mount caused a reload'

# Discovery searches every issuer and refuses two copies. Explicit paths select a pair.
setup
mkdir -p "$WORK/case/caddy/certificates/acme.example-issuer/directory/db.example.com"
issuer="$WORK/case/caddy/certificates/acme.example-issuer/directory/db.example.com"
cp -- "$WORK/fixtures/new.crt" "$issuer/db.example.com.crt"
cp -- "$WORK/fixtures/new.key" "$issuer/db.example.com.key"
printf 'unset SOURCE_CERT SOURCE_KEY\nCADDY_CERT_ROOT=%q\n' "$WORK/case/caddy/certificates" >>"$WORK/cert.conf"
run_job pass
assert_verified
mkdir -p "$WORK/case/caddy/certificates/second-issuer/db.example.com"
cp -- "$WORK/fixtures/new.crt" "$WORK/case/caddy/certificates/second-issuer/db.example.com/db.example.com.crt"
cp -- "$WORK/case/state/last-success" "$WORK/discovery-proof"
run_job fail
contains "$WORK/stderr" 'more than one issuer copy'
cmp -s "$WORK/case/state/last-success" "$WORK/discovery-proof" || fail 'Ambiguous discovery changed the proof'
printf 'unset CADDY_CERT_ROOT\nSOURCE_CONTAINER=caddy-fixture\nSOURCE_CERT=%q\nSOURCE_KEY=%q\n' "$issuer/db.example.com.crt" "$issuer/db.example.com.key" >>"$WORK/cert.conf"
run_job pass
assert_verified
printf 'unset SOURCE_CERT SOURCE_KEY\nCADDY_CERT_ROOT=%q\n' "$WORK/case/caddy/certificates/acme.example-issuer" >>"$WORK/cert.conf"
run_job pass
assert_verified
contains "$WORK/commands" 'exec caddy-fixture find'
contains "$WORK/commands" 'cp caddy-fixture:'

# Keep a deploy-owned 0664 lock intact. FD 8 must be read-only (no create-open).
setup
printf 'existing deployment lock\n' >"$WORK/box.lock"
chmod 664 "$WORK/box.lock"
lock_metadata_before=$("$REAL_STAT" -c '%u %g %a %h %d:%i' -- "$WORK/box.lock")
: >"$WORK/deploy-lock-owner"
: >"$WORK/check-read-only-lock"
printf 'DEPLOY_UID=1000\nDEPLOY_GID=1000\n' >>"$WORK/cert.conf"
run_job pass
assert_verified
contains "$WORK/lock-open-log" 'read-only'
[[ $(<"$WORK/box.lock") == 'existing deployment lock' ]] || fail 'Sync changed shared lock bytes'
[[ $("$REAL_STAT" -c '%u %g %a %h %d:%i' -- "$WORK/box.lock") == "$lock_metadata_before" ]] || fail 'Sync changed shared lock metadata'

# Pins do not permit unknown owners, groups, other-write, multiple links or creation.
for invalid_lock in unpinned uid gid partial other-write links symlink missing invalid-id; do
    setup
    old_proof
    chmod 664 "$WORK/box.lock"
    : >"$WORK/deploy-lock-owner"
    if [[ $invalid_lock != unpinned && $invalid_lock != partial ]]; then
        printf 'DEPLOY_UID=1000\nDEPLOY_GID=1000\n' >>"$WORK/cert.conf"
    fi
    case $invalid_lock in
        uid) printf 'DEPLOY_UID=1001\n' >>"$WORK/cert.conf" ;;
        gid) printf 'DEPLOY_GID=1001\n' >>"$WORK/cert.conf" ;;
        partial) printf 'DEPLOY_UID=1000\n' >>"$WORK/cert.conf" ;;
        other-write) chmod 666 "$WORK/box.lock" ;;
        links) ln "$WORK/box.lock" "$WORK/case/second-lock-link" ;;
        symlink)
            ln -s "$WORK/box.lock" "$WORK/case/symlink-lock"
            printf 'BOX_LOCK=%q\n' "$WORK/case/symlink-lock" >>"$WORK/cert.conf"
            ;;
        missing) rm -- "$WORK/box.lock" ;;
        invalid-id) printf 'DEPLOY_UID=4294967295\n' >>"$WORK/cert.conf" ;;
    esac
    run_job fail
    assert_restored
    [[ ! -s $WORK/commands && ! -f $WORK/reloads ]] || fail "$invalid_lock lock ran Docker"
    [[ $invalid_lock != missing || ! -e $WORK/box.lock ]] || fail 'Sync created a missing lock'
done

# Synthetic deployment ownership is 1000:1000 at 0755/0775; the SSL leaf is
# root:root 0755, files are separate readonly binds and the same pair owns 0664 lock.
setup
deployment_layout
: >"$WORK/check-read-only-lock"
run_job pass
assert_verified
contains "$WORK/lock-open-log" 'read-only'
[[ $(stat -c %a -- "$WORK/case/deployment") == 755 && $(stat -c %a -- "$WORK/case/deployment/app") == 775 && $(stat -c %a -- "${TEST_TARGET_CERT%/*}") == 755 && $(stat -c %a -- "$WORK/box.lock") == 664 ]] || fail 'Sync changed deployment directory or lock modes'

# Pins trust only the exact pair, not world write, symlinks, hardlinks or arbitrary
# target owners. They do not weaken the config or state directory checks.
for unsafe in unpinned owner group world-write symlink hardlink target-owner config state; do
    setup
    deployment_layout
    old_proof
    case $unsafe in
        unpinned)
            printf 'unset DEPLOY_UID DEPLOY_GID\n' >>"$WORK/cert.conf"
            rm -- "$WORK/deploy-lock-owner"
            chmod 600 "$WORK/box.lock"
            ;;
        owner) : >"$WORK/unsafe-owner" ;;
        group) : >"$WORK/unsafe-group" ;;
        world-write) chmod 777 "$WORK/case/deployment/app" ;;
        symlink)
            mv -- "$WORK/case/deployment/app/infra" "$WORK/case/deployment/app/real-infra"
            ln -s real-infra "$WORK/case/deployment/app/infra"
            ;;
        hardlink) ln "$TEST_TARGET_KEY" "$WORK/case/key-link" ;;
        target-owner) : >"$WORK/unsafe-target-owner" ;;
        config) chmod 640 "$WORK/cert.conf" ;;
        state) chmod 770 "$WORK/case/state" ;;
    esac
    run_job fail
    assert_restored
    case $unsafe in
        config) contains "$WORK/stderr" '0600' ;;
        state) contains "$WORK/stderr" 'writable parent' ;;
        unpinned|owner|group|world-write) contains "$WORK/stderr" 'target directory' ;;
        symlink|hardlink) contains "$WORK/stderr" 'target file is missing, symlinked or hard-linked' ;;
        target-owner) contains "$WORK/stderr" 'target file has an unsafe owner' ;;
    esac
    [[ ! -f $WORK/reloads ]] || fail "$unsafe deployment layout caused a reload"
done

# An acceptable lock leaf cannot make a writable parent safe.
for parent_mode in 777 1777 775; do
    setup
    old_proof
    mkdir "$WORK/case/unsafe-lock-parent"
    chmod "$parent_mode" "$WORK/case/unsafe-lock-parent"
    printf 'fixture lock\n' >"$WORK/case/unsafe-lock-parent/box.lock"
    printf 'BOX_LOCK=%q\n' "$WORK/case/unsafe-lock-parent/box.lock" >>"$WORK/cert.conf"
    run_job fail
    assert_restored
    [[ ! -s $WORK/commands && ! -f $WORK/reloads ]] || fail 'Unsafe lock ancestor ran Docker'
done

# Compare the actual opened inode with inspection, and the pathname after waiting.
for replacement in replace-before-open replace-during-lock; do
    setup
    old_proof
    : >"$WORK/$replacement"
    run_job fail
    contains "$WORK/stderr" 'shared lock changed'
    assert_restored
    [[ ! -s $WORK/commands && ! -f $WORK/reloads ]] || fail 'Replaced lock inode ran Docker'
    if [[ $replacement == replace-during-lock ]]; then contains "$WORK/lock-bypass" 'split inodes'; fi
done

# Exercise the narrow Linux sticky-directory exception with metadata fakes.
# Import only the real policy functions; never run the job against /run here.
sed -n '/^deployment_access()/,/^}/p; /^certificate_ancestors()/,/^}/p' "$ROOT/jobs/cert-sync.sh" >"$WORK/access.sh"
(
    # shellcheck source=/dev/null
    source "$WORK/access.sh"
    unset DEPLOY_UID DEPLOY_GID
    : >"$WORK/sticky-fixture"
    printf '1777\n' >"$WORK/sticky-mode"
    certificate_ancestors /run/lock lock || fail 'Root-owned sticky /run/lock should be allowed'
    if certificate_ancestors /run/lock target; then fail 'Sticky /run/lock was trusted for targets'; fi
    printf '777\n' >"$WORK/sticky-mode"
    if certificate_ancestors /run/lock lock; then fail 'Non-sticky /run/lock was trusted'; fi
    printf '1777\n' >"$WORK/sticky-mode"
    printf '1000 1000\n' >"$WORK/sticky-ids"
    if certificate_ancestors /run/lock lock; then fail 'Non-root sticky /run/lock was trusted'; fi
)
rm -- "$WORK/sticky-fixture" "$WORK/sticky-ids"

# A held shared lock blocks Docker and target writes, not just proof updates.
setup
old_proof
exec 7>"$WORK/box.lock"
flock -n 7
run_job fail
assert_restored
[[ ! -s $WORK/commands && ! -f $WORK/reloads ]] || fail 'Shared-lock contention ran Docker'
flock -u 7
exec 7>&-
setup
old_proof
exec 7>"$WORK/case/state/cert.lock"
flock -n 7
run_job fail
assert_restored
contains "$WORK/stderr" 'already running'
flock -u 7
exec 7>&-

# Expiry warnings use shared SMTP. Mail failure does not undo an already verified cert.
setup
{
    printf 'ALERT_CONFIG=%q\nEXPIRY_WARN_DAYS=365\n' "$WORK/alert.conf"
} >>"$WORK/cert.conf"
printf "SMTP_HOST='smtp.example.com'\nSMTP_USER='test'\nSMTP_PASS='fixture-secret'\nSMTP_FROM='ops@example.com'\nSMTP_TO=('one@example.com')\n" >"$WORK/alert.conf"
: >"$WORK/mail-fail"
run_job fail
assert_verified
[[ -s $WORK/mail-log ]] || fail 'Expiry warning did not use shared SMTP'
rm -- "$WORK/mail-fail"
run_job pass
assert_verified
printf 'cert-sync checks passed\n'
