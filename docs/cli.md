# Server inspection

```sh
gusnips-infra inspect ops@server.example.net
```

This reads the host baseline over SSH and lists findings with a next step. It changes no server files. It exits 1 if a check finds a problem or cannot verify required state. A bare host has no expected service inventory, so it cannot pass the complete inspection.

Use an absolute path to a private JSON manifest to check expected services and paths:

```sh
gusnips-infra inspect /home/operator/infra/server.json
```

The manifest must be a regular, single-link file of at most 1 MB at exact mode 0600, including no special mode bits. Its owner and every parent must be you or root, without group or other write access. Symlinks, relative paths, control characters and `..` segments are refused. Keep this file outside git. Never put passwords, tokens or private keys in it or in CLI flags.

## Version 1 manifest

This example uses fictitious names and paths. Replace them with the running server's inventory. Every inventory field is required: use an empty array for a service you do not run, or `null` for Docker or mail. These explicit values skip those checks; they do not prove that the service is absent. Missing `inventory` means the inventory is unknown, not empty. Missing `sshd` leaves effective SSH rules unverified.

```json
{
  "version": 1,
  "host": "ops@server.example.net",
  "port": 22,
  "disks": [
    {
      "path": "/",
      "maxUsedPercent": 90,
      "maxInodePercent": 90,
      "minFreeBytes": 1073741824
    }
  ],
  "maxJournalBytes": 1073741824,
  "sshd": {
    "user": "ops",
    "clientAddress": "192.0.2.10",
    "clientHost": "client.example.net",
    "permitRootLogin": "no"
  },
  "inventory": {
    "docker": {
      "containers": ["database"],
      "maxLogBytes": 10485760,
      "maxLogFiles": 5,
      "maxReclaimableBytes": 5368709120
    },
    "pm2": [
      {
        "unit": "pm2-ops.service",
        "pidFile": "/home/ops/.pm2/pm2.pid",
        "logsPath": "/home/ops/.pm2/logs",
        "after": ["redis-server.service", "docker.service"],
        "minStopSeconds": 120,
        "maxRotationAgeSeconds": 604800
      }
    ],
    "envFiles": ["/srv/example/api/.env"],
    "backups": [
      {
        "name": "nightly",
        "statePath": "/var/lib/infrakit/nightly",
        "archivePath": "/var/backups/infrakit/nightly",
        "remoteRoot": "backup:example-bucket/server/nightly",
        "ownerUid": 0,
        "maxAgeSeconds": 129600
      }
    ],
    "certificates": [
      {
        "name": "shared",
        "kind": "caddy",
        "path": "/var/lib/caddy/certificates/issuer.example/shared.example.net/shared.example.net.crt",
        "minValidDays": 30
      },
      {
        "name": "database",
        "kind": "postgres",
        "container": "database",
        "path": "/etc/postgresql/server.crt",
        "minValidDays": 30
      }
    ],
    "redis": [
      {
        "name": "cache",
        "port": 6379,
        "authFile": "/etc/infrakit/redis.password",
        "maxUsedPercent": 90
      }
    ],
    "mail": {
      "configPath": "/etc/infrakit/alert.conf",
      "testProofPath": "/var/lib/infrakit/mail-test",
      "maxAgeSeconds": 2592000
    }
  }
}
```

Unknown fields are refused. Lists hold at most 100 entries. Optional thresholds default to the numbers shown above. The default disk is `/`. Ports default to 22 for SSH and 6379 for Redis. `permitRootLogin` can be `no` or `prohibit-password`. Redis is read only on `127.0.0.1`; omit `authFile` only when the instance needs no password. A password file holds one line, uses mode 0600 and the same owner rules as the manifest. Its value is passed only through `REDISCLI_AUTH`, never argv.

Caddy certificate paths point to its shared storage, not a hardcoded issuer directory. Use the real `.crt` path. PostgreSQL may read a host copy or a copy inside an explicitly named container. Expiry checks do not prove which certificate clients receive, hostname coverage or the trust chain.

## Field rules

Unknown keys are rejected at every level. Integers cannot be strings or decimals. Unless a range is given below, a positive integer can be 1 to 9007199254740991. Every list has at most 100 entries.

- Top level: `version` and `host` are required. `version` is exactly 1. `port`, `sudo`, `disks`, `maxJournalBytes`, `sshd`, `inventory` and `install` are optional.
- `sudo`: boolean, default `false`. Set `true` only when the SSH account may run the fixed read-only probe through noninteractive sudo. It requests no password and preserves only the nonsecret `SSH_CONNECTION` field for the SSH rule check.
- `port`: 1–65535, default 22. `maxJournalBytes`: positive integer, default 1073741824.
- `disks`: a nonempty list. Each item requires `path`. `maxUsedPercent` and `maxInodePercent` are 1–100, default 90. `minFreeBytes` is 0–9007199254740991, default 1073741824. Omitting the list gives the single `/` disk with these defaults.
- `sshd`: requires `user`, `clientAddress` (an IPv4 or IPv6 address) and `clientHost` (a hostname without `user@`). `permitRootLogin` is `no` by default or `prohibit-password`. The `user` must be the account whose effective rules you need to inspect.
- `inventory`: requires `docker`, `pm2`, `envFiles`, `backups`, `certificates`, `redis` and `mail`, even when their values are empty or `null`.
- `docker`: `null`, or an object requiring `containers` (a list of names). `maxLogBytes` defaults to 10485760. `maxLogFiles` is 1–1000, default 5. `maxReclaimableBytes` defaults to 5368709120.
- Each `pm2` item requires `unit`, `pidFile`, `logsPath` and `after` (a list of service unit names). `minStopSeconds` defaults to 120. `maxRotationAgeSeconds` defaults to 604800.
- `envFiles`: a list of absolute file paths.
- Each `backups` item requires `name` (the job id), `statePath`, `archivePath` and `remoteRoot`. `ownerUid` is 0–4294967294, default 0. `maxAgeSeconds` defaults to 129600. A remote root uses `remote:bucket/prefix`, with only letters, digits, dots, underscores, hyphens and path slashes. Empty or dot segments, trailing slashes and `..` are rejected. Local backend roots are not accepted as offsite destinations.
- Each `certificates` item requires `name`, `kind` (`caddy` or `postgres`) and `path`. `container` is an optional name. `minValidDays` is 1–3650, default 30.
- Each `redis` item requires `name`. `port` is 1–65535, default 6379. `authFile` is optional. `maxUsedPercent` is 1–100, default 90.
- `mail`: `null`, or an object requiring `configPath` and `testProofPath`. `maxAgeSeconds` defaults to 2592000.
- `install`: requires `packageVersion`, `prefix` and a nonempty `jobs` list. Each job requires a unique `name`, `configPath`, `user` and `schedule`. Install job names start with a letter, digit or underscore and have at most 63 letters, digits, underscores or hyphens. Dots are refused because Debian ignores dotted filenames under `/etc/cron.d`. The version has three numeric parts and must match this package. Schedules have five numeric cron fields, including lists, ranges and steps within each field's bounds.

Inventory names start with a letter, digit or underscore and have at most 63 letters, digits, dots, underscores or hyphens. Install job names follow the narrower rule above. Backup job ids cannot contain `..`. Users start with a lowercase letter or underscore and have at most 32 lowercase letters, digits, underscores or hyphens. Service units end with `.service` and may also contain `@`. Paths are clean absolute paths of at most 4096 characters, without trailing slashes, repeated slashes, dot segments, control characters or text direction controls. Only a disk path can be `/`. These rules apply to both remote paths and local install config paths.

## What is measured

The CLI reads disk space and inodes, journald disk usage, a reboot marker, effective sshd rules for the supplied client context, and enabled daily unattended updates with an active timer. The SSH rule check adds the local server address and listening port from the remote session's `SSH_CONNECTION` to both the user and root contexts. It validates both connection addresses as IPv4 or IPv6 and both ports as 1–65535. Missing or malformed connection evidence is unverified, not a pass. Only those contexts are checked, not every possible login path. It checks that APT periodic updates are not disabled. It does not change their configuration or verify which package origins are allowed.

With an inventory it also reads running Docker `LogConfig`, the running container names, and Docker's reported reclaimable space. Docker `json-file` and `local` drivers require explicit `max-size` and `max-file` values. Other drivers remain unverified. Docker's reported reclaimable total is not a promise that pruning will free that much space.

PM2 checks read an existing daemon PID and its systemd cgroup. They never invoke PM2 or start a daemon. Unit ordering and the stop timeout come from systemd's loaded state. A live daemon whose unit is inactive or failed is a finding: the unit does not hold it, so its ordering and stop timeout do nothing. A unit that is starting or stopping is unverified. Rotation checks test real recent `*__*.log.gz` files with `gzip -t`; a setting alone does not pass, and no recent rotation is unverified. Each filename is read with a NUL separator, so a newline cannot split it into other valid gzip paths. A failed directory read is unverified, even when it returned some names.

Env checks read modes and sibling backup names, not contents. Names are read with NUL separators, so a newline in a backup name cannot hide it. A failed directory read is unverified even if it returned some names. Backup checks use the shared library's five-line `last-success`: format (`infrakit-snapshot-v1`), job id, snapshot name, Unix time in seconds and remote root. `name` is the expected job id, not a display label. `archivePath` and `remoteRoot` must match both archive and state ownership markers. The proof and receipt files must have the expected `ownerUid` (0 for root by default) and mode 0600. Receipts need a matching proof, a sorted unique encrypted file list containing `complete.age`, `manifest.txt.age` and at least one artifact, and a 64-character marker hash. The `offsite-enabled` marker must name that exact remote snapshot. The check reads only these local records from a verified upload and download. It does not contact the remote store or prove that the objects still exist. Legacy JSON proofs do not pass.

Mail checks look for the required SMTP assignments and reject known empty values. They do not execute Bash config, prove that expressions resolve to usable values, test credentials or infer historical delivery. After sending a labeled setup test and confirming it arrived, the operator can record this private three-line proof:

```text
infrakit-mail-test-v1
<Unix time in seconds when the recipient confirmed receipt>
recipient-confirmed
```

The proof must use mode 0600. A stale proof, a proof in the future or one older than the config does not pass. This is an operator's record, not provider delivery history. The alert job does not create it automatically.

SSH uses key-only batch login and existing trusted host keys. Hosts use a DNS name or IPv4 address, with an optional `user@` prefix; IPv6 destinations are not supported in version 1. An inspection times out after 120 seconds and refuses output above 1 MB. The remote host needs Bash 4 or newer, GNU tools and read access to the expected services and files. Missing tools, reads and proofs are unverified, never a pass. Remote error text is not printed.

By default the probe runs as the SSH account. For root-private reads, add `"sudo": true` to the private manifest and arrange noninteractive sudo access to this fixed command:

```sh
sudo -n env SSH_CONNECTION="${SSH_CONNECTION-}" bash --noprofile --norc -s -- infrakit-inspect-sudo
```

Only that nonsecret connection field is carried through sudo; there is no `sudo -E` or password prompt. The fixed command's final marker lets the read-only probe use sudo's generated `SUDO_UID` as the SSH account's expected data owner. SMTP config, mail confirmation and Redis password files may belong to root or that account, with single-link mode 0600 and protected parents. Backup files still need the manifest's exact `ownerUid`; their parents may belong to root or that owner. An inherited owner variable alone grants no access. Job config sourcing and writable state keep their stricter root-or-job-user rules. A denied sudo request fails inspection. Grant the needed access through your server's policy, then retry; inspection will not change file permissions. This option does not enable `install --apply`, and an installation plan still opens no SSH connection.

## Installation plan

```sh
gusnips-infra install /home/operator/infra/server.json
```

This checks private local job-file metadata, without reading or executing its contents, and prints a plan. It opens no SSH connection. Add this optional field to the manifest; each `configPath` refers to a local Bash job config, not a remote file:

```json
{
  "install": {
    "packageVersion": "0.1.5",
    "prefix": "/opt/infrakit",
    "jobs": [
      {
        "name": "nightly",
        "configPath": "/home/operator/infra/nightly.conf",
        "user": "root",
        "schedule": "17 3 * * *"
      }
    ]
  }
}
```

The version must match the installed package exactly. Schedules have five numeric cron fields. Job names must be unique. The plan places versioned jobs under the prefix, configs at `/etc/infrakit/<name>.conf` and new cron files at `/etc/cron.d/infrakit-<name>`.

`install --apply` is unsupported and exits 1 without connecting. Job syntax and settings are not validated by a plan. Test each job before scheduling it. Nothing restarts, recreates containers, upgrades packages, changes PM2 or DNS, deletes old jobs or publishes a package. The [log-policy PM2 parser command](log-policies.md#pm2-compression-fix) has a separate, explicit `--apply` that replaces only a guarded local source file; it is not an installer.
