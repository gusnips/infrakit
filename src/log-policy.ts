import { absolutePath, readSafeFile } from "./files.js";
import { quote } from "./inspect.js";
import { patchPm2Logrotate } from "./pm2-logrotate.js";

const invalid = () =>
  new Error(
    "The log policy has an invalid or unknown field. Follow the version 1 schema in docs/log-policies.md and retry; no configuration was installed.",
  );
function record(value: unknown, keys?: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw invalid();
  const result: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (keys && !keys.includes(key)) throw invalid();
    Object.defineProperty(result, key, { value: item, enumerable: true });
  }
  return result;
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1 ||
    value > maximum
  )
    throw invalid();
  return value;
}
function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw invalid();
  return value;
}
function text(value: unknown, pattern: RegExp): string {
  if (
    typeof value !== "string" ||
    value.length > 4096 ||
    /[\p{Cc}\p{Cf}]/u.test(value) ||
    !pattern.test(value)
  )
    throw invalid();
  return value;
}

export function renderLogPolicy(value: unknown, daemonBase: unknown = {}) {
  const input = record(value, [
    "version",
    "docker",
    "journald",
    "opsLogs",
    "pm2",
  ]);
  if (input.version !== 1) throw invalid();
  const configs: Record<string, string> = {};
  const requiredReloads: string[] = [];
  const warnings: string[] = [];
  if (input.docker !== undefined) {
    const docker = record(input.docker, ["maxLogBytes", "maxLogFiles"]);
    const options = {
      "max-size": String(integer(docker.maxLogBytes)),
      "max-file": String(integer(docker.maxLogFiles, 1000)),
    };
    const base = record(daemonBase);
    configs["daemon.json"] =
      `${JSON.stringify({ ...base, "log-driver": "json-file", "log-opts": options }, null, 2)}\n`;
    configs["compose-logging.yaml"] =
      `x-logging: &logging\n  driver: json-file\n  options:\n    max-size: "${options["max-size"]}"\n    max-file: "${options["max-file"]}"\n`;
    requiredReloads.push(
      "Docker: no restart or recreate was performed. A daemon default change needs an approved dockerd restart and affects only new containers. Apply the compose logging anchor to each service, then approve each required container recreate separately.",
    );
    warnings.push(
      "daemon.json replaces only log-driver and log-opts in the supplied base. Without --daemon-json it is a template, not a safe replacement for an existing daemon.json. Preserve unrelated settings and validate it with dockerd --validate before installation.",
    );
  }
  if (input.journald !== undefined) {
    const journal = record(input.journald, [
      "systemMaxUseBytes",
      "runtimeMaxUseBytes",
    ]);
    configs["journald.conf"] =
      `[Journal]\nSystemMaxUse=${integer(journal.systemMaxUseBytes)}\nRuntimeMaxUse=${integer(journal.runtimeMaxUseBytes)}\n`;
    requiredReloads.push(
      "journald: install as a named drop-in only after approval, then approve a systemd-journald restart. This command does not restart it or vacuum logs.",
    );
    warnings.push(
      "journald counts active and archived files but removes only archived files to meet a limit. Active files can keep usage above the cap. Other drop-ins can override these settings; read the effective configuration after installation.",
    );
  }
  if (input.opsLogs !== undefined) {
    if (
      !Array.isArray(input.opsLogs) ||
      input.opsLogs.length === 0 ||
      input.opsLogs.length > 100
    )
      throw invalid();
    const seen = new Set<string>();
    configs["logrotate.conf"] = input.opsLogs
      .map((value: unknown) => {
        const item = record(value, [
          "path",
          "owner",
          "group",
          "maxBytes",
          "rotate",
          "reopenCommand",
        ]);
        const path = absolutePath(text(item.path, /^\/[A-Za-z0-9_ .@+/-]+$/));
        if (
          seen.has(path) ||
          path.startsWith("/var/lib/docker/") ||
          /(?:^|\/)containers\/[a-f0-9]{64}\//.test(path) ||
          path.endsWith("-json.log")
        )
          throw new Error(
            "An ops log is duplicated or points to a Docker log. List each ops log once; use Docker log caps for container logs, never logrotate.",
          );
        seen.add(path);
        const owner = text(item.owner, /^[a-z_][a-z0-9_-]{0,31}$/);
        const group = text(item.group, /^[a-z_][a-z0-9_-]{0,31}$/);
        let reopen = "";
        if (item.reopenCommand !== undefined) {
          if (
            !Array.isArray(item.reopenCommand) ||
            item.reopenCommand.length === 0 ||
            item.reopenCommand.length > 32
          )
            throw invalid();
          const command = item.reopenCommand.map((arg: unknown) =>
            text(arg, /^.+$/),
          );
          absolutePath(command[0]);
          reopen = `    postrotate\n        ${command.map(quote).join(" ")}\n    endscript\n`;
        }
        return `"${path}" {\n    daily\n    maxsize ${integer(item.maxBytes)}\n    rotate ${integer(item.rotate, 1000)}\n    missingok\n    notifempty\n    nocopytruncate\n    nodateext\n    compress\n    delaycompress\n    su root root\n    create 0640 ${owner} ${group}\n${reopen}}\n`;
      })
      .join("\n");
    warnings.push(
      "Only explicitly listed ops logs are rotated. There is no copytruncate. Continuous writers need their own rotation or an explicit reopenCommand; do not let two rotators own the same file. Reopen commands run with logrotate's user, usually root, and must be trusted.",
    );
    requiredReloads.push(
      "logrotate: no service reload is needed to read the config. Run logrotate --debug on the reviewed file before installation. maxsize is checked only when logrotate runs; it is not a hard cap. An optional reopenCommand runs only on a later rotation, never during rendering.",
    );
  }
  if (input.pm2 !== undefined) {
    const pm2 = record(input.pm2, [
      "maxLogBytes",
      "retain",
      "compress",
      "rotateModule",
      "workerIntervalSeconds",
    ]);
    const settings = {
      max_size: String(integer(pm2.maxLogBytes)),
      retain: String(integer(pm2.retain, 1000)),
      compress: String(boolean(pm2.compress)),
      rotateModule: String(boolean(pm2.rotateModule)),
      workerInterval: String(integer(pm2.workerIntervalSeconds, 86400)),
    };
    configs["pm2-settings.sh"] =
      `#!/usr/bin/env bash\nset -euo pipefail\n# Run as the existing PM2 process owner with its existing PM2_HOME, after approval.\n${Object.entries(
        settings,
      )
        .map(([key, value]) => `pm2 set pm2-logrotate:${key} ${quote(value)}`)
        .join("\n")}\n`;
    requiredReloads.push(
      "PM2 settings: rendering made no PM2 calls. Applying the script changes the module settings and can reload it. Review the process owner and PM2_HOME first; apply the guarded parser fix before these settings. Do not start a new daemon under another user or restart apps.",
    );
    warnings.push(
      "max_size is checked at workerInterval, not a hard cap. The parser fix also makes rotateModule:false work; no other setting is changed by the source patch. Verify a newly rotated .gz file with gzip -t, not just PM2's saved settings.",
    );
  }
  if (Object.keys(configs).length === 0) throw invalid();
  return { configs, requiredReloads, warnings };
}

export async function runLogPolicy(
  args: string[],
  write: (line: string) => void,
): Promise<void> {
  if (args.length === 0 || (args.length === 1 && args[0] === "--help")) {
    write(
      "Usage: gusnips-infra log-policy <absolute-policy-path> [--daemon-json <absolute-daemon.json>]",
    );
    write(
      "Prints configs, warnings and required reloads. No files, containers or services change. See docs/log-policies.md for the private JSON schema.",
    );
    write(
      "Usage: gusnips-infra log-policy pm2-parser <absolute-module-directory> [--rollback] [--apply]",
    );
    write(
      "Checks pm2-logrotate 3.0.0 and its full source. Only this command's explicit --apply replaces app.js; no PM2 command runs.",
    );
    return;
  }
  const argumentsError = () =>
    new Error(
      "The arguments do not match this log-policy command. Run gusnips-infra log-policy --help and retry; no configuration was installed.",
    );
  try {
    if (args[0] === "pm2-parser") {
      const [, directory, ...flags] = args;
      if (
        !directory ||
        flags.some((flag) => flag !== "--apply" && flag !== "--rollback") ||
        new Set(flags).size !== flags.length
      )
        throw argumentsError();
      write(
        JSON.stringify(
          await patchPm2Logrotate(
            directory,
            flags.includes("--apply"),
            flags.includes("--rollback"),
          ),
          null,
          2,
        ),
      );
      return;
    }
    const [policy, flag, daemon] = args;
    if (
      !policy ||
      (args.length !== 1 &&
        (args.length !== 3 || flag !== "--daemon-json" || !daemon))
    )
      throw argumentsError();
    const value: unknown = JSON.parse(
      (await readSafeFile(policy, { privateFile: true })).text,
    );
    const base: unknown = daemon
      ? JSON.parse((await readSafeFile(daemon)).text)
      : {};
    write(JSON.stringify(renderLogPolicy(value, base), null, 2));
  } catch (error: unknown) {
    // Never print parser excerpts, file contents or operating-system diagnostics.
    throw new Error(
      error instanceof Error &&
        !("code" in error) &&
        !(error instanceof SyntaxError)
        ? error.message
        : args[0] === "pm2-parser"
          ? "The source operation could not finish. Check file access and the current app.js source state before retrying; no PM2 command was run."
          : "A log-policy file could not be read or parsed. Check its JSON, owner, permissions and path, then retry; no configuration was installed.",
    );
  }
}
