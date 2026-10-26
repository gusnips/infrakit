# infrakit

Read server state, print log limits, run encrypted backups and check disks or sync PostgreSQL certificates on Debian or Ubuntu.

```sh
gusnips-infra inspect ops@server.example.net
```

Lists problems and what to check next. It reads over SSH and changes no server files. A bare host checks only the host baseline; use a private manifest to list the services and files you expect. A problem or an unverified check exits 1.

```sh
gusnips-infra log-policy /etc/infrakit/log-policy.json
```

Prints configuration text, warnings and the reloads you would need. It installs nothing. See [server inspection and installation plans](docs/cli.md), [log policies and the guarded PM2 parser fix](docs/log-policies.md), or [disk watch and certificate sync](docs/ops-jobs.md) for configuration and commands.

## Install the package

```sh
npm install --global @gusnips/infra@0.1.3
```

The CLI needs Node.js in PATH and has no JavaScript runtime dependencies. Publishing or installing the package does not schedule a job or restart a service. `gusnips-infra install` only prints a plan; its `--apply` is refused before SSH. The PM2 parser command has its own explicit `--apply`, which changes only a reviewed local module source file and never calls PM2.

Run a packaged backup with one private job file:

```sh
bash "$(npm root -g)/@gusnips/infra/jobs/backup.sh" /etc/infrakit/nightly.conf
```

A verified run prints `Offsite verified:` with the snapshot name and number of encrypted files. A failed run exits nonzero, keeps its local files and says which step to fix. For cron, use the resolved absolute job path instead of running npm each time. Keep the `jobs/` files together.

Disk watch sends warning and recovery mail for space and inode limits. Certificate sync checks a Caddy certificate pair, copies it into existing PostgreSQL files, reloads PostgreSQL and verifies the served fingerprint. It never restarts a container. Both need private configuration and separate scheduling; see [the job guide](docs/ops-jobs.md).

There is no automatic installer or restore automation. Inspection reads local backup receipts, not current remote object availability. Inspection's certificate checks read expiry from files, not the certificate served to clients, hostname coverage or trust chains. A local mail-test confirmation does not prove provider delivery history. Set `sudo: true` in a private manifest for root-private inspection reads; the CLI uses `sudo -n`, carries only `SSH_CONNECTION` into the read-only probe, never asks for a password and never changes permissions. The fixed sudo command also permits the SSH account's protected 0600 data files. Backup data must match the declared `ownerUid`. These read-only checks do not relax job config or writable-state ownership rules.

## Before the first run

Jobs need Bash 4 or newer, GNU coreutils, GNU find, GNU tar, gzip, curl, flock, age and rclone 1.75.2 or newer. Hosted PostgreSQL needs `pg_dump` and `pg_restore` clients at least as new as the database server. Docker PostgreSQL profiles need Docker access and use the dump and restore tools inside the named container; no host PostgreSQL client is needed. D1 needs jq and SQLite with `-safe` support. The copy job needs jq too. Host Redis needs redis-cli; container Redis uses redis-cli inside its container. Redis 7 or newer is required.

Configuration files are trusted Bash code, not dotenv or JSON. Use assignments and indexed arrays. Every file that is sourced, plus libpq service/password files and Redis password files, must be a regular, single-link `0600` file. Its owner and every ancestor must be root or the job's user, with no group or other write access. Symlinks, relative paths, `.`/`..` segments and world-writable parents are refused before sourcing. This includes `/tmp`. Configuration is not a sandbox: its owner can run code as the job's user.

Run jobs with private files controlled by the job's user or root. Keep configuration under a protected directory such as `/etc/infrakit` (`0700`). Never put a password, API token or private age key in a command line. Keep the private age key off the server and test its recovery copies separately.

Start with new, empty directories. Existing job directories must be owned by the job's user at `0700`. Do not use a system root or overlap the archive, state and local test remote. The runner never adopts another script's backups. A failed directory read stops adoption; it does not mean the directory is empty. Existing state files must be single-link `0600` files owned by the job's user. A directory, link or unsafe file at a proof path is refused without replacing it.

## Common job fields

Required:

- `JOB_ID`: 1–63 letters, digits, dots, underscores or hyphens. Start with a letter, digit or underscore. No `..`.
- `PROFILE`: `supabase-docker`, `postgres-docker`, `hosted-postgres`, `files` or `d1`.
- `ARCHIVE_DIR`: absolute, dedicated local archive directory.
- `STATE_DIR`: separate absolute, dedicated state directory. Its `job.lock` allows one run at a time. A second run fails rather than reporting success.
- `REMOTE_PREFIX`: nonempty path below the bucket. Use letters, digits, dots, slashes, underscores or hyphens; start with a letter, digit or underscore. No dot segments, `..`, glob characters, empty segments or trailing slash. A bucket root is never a retention target.
- `BACKUP_AGE_RECIPIENT`: one public age recipient. No plaintext upload option exists.

Optional:

- `BACKEND`: `s3` or `r2` (`r2` by default, or `s3` when `S3_ENV` is set). `local` is for isolated checks only and requires `LOCAL_REMOTE_DIR`, an absolute private directory separate from archive and state.
- `S3_ENV` / `R2_ENV`: required for the `s3` or `r2` backend. Path to the private Bash remote file below.
- `LOCAL_KEEP_DAYS`: 1–36500 days, default `7`.
- `REMOTE_KEEP_DAYS`: 1–36500 days, default `30`.
- `ALERT_CONFIG`: private SMTP file. Unset means no email alerts. When set, a failed job sends an authored summary, not its raw logs. Mail failure never turns a failed backup into success.
- `HEARTBEAT_CONFIG`: private heartbeat file. Unset means no outside monitoring. When set, start, success and failure each need a URL. A failed start or success ping makes the job exit nonzero and skips retention, even if the offsite copy was verified.
- `CONFIG_PATHS`, `STORAGE_PATHS`: indexed arrays of required absolute host paths. Missing paths fail the snapshot. Directories are allowed; their contents are not a transactionally consistent snapshot. Top-level paths and parents cannot use symlinks. Tar keeps their root-relative shape and does not follow symlinks inside a listed directory. Do not list a data directory, a whole project by habit or a parent of the job directories.
- `CONTAINER_CONFIG_PATHS`: indexed array of required absolute **regular file** paths inside `CONTAINER`. Files are checked with `readlink -f` and `test -f`, then copied with `docker cp`. Symlinked paths and directories fail. `container-configs.tar.gz` keeps each file's root-relative shape. Only list files needed for recovery. The container must supply `readlink -f`.

The runner clears inherited `TAR_OPTIONS` after loading profile configuration. Those options cannot exclude required host, storage or container recovery files. Deliberate database table exclusions still use `DUMP_ARGS`.

For example, a host-file job:

```bash
JOB_ID=nightly
PROFILE=files
BACKEND=s3
ARCHIVE_DIR=/var/backups/infrakit/nightly
STATE_DIR=/var/lib/infrakit/nightly
S3_ENV=/etc/infrakit/s3.conf
REMOTE_PREFIX=backups/nightly
BACKUP_AGE_RECIPIENT='replace-with-your-public-age-recipient'
CONFIG_PATHS=(/etc/my-service/settings.conf /etc/my-service/keys.conf)
```

For AWS S3, `/etc/infrakit/s3.conf` contains:

```bash
S3_PROVIDER='AWS'
S3_REGION='sa-east-1'
S3_ACCESS_KEY_ID='replace-with-your-access-key'
S3_SECRET_ACCESS_KEY='replace-with-your-secret-key'
S3_BUCKET='your-backup-bucket'
```

For Cloudflare R2, use `R2_ENV=/etc/infrakit/r2.conf` (or `S3_ENV`):

```bash
R2_ACCOUNT_ID='replace-with-your-32-digit-hex-account-id'
R2_ACCESS_KEY_ID='replace-with-your-access-key'
R2_SECRET_ACCESS_KEY='replace-with-your-secret-key'
R2_BUCKET='your-backup-bucket'
```

Choose one credential format. An explicit `S3_PROVIDER` uses the complete `S3_*` key and bucket settings; it never fills a missing S3 key from `R2_*`. With no S3 settings, legacy `R2_*` files keep working. `S3_SESSION_TOKEN` is optional for temporary credentials.

AWS needs `S3_REGION`; leave `S3_ENDPOINT` unset for AWS's regional endpoint. Other S3-compatible providers use `S3_PROVIDER='Other'` and `S3_ENDPOINT`. Cloudflare also accepts `S3_PROVIDER='Cloudflare'` with S3 keys and an endpoint. `R2_ENDPOINT` can replace `R2_ACCOUNT_ID` in a legacy file. Endpoints must be bare HTTPS origins, without a path or credentials. Missing remote or age settings fail; they never become a local-only success. Rclone reads credentials from its process environment, not argv or a shared rclone config. Uploads use `--s3-no-head`; verification still downloads every encrypted object. The runner sets no object ACL, so AWS buckets with ACLs disabled work.

### Copy existing backups to another provider

```sh
bash /opt/infrakit/0.1.3/jobs/backup-sync.sh /etc/infrakit/sync.conf
```

This copies existing files and checks their bytes at the destination. The first run copies the history. Later runs transfer missing files and still check the source files against the destination. It never deletes files, changes the active provider or rewrites backup receipts. Existing destination files with different bytes stop the job rather than being replaced.

Use a private `0600` Bash file for the transfer:

```bash
SOURCE_ENV=/etc/infrakit/r2.conf
TARGET_ENV=/etc/infrakit/s3.conf
SOURCE_PREFIX=backups/nightly
TARGET_PREFIX=backups/nightly
STATE_DIR=/var/lib/infrakit/copy-nightly-to-s3
```

The two remote files use the S3 or R2 settings above. Use separate credentials, with read-only source access and target write access limited to the selected prefix. Keep writers paused while copying the selected source. A failed read, empty source, changed inventory or failed byte check stops the run. Read-back checks use network traffic and may incur provider charges.

The copy keeps the original bytes, including encryption and completion markers. It needs no private age key. Copy only complete backup sets; a byte check cannot make an incomplete source recoverable. A logical dump, an encrypted snapshot and a physical PostgreSQL repository have different recovery rules. This generic command refuses pgBackRest repository trees: use pgBackRest's own repository setup and a reviewed WAL migration procedure for those. It does not copy bucket version history, delete markers, lifecycle policies or access rules.

For a fresh backup, run `backup.sh` with the chosen provider's job file. Use a separate archive and state directory per provider. Historical copies are not adopted by the new job's retention, and their original receipts remain unchanged. Version 0.1.2 cloud-state directories did not record provider identity; keep them and use new directories when adopting this release. Switching back means copying from the currently active provider to the other one, then running that provider's existing job. Never delete or edit ownership markers to force a switch.

## Profiles

### PostgreSQL in Docker

Use `PROFILE=postgres-docker` or `PROFILE=supabase-docker`, with these fields:

```bash
CONTAINER=database
DB_USER=postgres
DB_NAMES=(postgres _supabase)
GLOBALS_USER=supabase_admin
DUMP_ARGS=('--exclude-table-data=public.large_cache')
```

`CONTAINER`, `DB_USER` and a nonempty `DB_NAMES` array are required. Each name follows the `JOB_ID` alphabet and length rules. `GLOBALS_USER` defaults to `DB_USER`. It must be allowed to export cluster roles. The container must support local, noninteractive authentication; the runner never supplies a database password in argv.

The runner collects `globals.sql.gz` and one custom-format dump per database (`db-001.dump`, `db-002.dump`, and so on). The encrypted manifest maps each dump to its database name. Dumps must be nonempty and pass the container's own `pg_restore --list`, with the saved archive sent through stdin. Globals must include PostgreSQL's completion footer. One failed database does not prevent another database or the listed files from being collected.

`DUMP_ARGS` accepts only `--exclude-table=` and `--exclude-table-data=` arguments. It cannot change the connection, output, format or schema selection. Write any deliberate exclusions into your restore plan.

The Supabase profile requires both `postgres` and `_supabase` in `DB_NAMES`, plus a nonempty host or container config array. You must include the actual init SQL, database overrides, pgsodium key, auth/storage settings and application encryption keys that recovery needs. The runner cannot discover which keys your application uses. Host mounts go in `CONFIG_PATHS`; files that only exist inside the database container go in `CONTAINER_CONFIG_PATHS`. For example, when these are the container's actual files:

```bash
CONTAINER_CONFIG_PATHS=(
  /docker-entrypoint-initdb.d/init.sql
  /etc/postgresql-custom/pgsodium_root.key
)
```

List every required init file, not just this example, and check the archive before scheduling. A missing listed file fails the snapshot. Storage files go in `STORAGE_PATHS`; external object storage needs a separate backup job. A logical dump contains storage metadata, not the objects themselves, and is not a complete Supabase recovery plan.

### Hosted PostgreSQL

Required fields:

```bash
PG_SERVICE=backup
PG_SERVICE_FILE=/etc/infrakit/pg_service.conf
PG_PASS_FILE=/etc/infrakit/pgpass
HOSTED_EXPORT_SCOPE='All schemas available to the backup role. No globals, storage objects or service keys.'
```

`PG_SERVICE` is a libpq service name, not a URL. Both files are private. The service file identifies the host, port, database, role and TLS settings; the password file holds the password. For a remote database, configure certificate verification in the service file. Inherited libpq connection variables are cleared so cron cannot override the service.

The default dump includes all accessible non-system schemas in that one database. `DUMP_ARGS` can exclude tables as above. The role must be able to read every selected table. The runner does not dump cluster globals, claim superuser access or discover other databases. Set `HOSTED_EXPORT_SCOPE` to one line stating what that role can export and what is missing. It is recorded in the encrypted manifest. Add service keys, auth configuration and storage through explicit paths or separate jobs.

### Files

`PROFILE=files` needs at least one host path, container recovery file or configured Redis instance. It does not create a pretend database dump.

### Redis on the host or in Docker

Redis is optional in any profile. Set `REDIS_RDB` and either `REDIS_CONFIG` or `REDIS_PASSWORD_FILE`:

```bash
REDIS_CONFIG=/etc/infrakit/redis.conf
REDIS_RDB=/var/lib/redis/dump.rdb
REDIS_PORT=6379
REDIS_WAIT_SECONDS=120
```

- `REDIS_CONFIG`: private host file, read but never sourced. A simple, unquoted `requirepass` supplies authentication. If you set this path, the file must exist and pass private-file checks.
- `REDIS_PASSWORD_FILE`: private `0600` host file containing the exact password on one line. Use it for spaces, quotes, escapes or ACL-based setups. It replaces the need for `REDIS_CONFIG`, including for Docker Redis with no host redis.conf. A password is always required. The Redis user must allow INFO, BGSAVE and CONFIG GET for `dir` and `dbfilename`; named ACL users are not supported in this release.
- `REDIS_PORT`: 1–65535, default `6379`. The connection uses `127.0.0.1`.
- `REDIS_SOCKET`: optional absolute socket path, used instead of the port.
- `REDIS_WAIT_SECONDS`: 1–9999, default `120`. Each Redis command also has a 20-second timeout.
- `REDIS_CONTAINER`: optional explicit container name. When set, the socket/port and `REDIS_RDB` refer to paths inside that container. The private authentication file stays on the host. The container must provide redis-cli and `readlink -f`.

The password goes in `REDISCLI_AUTH`, including Docker's environment passthrough (`--env REDISCLI_AUTH`, with no value in argv). The runner first checks that `REDIS_RDB` matches the running instance's `dir` and `dbfilename`. A save counter alone cannot prove that a different old RDB is fresh. It then checks that no save is in progress, starts BGSAVE and waits for the save counter to increase with its result `ok`. It never uses blocking SAVE and never copies an old RDB on timeout or failure. Only then does it copy the host RDB or use `docker cp` and check the RDB header. This is a format check, not a Redis restore drill. Use one file job per Redis instance. Avoid overlapping schedules for jobs that share the same instance.

For container Redis, for example:

```bash
REDIS_CONTAINER=cache
REDIS_PASSWORD_FILE=/etc/infrakit/redis-password
REDIS_RDB=/data/dump.rdb
```

### Cloudflare D1

Use `PROFILE=d1` with `D1_ENV`, a private Bash file containing `CF_ACCOUNT_ID` (32 hex digits), `CF_DATABASE_ID` (UUID) and `CF_API_TOKEN`. The token must have permission to export that database. Set `D1_DOWNLOAD_HOSTS` to an indexed array of the **exact** HTTPS hosts used by the export. Only subdomains of `cloudflare.com` or `r2.cloudflarestorage.com` are accepted; no wildcards. The hostname must match the signed result URL exactly. Do not guess it or broaden the allowlist to unrelated hosts.

`D1_TIMEOUT_SECONDS` sets the polling deadline (1–9999 seconds, default `600`). The runner POSTs `output_format: polling`, then polls the same endpoint with `current_bookmark`. Pending responses omit status; completed responses use `complete`, failures use `error`. Invalid JSON, malformed fields or an unknown status fail the snapshot. A separate curl config downloads the signed URL without the API token or redirects. Empty/invalid SQL fails. SQLite safe mode validates the SQL in a new scratch database under the run directory, never in an existing database. Validation stops on the first SQL error, has a 600-second timeout and checks that SQLite read through the end of the export. The sealed artifact is `database.sql`.

**An export interrupts D1 queries.** Cloudflare says the database is unavailable for queries during export. Schedule it in a window where that interruption is acceptable. The API requires continued polling; if the job is stopped, it stops polling and Cloudflare automatically cancels the export. This runner has no cancel or resume command. A retry starts a new export and may interrupt queries again. The signed download URL expires after one hour. Failed responses and bookmarks stay in the private run files; never paste them into an alert.

Reference: [Cloudflare D1 export API](https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/export/).

## What success proves

A snapshot name is UTC `YYYYmmddTHHMMSSZ-` plus six random letters/digits. Local creation is atomic, and a successful remote-prefix listing must show no collision before upload. A failed listing is never treated as an empty remote.

Artifacts start at partial names. Collection continues after a source failure, but an incomplete run gets `INCOMPLETE`, exits nonzero and uploads nothing. Successful local artifacts and private diagnostics stay in the run directory. Local files, including credentials copied for recovery, are plaintext under `0700` directories. Only the `sealed/` directory is uploaded, with each artifact and the manifest encrypted by age.

The payload is uploaded without `complete.age`. It must pass `rclone check --download --one-way` and an exact file-path comparison before the encrypted completion marker is uploaded. The full set then passes the same download and path checks. Only then are its receipt, local `COMPLETE`, atomic `last-success` and `offsite-enabled` state recorded. Neither a successful upload alone nor a previous run's marker counts as a new success.

The proof has exactly five lines. `last-success`, `COMPLETE`, the receipt's `proof` and the plaintext inside encrypted `complete.age` use the same format:

```text
infrakit-snapshot-v1
<JOB_ID>
<SNAPSHOT>
<RUN_STARTED_UNIX_SECONDS>
<REMOTE_ROOT>
```

`REMOTE_ROOT` is `backup:<bucket>/<prefix>` for R2, or `backup:<absolute-local-remote>/<prefix>` for checks. The full snapshot location adds `/<SNAPSHOT>`. The timestamp names the **start of the backup**, not the verification time. The proof is only recorded as success after verification, so freshness is conservative for a long-running dump.

`STATE_DIR/receipts/<SNAPSHOT>/` contains `proof`, the exact encrypted `files` list and `complete.sha256`, the encrypted ownership marker's hash. The directory owner marker binds the job ID, archive directory and remote root. `offsite-enabled` records the full verified snapshot location. Do not edit or delete these files to hide a failed job.

## Retention and recovery

Retention runs only after a fully collected, sealed and verified new snapshot and its configured success ping. It considers only receipts belonging to this job and remote. Unknown historical backups, incomplete runs and unrecognized names stay untouched. Failed runs can consume disk space; inspect them and remove them by hand only after deciding what you need to keep.

Before deleting an old remote snapshot, retention checks that every remaining path belongs to its receipt and that `complete.age` matches its saved hash. It deletes that marker last, so an interrupted prune can safely resume on the next verified run. A failed read or unknown object stops retention. It uses individual file deletes, never a bucket-root purge. Local deletion also requires a matching `COMPLETE` proof. Small receipts stay after pruning; they grow by one per verified run in this release. Do not rely on bucket lifecycle rules that bypass these checks.

To recover, download a chosen sealed snapshot to a separate restore machine. Decrypt its manifest and artifacts with your offline age identity, compare each plaintext checksum to the manifest, then test the database and files in isolation. Never restore over a live database as a drill. Tar paths are root-relative; extract into a scratch directory first, inspect them and copy back only the paths your recovery plan names. Do not restore PostgreSQL globals blindly over an existing cluster.

A logical PostgreSQL dump does not replace a physical backup and write-ahead log (WAL) chain. It cannot restore every point between runs. File copies and dumps also do not promise one shared transaction across databases, storage and Redis. A verified download proves byte equality, not that every application key was listed or that a full application restore works.

## Alerts and heartbeat pings

```sh
printf 'This is a setup check.\n' | ALERT_CONFIG=/etc/infrakit/alert.conf bash "$(npm root -g)/@gusnips/infra/jobs/alert.sh" --test 'Backup mail'
bash "$(npm root -g)/@gusnips/infra/jobs/heartbeat.sh" /etc/infrakit/heartbeat.conf
```

Alert mail reads its body from stdin and accepts one single-line subject. `--test` adds `[Setup test]` to the subject. Missing mail configuration fails loudly. The private Bash file requires `SMTP_HOST` (hostname), `SMTP_USER` (login, no colon), `SMTP_PASS`, `SMTP_FROM` (bare address) and a nonempty `SMTP_TO` address array. `SMTP_PORT` defaults to `587` (1–65535); `SMTP_TRANSPORT` is `starttls` by default, or `tls` for implicit TLS. Both require TLS. Curl sees a private config path, never the password. Failed requests keep private diagnostics; raw responses are not printed.

Heartbeat accepts `start`, `fail` or `success` (the default). Each event needs its own `HEARTBEAT_START_URL`, `HEARTBEAT_FAIL_URL` or `HEARTBEAT_SUCCESS_URL` in the private Bash file. URLs must be HTTPS with no embedded credentials. A root URL such as `https://monitor.example.net` can omit the final slash. Pings require a 2xx response and do not follow redirects. A missing URL is explicitly not configured, not healthy. A monitor with only one URL can support a standalone success ping, but cannot serve as a backup job's three-event monitor.

For a host heartbeat that also checks backup freshness, add matching indexed arrays:

```bash
BACKUP_STATE_DIRS=(/var/lib/infrakit/nightly)
BACKUP_MAX_AGE_SECONDS=(172800)
```

Each age is 1–9999999 seconds, without leading zeros. Success checks each five-line proof against its owner marker, receipt and offsite marker. Missing, malformed, mismatched, future-dated or stale proof sends the failure URL instead and exits nonzero. Start/fail pings do not require backup proofs. This is a check of the last verified local record, not a new remote read or a host-wide health probe. An outside service must also alert when scheduled pings stop arriving.

Test by hand before scheduling cron. Give cron an explicit PATH with these tools, keep logs private and configure the monitor's expected interval and grace period to match your schedule. No cron or monitor account is created for you.

## Local checks

```sh
bun install
bun run build
bun tests/contracts.ts
bun tests/inspect-cli.test.ts
bun tests/ci.test.ts
bun tests/log-policy.test.ts /absolute/pm2-logrotate/package /absolute/pmx/package/lib/utils/autocast.js
bash tests/diskwatch.test.sh
bash tests/cert-sync.test.sh
bash tests/heartbeat.test.sh
bash tests/backup-sync.test.sh
bun run check
```

`contracts.ts` uses command stand-ins and real age encryption. It checks every profile, missing/unsafe config, dump failures, exact remote sets, locks, notification errors and secret redaction. It also checks Docker dump validation without host PostgreSQL clients, required Supabase recovery files, host/container Redis password files and stale paths, malformed D1 polling responses and SQL isolation. It includes a successful backup and a working prune as positive controls. GNU tar omission controls check decrypted host, storage and container archives with inherited exclusions. State checks cover unsafe targets, failed atomic publication and unread ownership directories without changing prior bytes.

`inspect-cli.test.ts` checks safe file reads with external FIFO deadlines, real offline SSH Match rules, newline backup and rotation names, sudo connection forwarding, read-only data-owner checks, cron-compatible install names, output redaction and the compiled Node CLI. `ci.test.ts` checks that a draft marked ready can trigger CI, alongside the default pull-request events. The offline SSH rule check needs OpenSSH's `sshd` and `ssh-keygen`; it never starts a daemon or opens a connection. `log-policy.test.ts` needs the reviewed upstream source files described in [local log-policy proof](docs/log-policies.md#local-proof). It checks rendering, guarded source apply/rollback and real gzip output with PM2 calls stubbed. Neither test uses a real SSH connection or PM2 daemon.

The [focused disk and certificate checks](docs/ops-jobs.md#local-checks) use command stand-ins and local OpenSSL fixtures. They check high disk percentages, negative free space, failed reads, mail retries, rollback, in-place writes, interrupted metadata changes and the pinned deploy-owned 0664 lock with a read-only descriptor. They do not use a real Docker service, change lock ownership or send mail. `heartbeat.test.sh` checks slashless HTTPS root URLs for every event, URL rejection, private curl config and rejected redirects with a local curl stand-in. Inspector owner checks model sudo and file owners; they do not run a real root or sudo process.

Run `bash tests/integration.sh` by hand when changing the backup or shared Bash library. It needs the tools above plus initdb, pg_ctl, psql, createdb and redis-server. Run it as a non-root user. It starts its own unique PostgreSQL cluster and two Redis processes, using private Unix sockets under your home directory with no TCP listeners. It decrypts and restores public and non-public tables from a real custom dump into that cluster's own test database, checks file contents and restores a real Redis RDB. Planted dump and stale Redis path failures must keep the previous proofs. It stops only those processes. Failed checks keep private logs; successful checks remove their scratch directory. It never uses Docker or a production database.

On macOS, install the corresponding Homebrew tools, including `gnu-tar` and `findutils`. Prepend this PATH so subprocesses use newer Bash, GNU coreutils, GNU tar, GNU find and flock:

```sh
export PATH=/usr/local/opt/bash/bin:/usr/local/opt/coreutils/libexec/gnubin:/usr/local/opt/gnu-tar/libexec/gnubin:/usr/local/opt/findutils/libexec/gnubin:/usr/local/opt/util-linux/bin:/usr/local/bin:$PATH
```

`check` runs lint, strict typecheck, formatting, a clean build and the packed-tarball check. It does not run tests. CI runs only typecheck. Run just the test files you changed by hand. `release:check` rebuilds and packs without publishing, verifies the exact shipped files and metadata, checks CLI/job execute bits, and runs Node and job help from the unpacked archive. It removes its own temporary pack files. A passing local check is not a production rollout or a live-provider test; verify each server's configuration before scheduling jobs.
