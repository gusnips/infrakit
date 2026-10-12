import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { lstat, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const run = (command: string, args: string[], cwd = root) =>
  execFileSync(command, args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
  });
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const compiled = [
  "cli.js",
  "files.js",
  "inspect.js",
  "log-policy.js",
  "manifest.js",
  "pm2-logrotate.js",
];
const jobs = ["backup", "alert", "heartbeat", "diskwatch", "cert-sync"];
const required = [
  "package.json",
  "README.md",
  "PRODUCT.md",
  "LICENSE",
  "docs/cli.md",
  "docs/log-policies.md",
  "docs/ops-jobs.md",
  "jobs/lib.sh",
  "jobs/inspect.sh",
  ...jobs.map((name) => `jobs/${name}.sh`),
  ...compiled.map((name) => `dist/${name}`),
];
const credentials =
  /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|AGE-SECRET-KEY-1[A-Z0-9]+|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\b(?:npm_[A-Za-z0-9]{36,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b|https?:\/\/[^\s/"']+:[^\s/"']+@|\/Users\/[^\s/"']+\/|\.claude\/worktrees\//;
const work = await mkdtemp(join(homedir(), ".infrakit-pack-"));
try {
  // release:check rebuilds first. Check the exact emitted set before inspecting the actual archive.
  assert.deepEqual(
    (await readdir(join(root, "dist"))).sort(),
    [...compiled].sort(),
    "Dist has missing or stale files. Run bun run build and review its output.",
  );
  assert.deepEqual(
    (await readdir(join(root, "src"))).sort(),
    compiled.map((name) => name.replace(/\.js$/, ".ts")).sort(),
    "The compiled-file list does not match src. Update the release gate for the reviewed modules.",
  );
  const source: unknown = JSON.parse(
    await readFile(join(root, "package.json"), "utf8"),
  );
  assert(
    record(source),
    "Package metadata is not an object. Fix package.json.",
  );
  assert.equal(
    source.name,
    "@gusnips/infra",
    "Fix the package name before packing.",
  );
  assert(
    typeof source.version === "string" &&
      /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(source.version),
    "Use a three-part package version without leading zeros.",
  );

  // Packing is not publishing. All pack output and extracted files belong to this check.
  run("bun", ["pm", "pack", "--destination", work]);
  const tarball = join(work, `gusnips-infra-${source.version}.tgz`);
  const entries = run("tar", ["-tzf", tarball]).split("\n").filter(Boolean);
  assert.equal(
    new Set(entries).size,
    entries.length,
    "The archive has duplicate paths. Review the pack output.",
  );
  assert.deepEqual(
    entries.filter((file) => !file.endsWith("/")).sort(),
    required.map((file) => `package/${file}`).sort(),
    "The tarball has missing or unexpected files. Exclude private work, configs, tests, source and stale dist from package.json files.",
  );
  assert(
    entries
      .filter((file) => file.endsWith("/"))
      .every((file) =>
        [
          "package/",
          "package/dist/",
          "package/docs/",
          "package/jobs/",
        ].includes(file),
      ),
    "The tarball has an unexpected directory. Review package.json files.",
  );
  assert(
    run("tar", ["-tvzf", tarball])
      .split("\n")
      .filter(Boolean)
      .every((line) => /^[d-]/.test(line)),
    "The tarball contains a link or special file. Package regular files only.",
  );
  run("tar", ["-xzf", tarball, "-C", work]);
  const packageRoot = join(work, "package");
  const packed: unknown = JSON.parse(
    await readFile(join(packageRoot, "package.json"), "utf8"),
  );
  assert(
    record(packed),
    "Packed metadata is invalid. Fix package.json and pack again.",
  );
  assert.deepEqual(
    packed,
    source,
    "Packed metadata differs from package.json. Pack from this worktree again.",
  );
  assert.equal(
    packed.private,
    undefined,
    "Remove private metadata only when the package is ready for public distribution.",
  );
  assert.equal(
    packed.type,
    "module",
    "The compiled CLI needs ESM package metadata.",
  );
  assert.deepEqual(
    packed.bin,
    { "gusnips-infra": "./dist/cli.js" },
    "The bin must point to the packaged CLI.",
  );
  assert.deepEqual(
    packed.exports,
    { "./jobs/*": "./jobs/*" },
    "Job exports must point to the packaged shell assets.",
  );
  for (const key of ["main", "types", "module"])
    assert.equal(
      packed[key],
      undefined,
      `Remove the unused ${key} entry before packing.`,
    );
  for (const key of [
    "dependencies",
    "optionalDependencies",
    "peerDependencies",
    "bundledDependencies",
    "bundleDependencies",
  ])
    assert(
      !packed[key] ||
        (record(packed[key]) && Object.keys(packed[key]).length === 0) ||
        (Array.isArray(packed[key]) && packed[key].length === 0),
      "The package must have no JavaScript runtime dependencies.",
    );
  for (const relative of required) {
    const file = join(packageRoot, relative);
    const info = await lstat(file);
    assert(
      info.isFile() && info.nlink === 1,
      `${relative} is not a regular single-link file. Fix the package asset.`,
    );
    const text = await readFile(file, "utf8");
    assert(
      !credentials.test(text),
      `${relative} contains a credential signature or local workspace path. Remove it before packing.`,
    );
    if (relative.endsWith(".sh")) {
      assert(
        text.startsWith("#!/usr/bin/env bash\n"),
        `${relative} has no Bash shebang. Fix the packaged file.`,
      );
      run("bash", ["-n", file]);
    }
  }
  const cli = join(packageRoot, "dist/cli.js");
  assert.equal(
    (await lstat(cli)).mode & 0o111,
    0o111,
    "The CLI is not executable. Run bun run build.",
  );
  assert(
    (await readFile(cli, "utf8")).startsWith("#!/usr/bin/env node\n"),
    "The CLI needs a Node shebang. Fix src/cli.ts and rebuild.",
  );
  const help = run("node", [cli, "--help"]);
  for (const command of ["inspect", "install", "log-policy"])
    assert(
      help.includes(`gusnips-infra ${command}`),
      `The packaged help is missing ${command}. Fix the CLI help.`,
    );
  assert(
    run("node", [cli, "log-policy", "--help"]).includes("pm2-parser"),
    "The packaged CLI is missing the guarded PM2 source command.",
  );
  for (const name of jobs) {
    const file = join(packageRoot, `jobs/${name}.sh`);
    assert.equal(
      (await lstat(file)).mode & 0o111,
      0o111,
      `${name}.sh is not executable. Set its execute bits before packing.`,
    );
    assert(
      (await readFile(file, "utf8")).includes('source "$INFRA_JOBS/lib.sh"'),
      `${name}.sh does not use the packaged foundation library.`,
    );
    assert(
      run("bash", [file, "--help"]).includes("Usage:"),
      `${name}.sh has no usable packaged help. Fix the job help.`,
    );
  }
  console.log(
    `Packed ${source.name}@${source.version}: six compiled CLI modules, five executable jobs, two shell helpers and public docs. Node and job help passed; no extra files or credential signatures found. Nothing was published.`,
  );
} finally {
  await rm(work, { recursive: true, force: true });
}
