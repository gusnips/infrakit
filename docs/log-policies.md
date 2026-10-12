# Log policies

```sh
gusnips-infra log-policy /etc/infrakit/log-policy.json
```

Prints JSON containing config text, warnings and the reloads you would need. It does not install anything, connect to PM2, restart Docker, recreate containers or delete logs. The installed CLI needs Node.js, not the TypeScript source files. Use a single-link policy of at most 1 MB at exact mode 0600, without special mode bits. Its owner and parent directories must be you or root, with no group or other write access or symlinks. Existing daemon and module files can be readable at modes such as 0644, but must pass the same owner, parent, link and size checks.

See [server inspection](cli.md) to check running state. `install --apply` is still unsupported; the parser's explicit `--apply` below is a separate, source-file-only operation.

## Policy file

Use version 1. Each section is optional; include at least one. Unknown fields fail. These are example values, not measured server limits. Choose each server's limits in your private inventory.

```json
{
  "version": 1,
  "docker": { "maxLogBytes": 10485760, "maxLogFiles": 5 },
  "journald": {
    "systemMaxUseBytes": 268435456,
    "runtimeMaxUseBytes": 67108864
  },
  "opsLogs": [
    {
      "path": "/var/log/nightly-backup.log",
      "owner": "root",
      "group": "root",
      "maxBytes": 10485760,
      "rotate": 7
    }
  ],
  "pm2": {
    "maxLogBytes": 10485760,
    "retain": 7,
    "compress": true,
    "rotateModule": true,
    "workerIntervalSeconds": 30
  }
}
```

All byte values must be positive safe integers. Log counts are 1–1000. The PM2 check interval is 1–86400 seconds. Ops logs are exact absolute file paths, never globs. Duplicate paths and known Docker log paths are refused. Never list container logs, even with a custom Docker data directory. Use [server inspection](cli.md) to find uncapped running containers. It reports container names and limits, not the stack that owns them. Map each finding to its compose service before approving a recreate; this renderer does not repeat the running-state check.

For an existing Docker config, supply its base file:

```sh
gusnips-infra log-policy /etc/infrakit/log-policy.json --daemon-json /etc/docker/daemon.json
```

The rendered `daemon.json` keeps unrelated settings and replaces `log-driver` and `log-opts`. Without the base file, it is a template only. Review the diff and run `dockerd --validate --config-file <rendered-file>` before installation. The compose block defines `x-logging: &logging`; add `logging: *logging` to each service you choose. Neither form changes existing containers. A daemon restart or container recreate needs separate approval.

Install the rendered `[Journal]` text as a named drop-in, such as `/etc/systemd/journald.conf.d/60-infrakit.conf`, after approval. A journald restart is a separate step. Both persistent and runtime limits are explicit. Active files can exceed these limits; this tool does not vacuum existing logs. Check other drop-ins for overrides.

## Ops log rotation

Run the rendered logrotate rules as root. They use daily rotation, `maxsize`, gzip, one-cycle delayed compression and `create 0640`. `su root root` lets rotation rename a service-owned log in a root-owned directory; the policy's `owner` and `group` set only the new file's ownership. Explicit `nocopytruncate` prevents a global setting from truncating a writer's open file. `nodateext` uses numbered archives so repeated size-triggered rotations on the same day cannot collide. Only the listed files are owned by this policy. Missing or empty files are skipped. `maxsize` is checked only when the scheduler runs, not while a writer is writing.

Cron jobs that open their log on each run need no reopen command. A continuous writer must support reopening the log, or keep its own rotation. You can add an explicit command as an argument list:

```json
"reopenCommand": ["/usr/bin/systemctl", "reload", "example.service"]
```

That command runs after a future rotation with logrotate's user, usually root. It is trusted operator configuration, not user input. The renderer never runs it. Check the reviewed file with `logrotate --debug <rendered-file>` before installing it under `/etc/logrotate.d/`. Keep the previous file for rollback. Do not assign the same log to two rotators. PM2's module already rotates `pm2.log`; Caddy can rotate its own file logs.

## PM2 compression fix

PMX converts the saved string `true` into boolean `true`. The parser shipped in pm2-logrotate 3.0.0 accepts only the string, so it turns compression off. Setting the same value again does not fix it. The shared patch accepts both boolean and string true/false, including `rotateModule:false`, while keeping the fallback for other values.

Review the installed source without changing it:

```sh
gusnips-infra log-policy pm2-parser /home/ops/.pm2/modules/pm2-logrotate/node_modules/pm2-logrotate
```

After approval, run as the existing process owner:

```sh
gusnips-infra log-policy pm2-parser /home/ops/.pm2/modules/pm2-logrotate/node_modules/pm2-logrotate --apply
```

The command checks the package name, version and full `app.js` SHA-256. It accepts only the reviewed npm 3.0.0 source or this exact fix. Unknown source fails before any write. It replaces only `app.js`, atomically, with the same UID, GID and mode. An already-fixed source is unchanged. A directory lock prevents two patches from writing at once. No application files, logs or PM2 settings are changed. The reverse patch reconstructs the exact original, so no backup file is needed.

Restart only `pm2-logrotate` as its owner, with that daemon's existing `PM2_HOME`, in a separately approved step. The patch never starts a daemon or runs a PM2 command. The rendered `pm2-settings.sh` uses `pm2 set` with the explicit values in the policy; those commands change saved settings and can reload the module. Review the daemon, owner and settings before running them. The source patch does not change rotation size, schedule, retention or any saved setting. A module upgrade can replace the fix; recheck the source afterward, never bypass the guard.

Preview rollback by adding `--rollback`. Apply it with both flags:

```sh
gusnips-infra log-policy pm2-parser /home/ops/.pm2/modules/pm2-logrotate/node_modules/pm2-logrotate --rollback --apply
```

Rollback accepts only the exact patched or original source and preserves ownership and mode again. Restart only the module afterward if it had loaded the fix. Source state alone does not prove a runtime reload. Validate a newly rotated fixture or an approved future rotation with `gzip -t <new-file.gz>`. Do not truncate, rename or rewrite an active application log to test it. Existing uncompressed rotations stay untouched.

## Local proof

`tests/log-policy.test.ts` is an assert-based check, not part of `check` or CI. Run it on Linux or macOS with Bun 1.4.2, ShellCheck, `gzip` and `mkfifo` on `PATH`. Install ShellCheck with `brew install shellcheck` on macOS or `sudo apt-get install shellcheck` on Debian/Ubuntu. The check stops at startup with those install steps if ShellCheck cannot run. Docker Compose config validation runs only when its CLI is available; it does not contact a daemon. Native ops-log validation needs `logrotate` on Linux and is separate from this local check.

The check takes two source paths, which you must download to separate new directories and inspect before running:

```sh
bun tests/log-policy.test.ts /absolute/pm2-logrotate/package /absolute/pmx/package/lib/utils/autocast.js
```

Build the compiled CLI with `bun run build` before this check. Use npm pm2-logrotate 3.0.0 and PMX 1.6.7. The check verifies their source hashes before loading code. It copies them into private fixtures, proves the Autocast failure before the patch, tests boolean and string inputs after it and exercises the reviewed module's rotation function with real file streams and zlib. It checks gzip bytes and the decompressed payload. PM2 connections, schedulers and metrics are stubs; no real PM2 daemon is used. It also checks dry-run, repeat apply, rollback, owner/mode preservation, unknown sources, unsafe paths, exact 0600 policy permissions and config rendering. A FIFO (named pipe) is rejected before opening; a separate child process replaces a checked file with a FIFO to prove the shared file reader cannot block.
