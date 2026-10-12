import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import type { Manifest } from "./manifest.js";

export interface Check {
  id: string;
  label: string;
  finding: string;
  unknown: string;
  command?: string;
  note?: string;
}
export interface Result {
  check: Check;
  status: "pass" | "finding" | "unknown";
  evidence: string;
}
export const quote = (value: string | number): string =>
  `'${String(value).replaceAll("'", "'\\''")}'`;
const command = (probe: string, id: string, args: (string | number)[]) =>
  `${probe} ${[id, ...args].map(quote).join(" ")}`;
export function checks(manifest: Manifest): Check[] {
  const items: Check[] = [];
  const add = (
    label: string,
    probe: string | undefined,
    args: (string | number)[],
    finding: string,
    unknown: string,
    note?: string,
  ) => {
    const id = `c${items.length}`;
    items.push({
      id,
      label,
      finding,
      unknown,
      ...(probe ? { command: command(probe, id, args) } : {}),
      ...(note ? { note } : {}),
    });
  };
  add(
    "Server clock",
    "probe_clock",
    [],
    "The clock could not be verified. Check date and retry.",
    "The server time could not be read. Install GNU date or grant read access and retry.",
  );
  add(
    "Pending reboot",
    "probe_reboot",
    [],
    "The server requests a reboot. Schedule it with the server owner; inspect will not reboot it.",
    "The reboot marker could not be checked. Check access to /run and GNU find, then retry.",
  );
  for (const disk of manifest.disks)
    add(
      `Disk ${disk.path}`,
      "probe_disk",
      [disk.path, disk.maxUsedPercent, disk.maxInodePercent, disk.minFreeBytes],
      "Disk space or inodes reached a limit. Review large files and retention before removing anything.",
      "Disk usage could not be read. Check the path and df access, then retry.",
      "Evidence: used percent, inode percent, free bytes.",
    );
  add(
    "Journal disk size",
    "probe_journal",
    [manifest.maxJournalBytes],
    "The journal exceeds its size limit. Set a journal cap and plan cleanup with the server owner.",
    "Journal size could not be read. Check journalctl access and GNU awk, then retry.",
    "Evidence: bytes.",
  );
  if (manifest.sshd) {
    const sshd = manifest.sshd;
    const suffix = `addr=${sshd.clientAddress},host=${sshd.clientHost}`;
    add(
      "SSH login rules",
      "probe_sshd",
      [
        `user=${sshd.user},${suffix}`,
        `user=root,${suffix}`,
        sshd.permitRootLogin,
      ],
      "Password, keyboard login or root access exceeds the policy. Review sshd Match rules, keep a working key session and validate before applying a change.",
      "Effective SSH rules could not be read. Check SSH_CONNECTION in the remote SSH session and read access to sshd -T, then retry.",
      "The manifest's client and user contexts plus this SSH connection's local address and port were checked.",
    );
  } else
    add(
      "SSH login rules",
      undefined,
      [],
      "",
      "No SSH connection context was supplied. Add sshd.user, clientAddress and clientHost to check effective Match rules.",
    );
  add(
    "Unattended upgrades",
    "probe_upgrades",
    [],
    "Daily unattended updates are not enabled and running. Review unattended-upgrades, its timer and APT periodic settings before enabling them.",
    "Unattended update settings could not be read. Check systemctl and apt-config access, then retry.",
  );
  const inventory = manifest.inventory;
  if (!inventory) {
    add(
      "Expected inventory",
      undefined,
      [],
      "",
      "A bare host has no complete service or path inventory. Use a private manifest to check Docker, PM2, env files, backups, certificates, Redis and mail.",
    );
    return items;
  }
  if (inventory.docker) {
    const docker = inventory.docker;
    add(
      "Docker inventory",
      "probe_docker_inventory",
      [docker.containers.join(" ")],
      "The running containers do not match the manifest. Update the expected list or investigate stopped and extra containers, then retry.",
      "Running containers could not be listed. Check Docker access without starting or restarting the daemon, then retry.",
    );
    for (const container of docker.containers)
      add(
        `Docker logs ${container}`,
        "probe_docker",
        [container, docker.maxLogBytes, docker.maxLogFiles],
        "This container is stopped or lacks the required explicit log limits. Set per-container limits and schedule a recreate separately; daemon.json does not prove the running state.",
        "The running log driver or limits could not be verified. Check Docker read access and review this driver's limits.",
        "Evidence: maximum bytes per file, maximum file count.",
      );
    add(
      "Docker reclaimable space",
      "probe_docker_space",
      [docker.maxReclaimableBytes],
      "Docker reports reclaimable space above the limit. Review images, containers, volumes and build cache before approving a prune.",
      "Docker reclaimable space could not be read. Check Docker access and docker system df support, then retry.",
      "Evidence: bytes reported by Docker, not a promise of space freed.",
    );
  }
  for (const pm2 of inventory.pm2) {
    add(
      `PM2 unit ${pm2.unit}`,
      "probe_pm2",
      [pm2.unit, pm2.pidFile, pm2.minStopSeconds, pm2.after.join(" ")],
      "The existing PM2 daemon is outside its unit, an ordering rule is missing or the stop timeout is too short. Review a systemd drop-in and plan any restart separately.",
      "The existing PM2 daemon or unit could not be verified. Check its PID file, /proc access and systemctl; no PM2 command was run.",
      "Evidence: stop timeout in seconds.",
    );
    add(
      `PM2 rotated logs ${pm2.unit}`,
      "probe_rotation",
      [pm2.logsPath, pm2.maxRotationAgeSeconds],
      "Recent rotated logs are uncompressed, invalid gzip files or dated in the future. Check the clock and log rotation job, then verify a new rotated file.",
      "No valid recent rotation could be checked. Check the log path, access and rotation schedule, then inspect after a real rotation.",
      "Evidence: bad files and checked files, or checked gzip files.",
    );
  }
  for (const path of inventory.envFiles)
    add(
      `Env file ${path}`,
      "probe_env",
      [path],
      "The live file is not a regular 0600 file or old backup copies remain beside it. Fix its mode and move old copies to a private archive after review.",
      "The file mode or sibling backup names could not be read. Check the expected path and access, then retry.",
      "Evidence: old backup file count when present. Contents were not read.",
    );
  for (const backup of inventory.backups)
    add(
      `Backup ${backup.name}`,
      "probe_backup",
      [
        backup.statePath,
        backup.maxAgeSeconds,
        backup.name,
        backup.archivePath,
        backup.remoteRoot,
        backup.ownerUid,
      ],
      "The proof is stale, invalid or does not match its offsite receipt. Run the backup and fix its failed step before trusting it.",
      "The private backup proof or offsite markers could not be read. Check the state path, ownership and mode 0600, then run a verified backup.",
      "Evidence: proof age in seconds. This checks local read-back receipts, not current object availability.",
    );
  for (const cert of inventory.certificates)
    add(
      `${cert.kind === "caddy" ? "Caddy" : "PostgreSQL"} certificate ${cert.name}`,
      "probe_certificate",
      [cert.path, cert.container ?? "", cert.minValidDays],
      "This certificate is expired or near expiry. Check Caddy renewal and the PostgreSQL certificate copy job; plan a reload separately if needed.",
      "Certificate expiry could not be read. List the real certificate path in Caddy's shared storage or its PostgreSQL copy and check OpenSSL access.",
      "Evidence: whole days until expiry. A file check does not prove the certificate served to clients.",
    );
  for (const redis of inventory.redis)
    add(
      `Redis ${redis.name}`,
      "probe_redis",
      [redis.port, redis.authFile ?? "", redis.maxUsedPercent],
      "Redis has no memory cap or usage reached the limit. Review maxmemory and eviction policy with the server owner.",
      "Redis memory could not be read. Check the local port, redis-cli and the private password file; no password was put in argv.",
      "Evidence: used bytes, cap bytes and used percent when capped.",
    );
  if (inventory.mail) {
    const mail = inventory.mail;
    add(
      "Mail configuration fields",
      "probe_mail_config",
      [mail.configPath],
      "Required SMTP assignments are missing or empty. Complete the private alert configuration and send a labeled setup test.",
      "The private mail configuration could not be checked. Verify its path, owner and mode 0600, then retry.",
      "Only field presence was checked. Bash configuration was not executed and credentials were not tested.",
    );
    add(
      "Mail setup test",
      "probe_mail_test",
      [mail.testProofPath, mail.configPath, mail.maxAgeSeconds],
      "The recipient's test confirmation is stale, invalid or older than the config. Send a labeled setup test, confirm receipt and replace the private proof.",
      "Mail delivery has not been verified. Send a labeled setup test, confirm receipt and record the private recipient-confirmed proof.",
      "Evidence: confirmation age in seconds. A local operator record is not provider delivery history.",
    );
  }
  return items;
}
export async function scriptFor(items: Check[]): Promise<string> {
  const library = await readFile(
    new URL("../jobs/lib.sh", import.meta.url),
    "utf8",
  );
  const helpers = await readFile(
    new URL("../jobs/inspect.sh", import.meta.url),
    "utf8",
  );
  return `set +x +v\nif (( BASH_VERSINFO[0] < 4 )); then exit 70; fi\n${library}\n${helpers}\n${items.flatMap((item) => (item.command ? [item.command] : [])).join("\n")}\n`;
}
export function parseResults(items: Check[], stdout: string): Result[] {
  const received = new Map<
    string,
    { status: Result["status"]; evidence: string }
  >();
  const bad = new Set<string>();
  for (const line of stdout.replace(/\n$/, "").split("\n")) {
    const match = /^(pass|finding|unknown)\t(c\d+)\t(-?\d+(?:,\d+)*)?$/.exec(
      line,
    );
    if (!match) continue; // Never print untrusted output, including provider errors or secrets.
    const status = match[1];
    const id = match[2];
    if (
      !id ||
      (status !== "pass" && status !== "finding" && status !== "unknown")
    )
      continue;
    if (received.has(id)) bad.add(id);
    received.set(id, { status, evidence: match[3] ?? "" });
  }
  return items.map((check) => ({
    check,
    status: "unknown",
    evidence: "",
    ...(check.command && !bad.has(check.id)
      ? received.get(check.id)
      : undefined),
  }));
}
export async function sshRead(
  manifest: Manifest,
  script: string,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "ssh",
      [
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "PermitLocalCommand=no",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "LogLevel=ERROR",
        "-p",
        String(manifest.port),
        "--",
        manifest.host,
        manifest.sudo
          ? 'sudo -n env SSH_CONNECTION="${SSH_CONNECTION-}" bash --noprofile --norc -s -- infrakit-inspect-sudo'
          : "bash --noprofile --norc -s",
      ],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    let output = "";
    let failed = false;
    const fail = (message: string) => {
      failed = true;
      child.kill("SIGTERM");
      reject(new Error(message));
    };
    const timer = setTimeout(
      () =>
        fail(
          "SSH inspection timed out after 120 seconds. Check the connection or blocked reads and retry; no files were changed.",
        ),
      120_000,
    );
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (data: string) => {
      output += data;
      if (Buffer.byteLength(output, "utf8") > 1024 * 1024)
        fail(
          "SSH returned too much output. Check remote shell startup messages and retry; private output was not printed.",
        );
    });
    child.stderr.resume();
    child.stdin.on("error", () => {
      /* close reports connection and remote-command failures without raw diagnostics. */
    });
    child.on("error", () => {
      clearTimeout(timer);
      fail("SSH could not start. Install the OpenSSH client and retry.");
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (failed) return;
      if (code !== 0)
        reject(
          new Error(
            "SSH inspection failed. Check the host key, key login, read permissions, Bash 4 or newer and noninteractive sudo access if requested, then retry; no password was requested and no remote error text was printed.",
          ),
        );
      else resolve(output);
    });
    child.stdin.end(script);
  });
}
export function printResults(
  results: Result[],
  write: (line: string) => void,
): number {
  const counts = { pass: 0, finding: 0, unknown: 0 };
  for (const result of results) {
    counts[result.status]++;
    if (result.status === "pass") continue;
    write(
      `${result.status === "finding" ? "Finding" : "Unverified"}: ${result.check.label}. ${result.status === "finding" ? result.check.finding : result.check.unknown}${result.evidence ? ` Evidence: ${result.evidence}. ${result.check.note ?? ""}` : ""}`.trim(),
    );
  }
  write(
    `${counts.pass} checks passed, ${counts.finding} findings, ${counts.unknown} unverified. No server files were changed.`,
  );
  return counts.finding + counts.unknown > 0 ? 1 : 0;
}
