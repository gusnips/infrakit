# Disk watch and certificate sync

```sh
bash "$(npm root -g)/@gusnips/infra/jobs/diskwatch.sh" /etc/infrakit/disk.conf
```

This checks local disk space and inodes, the entries a filesystem uses to track
files. It sends mail when a mounted disk enters warning or critical level, or
recovers. A successful run prints the number of filesystems checked and changes
sent. Resolve the job's absolute path once for cron and keep the packaged `jobs/`
files together. See the [package guide](../README.md#install-the-package) for installation.

Both jobs need Bash 4 or newer, GNU coreutils and `flock`. Certificate sync also
needs Docker, `jq` and OpenSSL 1.1.1 or newer. Disk watch needs GNU `df`. Shared
alert mail uses `curl` with TLS.

Config files are trusted Bash, not dotenv files. Use absolute paths, owner-only
0600 files and directories that other users cannot write. Config and state paths
must not contain symlinks. Each job needs its own state directory, owned by the
user running it at mode 0700. The job can create that directory. Do not put
configs, keys or state in git.

## Disk configuration

A minimal `/etc/infrakit/disk.conf`:

```bash
STATE_DIR=/var/lib/infrakit/disk
ALERT_CONFIG=/etc/infrakit/alert.conf
```

| Field                       | Default      | Meaning                                                      |
| --------------------------- | ------------ | ------------------------------------------------------------ |
| `STATE_DIR`                 | Required     | Private directory for the lock and delivered mail state.     |
| `ALERT_CONFIG`              | Required     | Private SMTP config used by the shared `alert.sh`.           |
| `DISK_LABEL`                | Hostname     | One-line name in the mail subject and progress log.          |
| `DISK_WARN` / `DISK_CRIT`   | `80` / `90`  | Warning and critical space-used percentages.                 |
| `INODE_WARN` / `INODE_CRIT` | `80` / `90`  | Warning and critical inode-used percentages.                 |
| `MIN_FILESYSTEM_BYTES`      | `1073741824` | Skip smaller filesystems, except a separate boot filesystem. |
| `BOOT_MOUNT`                | `/boot`      | Mount path with its own free-byte limits.                    |
| `BOOT_WARN_FREE_BYTES`      | `134217728`  | Warn at or below this free-byte count (128 MiB).             |
| `BOOT_CRIT_FREE_BYTES`      | `67108864`   | Critical at or below this free-byte count (64 MiB).          |
| `REQUIRED_MOUNTS`           | `()`         | Bash array of mounts that must appear in both scans.         |

Configured percentages must be 1 to 100, with warning below critical. GNU `df`
can report usage above 100% when available space is negative. That usage remains
critical; negative available space is treated as zero free bytes. Byte counts must be
positive integers of at most 18 digits. The boot warning count must exceed its
critical count. Use exact mount paths in `REQUIRED_MOUNTS`, including spaces:

```bash
REQUIRED_MOUNTS=('/' '/data with spaces')
```

The job scans local filesystems, excluding `tmpfs`, `devtmpfs`, `overlay` and
`squashfs`. A separate `/boot` is checked even below the normal size floor. If
`/boot` is part of `/`, there is no separate boot check.

Space and inode limits both apply. The worse level wins. At a boot mount, its
free-byte limits can raise that level too. Recovery means all relevant values
are below their warning percentages and above the boot warning free-byte count.
A critical disk that improves only to warning sends a warning, not a recovery.
A healthy first run sends no mail.

Delivered state is one private `disk-delivered.tsv` file. Its first line is
`infrakit-disk-v1`. The second is the active mail route's SHA-256 hash. Each
remaining line holds `ok`, `warn` or `crit`, a tab, then the full mount path.
The file is replaced atomically after a complete scan and any required mail
sends. Failed, empty or malformed `df` output keeps the previous record. A
changed mount table between the space and inode scans also fails. Fix the
reported mount or GNU tool issue, then run the same command again.

The hash includes the sender, sorted recipients, SMTP host, port and transport.
Recipient order and password changes do not resend critical mail. A new sender
or recipient does. A changed route starts with no delivered levels; switching
back never revives its old levels. A complete healthy scan can record a changed
route with no level rows because no mail was due. Failed scans and failed SMTP
requests never advance the record, so the next run retries.

Without `ALERT_CONFIG`, the job fails without recording delivery. Adding valid
mail config while a disk is already critical sends its first alert immediately.
Historical `disk-smtp-<hash>.tsv` files are not read or imported.

Disk watch loads SMTP settings once per run. It writes the resolved values as
literal Bash into a private `.disk-scan.*/alert.conf` file. Both the route hash
and shared `alert.sh` use those values, even if the original config changes
during the scan. Successful runs remove that directory. Failed runs retain it
and SMTP details inside it. These files can contain credentials. Keep them
private and remove them after fixing the failure.

For either job, the shared alert config has these fields:

```bash
SMTP_HOST=smtp.example.com
SMTP_USER=server-alerts
SMTP_PASS='replace with the provider password'
SMTP_FROM=ops@example.com
SMTP_TO=('oncall@example.com')
# SMTP_PORT=587
# SMTP_TRANSPORT=starttls
```

Use bare email addresses. `SMTP_PORT` is 1 to 65535. `SMTP_TRANSPORT` is `starttls`
or `tls`; the default is `starttls` on port 587. For TLS on connection, set both
`SMTP_TRANSPORT=tls` and the provider's port, commonly 465. Passwords go through a
private curl config, never curl's command line. Test delivery with the shared
alert's [labeled setup test](../README.md#alerts-and-heartbeat-pings) before scheduling either job.

## Certificate configuration

```sh
bash "$(npm root -g)/@gusnips/infra/jobs/cert-sync.sh" /etc/infrakit/database-tls.conf
```

Caddy obtains public Let's Encrypt certificates. These are not self-signed
certificates. Sync copies the chosen Caddy pair into the files PostgreSQL already
uses, reloads its config and checks the certificate PostgreSQL actually serves.
It never restarts a container.

A host-source config:

```bash
STATE_DIR=/var/lib/infrakit/database-tls
CERT_HOSTNAME=db.example.com
CADDY_CERT_ROOT=/var/lib/caddy/.local/share/caddy/certificates
DB_CONTAINER=postgres
TARGET_CERT=/etc/database-tls/server.crt
TARGET_KEY=/etc/database-tls/server.key
CONTAINER_CERT=/tls/server.crt
CONTAINER_KEY=/tls/server.key
```

The target files must already exist as regular, single-link files in a protected
directory. They should hold the working pair, not empty placeholders. Docker's
most-specific mount for each container path must map exactly to the configured
host file. File binds, directory binds and named volumes with a verified host
`Source` path are supported. A nested bind, volume or `tmpfs` can hide a parent
mount; sync checks that effective mount, not the hidden parent. It never assumes
where Docker stores volumes.

PostgreSQL's `ssl_cert_file` and `ssl_key_file` settings must use the configured
container paths. Run as a user allowed to write the files, set their PostgreSQL
UID/GID and call `pg_reload_conf()`. UID and GID come from `id postgres` inside
the database container, not a hard-coded number. Sync checks the mount, database
paths and account before allowing PostgreSQL-owned targets or directories within
that verified mount. Group write for that service account is not allowed.

| Field                              | Default                               | Meaning                                                                                  |
| ---------------------------------- | ------------------------------------- | ---------------------------------------------------------------------------------------- |
| `STATE_DIR`                        | Required                              | Separate private directory for proof, lock and rollback data.                            |
| `CERT_HOSTNAME`                    | Required                              | Database hostname the certificate must cover.                                            |
| `DB_CONTAINER`                     | Required                              | Running PostgreSQL container.                                                            |
| `TARGET_CERT` / `TARGET_KEY`       | Required                              | Existing absolute host file paths.                                                       |
| `CONTAINER_CERT` / `CONTAINER_KEY` | Required                              | Corresponding absolute paths PostgreSQL uses inside the container.                       |
| `SOURCE_CERT` / `SOURCE_KEY`       | Either this pair or `CADDY_CERT_ROOT` | Explicit absolute source paths.                                                          |
| `CADDY_CERT_ROOT`                  | Either this or the explicit pair      | Search every issuer below this directory for `<hostname>/<hostname>.crt`.                |
| `SOURCE_CONTAINER`                 | Unset                                 | Read source paths inside this Caddy container instead of on the host.                    |
| `DB_USER` / `DB_NAME`              | `postgres` / `postgres`               | Role and database for local `psql` calls inside the container.                           |
| `VERIFY_HOST` / `VERIFY_PORT`      | `127.0.0.1` / `5432`                  | Direct PostgreSQL TLS endpoint, not a pooler. Hostname or IPv4 address; port 1 to 65535. |
| `VERIFY_ATTEMPTS`                  | `5`                                   | Served-certificate probes, 1 to 30, one second apart.                                    |
| `VERIFY_TIMEOUT_SECONDS`           | `10`                                  | Per-probe timeout, 1 to 60 seconds.                                                      |
| `EXPIRY_WARN_DAYS`                 | `14`                                  | Warn within this many days, 1 to 3650.                                                   |
| `DEPLOY_UID` / `DEPLOY_GID`        | Unset                                 | Pin the trusted deployment account for the shared lock and target directories.           |
| `BOX_LOCK`                         | `/var/lock/box-deploy.lock`           | Existing shared lock also used by server deploys.                                        |
| `BOX_LOCK_WAIT_SECONDS`            | `900`                                 | Wait for that lock, 1 to 3600 seconds.                                                   |
| `ALERT_CONFIG`                     | Unset                                 | Shared SMTP config for failure and expiry alerts.                                        |

`BOX_LOCK` must already exist as a regular, single-link file. By default, only
root or the job user's ownership is accepted, with no group or other write
access. If deploys use another account or a group-writable lock, check that
account's user and group IDs, then pin both in the private config:

```bash
DEPLOY_UID=1000
DEPLOY_GID=1000
```

These IDs are examples, not values to copy without checking. Both must be numeric
IDs from 0 to 4294967294. With both pins set, the lock must belong to exactly that
user and group. The same pair permits deployment-owned target directories and
files, including group-write modes such as 0775 and 0664. Root and the job user
remain trusted when there is no group or other write access. Other owners and
other-user write are refused. Setting just one ID fails. Sync does not change
existing directory owners or modes. Config files and `STATE_DIR` keep their
stricter checks; these pins do not grant access there.

Every resolved lock ancestor is checked. Other-user write is allowed only at
root:root `/run/lock` with mode 1777, whose sticky bit stops users from replacing
someone else's lock. Arbitrary sticky directories and non-sticky writable
parents are refused. Target ancestors never get this exception.

Sync opens the existing lock read-only, without creating or truncating it. This
also works when Linux `fs.protected_regular` blocks root from create-opening a
deploy-owned file in root's sticky `/run/lock`. Opening read-only does not make
the lock shared: sync still takes an exclusive `flock`. It checks that the open
file is the inspected inode and that the pathname still names it after waiting.
Sync never changes lock bytes, ownership or mode, and never creates a missing
lock. The resolved path may pass through the system's `/var/lock` directory
symlink; the lock file itself must not be a symlink. Use the same lock file as
deploys and never replace it while a job holds it. Sync takes this lock before
writing certificate targets.

For a Caddy Docker source, set `SOURCE_CONTAINER=caddy` and use container paths,
for example `CADDY_CERT_ROOT=/data/caddy/certificates`. Discovery works under any
issuer directory. Zero or multiple matches fail without changing targets. To
choose one issuer, remove `CADDY_CERT_ROOT` and set `SOURCE_CERT` and `SOURCE_KEY`
to that exact pair. Do not set both forms. Source paths must resolve to regular
files without symlinks.

Sync checks the hostname, validity dates and matching public keys before any
target write. Caddy keys need no password prompt. The private key is copied only
through files; its contents never enter a command argument or a public log.
Every run reloads and verifies, even if the target bytes are unchanged. Identical
files without a served-certificate proof cannot count as a verified sync.

## Certificate proof and recovery

Targets are written in place, not renamed. Docker can bind-mount each file's
inode, so an atomic rename could leave PostgreSQL seeing the old file. The job
prepares the target binding, old bytes, owners, modes and proof in private
`STATE_DIR/staging/`. Only after its `ready` marker is written does one rename
publish the complete directory as `pending/`. No target write can start before
that rename. The installed certificate is mode 0644 and the key is 0600, both
owned by the detected PostgreSQL UID/GID. Sync sets those restricted modes before
transferring ownership. Rollback restores the saved owner before its saved mode,
so an interruption cannot leave a PostgreSQL-owned group-writable target that
blocks recovery. PostgreSQL keeps its old TLS context until reload.

Only a successful reload and matching SHA-256 fingerprint from a fresh PostgreSQL
TLS connection advance `STATE_DIR/last-success`. The private, atomically written
proof has four lines:

1. `infrakit-cert-v1`
2. SHA-256 binding of the hostname, container, database role/name, target and container paths, and verification endpoint
3. The served leaf certificate's SHA-256 fingerprint, without colons
4. Verification time in Unix seconds

`.cert-owner` keeps the same binding. Changing a target or endpoint requires a
new state directory; keep the old directory until recovery is no longer needed.
A failed directory read never counts as empty state and never adopts it.

On retry, unpublished staging is discarded only inside the checked, job-owned
state directory. If it has a binding, it must match this target. A ready marker
always requires that binding. An interrupted unready `pending/` from an earlier
run can be discarded because no target write could have started. Ready pending
recovery must have its matching binding and private rollback files. A missing
or different binding fails without touching the targets.

A failed reload or TLS read-back restores the old target bytes, owner and mode
without changing their inodes, and preserves the old proof. Rollback also reloads
and checks the old served fingerprint. If that check fails, private `pending/`
recovery data stays in place. Fix PostgreSQL's permissions, SSL settings or the
direct verification endpoint, then run the same command. An interrupted write
is recovered before a new source pair can be installed. Do not delete pending
recovery data to bypass an error.

Failures retain a private `.cert-check.*` directory with step details. Failed SMTP
requests retain their own private details beside the alert config. These may
include key files or credentials, so keep them private and remove them only after
checking the failure and completing recovery. Successful runs remove temporary
checks and rollback data.

An expiry warning is sent after the certificate is verified. If that mail fails,
the verified files and proof stay installed; retry after fixing SMTP. If expiry
is near and `ALERT_CONFIG` is missing, the job exits nonzero and asks you to set
it and check Caddy renewal. Publishing this package schedules or installs nothing.

## Local checks

Run only these focused checks. They use fake `df`, curl, Docker and PostgreSQL
TLS responses, with local OpenSSL fixtures. They do not need Docker or Colima
running, send mail or contact a server. Fixture certificates are self-signed only
for these local checks.

```sh
bun install
shellcheck -x --source-path=SCRIPTDIR jobs/diskwatch.sh jobs/cert-sync.sh tests/diskwatch.test.sh tests/cert-sync.test.sh
bash tests/diskwatch.test.sh
bash tests/cert-sync.test.sh
```

On macOS, put the installed GNU tools first:

```sh
export PATH=/usr/local/opt/bash/bin:/usr/local/opt/coreutils/libexec/gnubin:/usr/local/opt/util-linux/bin:/usr/local/bin:$PATH
```

The certificate check intentionally kills fake jobs to test recovery before
publication and after a partial write. A shell may print `Killed` for these
cases; the final check result must still say `cert-sync checks passed`. These
checks stay out of `check` and CI.
