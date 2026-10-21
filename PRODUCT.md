# infrakit

## Who it's for

People who run Debian or Ubuntu servers and need to check server state, limit logs and verify encrypted backups.

## What it does

The `gusnips-infra` CLI reads a host over SSH and reports findings or unverified checks with a next step. A private JSON manifest lists the expected services, files and limits. An installation command checks local job-file metadata and prints a plan without connecting or installing anything.

Log policies print Docker, journald, ops-log and PM2 settings for review. A separate guarded command can preview, apply or reverse one reviewed pm2-logrotate parser fix. It changes only the local module's source file and never calls PM2 or restarts a service.

Bash jobs collect database dumps, host or container Redis snapshots and explicitly listed files. They encrypt them with age and check a fresh download on S3 or Cloudflare R2 before recording an offsite backup. `backup-sync.sh` syncs verified encrypted snapshots between providers or from local archives and rebinds local receipts when switching buckets. SMTP alerts and outside heartbeat pings use private configuration files. A host ping can require a recent verified backup proof.

Disk watch checks space, inodes and a separate boot filesystem, then sends mail when warning or critical levels change or a disk recovers. Certificate sync checks a Caddy pair, updates existing PostgreSQL certificate files in place, reloads PostgreSQL and verifies its served fingerprint. If a write or verification fails, the job tries to restore the previous files and proof. It keeps recovery data when it cannot confirm that restore. The job takes the existing shared deploy lock without creating or changing it.

## How people use it

Run `gusnips-infra inspect ops@server.example.net` to read the host baseline and get a list of problems. Use a private manifest for expected services and paths. Run `gusnips-infra log-policy /etc/infrakit/log-policy.json` to print log settings without installing them. Test each packaged Bash job with one private config file before scheduling it.

## What it can and can't do

- The compiled CLI runs on Node.js. Bash jobs need Bash 4 or newer and GNU tools, but no JavaScript runtime.
- Backup profiles cover PostgreSQL in Docker, self-hosted Supabase, hosted PostgreSQL, files and Cloudflare D1 exports.
- Every uploaded artifact is encrypted. The private age key belongs off the server.
- Retention only touches snapshots this job created and verified. Other scripts' backups stay untouched.
- Inspection checks local read-back receipts, not current remote objects. Inspection's certificate expiry comes from files, not served TLS. The separate certificate-sync job checks the served fingerprint, not a complete trust chain. Mail confirmation is a local operator record, not provider delivery history.
- Rendering log limits installs nothing. Reloads and container recreates need separate review and approval. The source-only PM2 parser fix does not prove the running module reloaded.
- A PostgreSQL dump is not its write-ahead log. There is no point-in-time recovery, restore automation or automatic server installation.
- Publishing the package changes no server. Operators choose when to install and schedule it.

## Voice

Sentence case. Short progress lines with measured counts. Errors name the failed step and the next action. Never print credentials, heartbeat URLs or raw provider errors.

## Principles

- Missing reads and proofs are unverified, not a pass. Missing backup credentials are a failure, not a local-only success.
- Job config and state files need exact mode 0600, one link and owner-controlled parents. Refuse unsafe paths before reading them. Bash job configuration is trusted code, not a sandbox. Read-only inspection also accepts the SSH account's data files when its fixed sudo command runs, and checks backup files against the declared owner UID. These data checks do not change job config or state ownership rules.
- Keep successful local artifacts when another artifact fails.
- Verify the new offsite copy before deleting an older snapshot.
- Start read-only. Keep source-file apply separate from installation, reloads and production changes.

## Proof

Runnable local checks live in `tests/`. They use throwaway data and command stand-ins, never production services or the operator's PM2 daemon. Tests run by hand, not in `check` or CI. Local checks do not claim a production deployment or a verified server configuration.
