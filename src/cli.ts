#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import {
  checks,
  parseResults,
  printResults,
  scriptFor,
  sshRead,
} from "./inspect.js";
import { loadManifest, parseManifest } from "./manifest.js";
import { readSafeFile } from "./files.js";
import { runLogPolicy } from "./log-policy.js";

const write = (line: string) => process.stdout.write(`${line}\n`);
async function run(args: string[]): Promise<number> {
  if (
    args.length === 0 ||
    (args.length === 1 && (args[0] === "--help" || args[0] === "help"))
  ) {
    write("Usage: gusnips-infra inspect <host-or-absolute-manifest-path>");
    write("Example: gusnips-infra inspect ops@server.example.net");
    write(
      "Reads server state over SSH. Findings or required unverified checks exit 1.",
    );
    write(
      "A bare host checks the host baseline only. Use a private 0600 JSON manifest for services and paths.",
    );
    write("Usage: gusnips-infra install <absolute-manifest-path>");
    write(
      "Follow docs/cli.md for the private manifest schema. Install --apply is unsupported; no SSH connection is opened.",
    );
    await runLogPolicy(["--help"], write);
    return 0;
  }
  if (args[0] === "log-policy") {
    await runLogPolicy(args.slice(1), write);
    return 0;
  }
  const [action, target, ...flags] = args;
  if (action !== "inspect" && action !== "install")
    throw new Error(
      "Unknown command. Run gusnips-infra --help to see inspect, install and log-policy.",
    );
  if (
    !target ||
    flags.some((flag) => flag !== "--apply") ||
    flags.length > 1 ||
    (action === "inspect" && flags.length > 0)
  )
    throw new Error(
      "The arguments do not match this command. Run gusnips-infra --help; credentials belong in private files, not flags.",
    );
  write(
    action === "inspect"
      ? "Inspecting server. No files will change."
      : "Preparing installation plan. No files will change.",
  );
  if (action === "install" && flags.includes("--apply"))
    throw new Error(
      "Apply is not supported in this release. Run install without --apply to review the plan; no SSH connection was opened and nothing was installed.",
    );
  if (action === "install") {
    if (!isAbsolute(target))
      throw new Error(
        "Install needs an absolute path to a private manifest. Create a 0600 JSON file and retry.",
      );
    const manifest = await loadManifest(target);
    if (!manifest.install)
      throw new Error(
        "The manifest has no install plan. Add install.packageVersion, prefix and jobs, then retry.",
      );
    const packageInfo: unknown = JSON.parse(
      await readFile(new URL("../package.json", import.meta.url), "utf8"),
    );
    if (
      !packageInfo ||
      typeof packageInfo !== "object" ||
      !("version" in packageInfo) ||
      packageInfo.version !== manifest.install.packageVersion
    )
      throw new Error(
        "The plan version does not match this installed package. Use the exact installed version in install.packageVersion and retry.",
      );
    for (const job of manifest.install.jobs) {
      try {
        await readSafeFile(job.configPath, {
          privateFile: true,
          metadataOnly: true,
        });
      } catch {
        throw new Error(
          "A job config could not be checked safely. Use owner-controlled 0600 files without symlinks or writable parents and retry; no config was executed.",
        );
      }
    }
    write(
      `Plan for ${manifest.host}, package ${manifest.install.packageVersion}. No SSH connection was opened.`,
    );
    write(
      `Install the packaged job files in ${manifest.install.prefix}/${manifest.install.packageVersion}/jobs without upgrading system packages.`,
    );
    for (const job of manifest.install.jobs) {
      write(
        `Job ${job.name}: copy the private local config to /etc/infrakit/${job.name}.conf at mode 0600.`,
      );
      write(
        `Add /etc/cron.d/infrakit-${job.name} for ${job.user}, schedule ${job.schedule}. Keep existing jobs.`,
      );
    }
    write(
      "Config modes were checked; Bash syntax and job settings were not validated. Validate and test each job before scheduling it.",
    );
    write(
      "Apply is unsupported. This plan does not restart services, recreate containers, change PM2 or DNS, delete old jobs or publish packages.",
    );
    return 0;
  }
  const manifest = isAbsolute(target)
    ? await loadManifest(target)
    : parseManifest({ version: 1, host: target });
  write(
    "Reads only the expected inventory. Backup checks use local offsite receipts; certificate checks read files. Mail checks do not query delivery history.",
  );
  if (manifest.sudo)
    write(
      "Inspection uses noninteractive sudo for private reads. No password will be requested and no server files will change.",
    );
  const items = checks(manifest);
  const stdout = await sshRead(manifest, await scriptFor(items));
  return printResults(parseResults(items, stdout), write);
}
run(process.argv.slice(2))
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error: unknown) => {
    // Only authored errors reach the terminal. Never echo JSON, remote diagnostics or credentials.
    const message =
      error instanceof Error &&
      !("code" in error) &&
      !(error instanceof SyntaxError)
        ? error.message
        : "The command could not finish. Check file access and the installed package files, then retry.";
    process.stderr.write(`Error: ${message}\n`);
    process.exitCode = 1;
  });
