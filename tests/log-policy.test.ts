import assert from "node:assert/strict";
import * as fs from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import * as nodePath from "node:path";
import { fileURLToPath } from "node:url";
import { createContext, runInContext, runInNewContext } from "node:vm";
import * as zlib from "node:zlib";
import { renderLogPolicy } from "../src/log-policy.js";
import { quote } from "../src/inspect.js";
import {
  logrotateSourceHashes,
  patchPm2Logrotate,
} from "../src/pm2-logrotate.js";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const shellcheck = spawnSync("shellcheck", ["--version"], {
  encoding: "utf8",
  timeout: 10000,
});
assert.equal(
  shellcheck.status,
  0,
  "ShellCheck could not run. Install it with brew install shellcheck (macOS) or sudo apt-get install shellcheck (Debian/Ubuntu), make sure shellcheck is on PATH, then retry.",
);
const [moduleDirectory, autocastPath] = process.argv.slice(2);
assert(
  moduleDirectory && autocastPath,
  "Pass reviewed pm2-logrotate 3.0.0 and PMX 1.6.7 source paths. See docs/log-policies.md.",
);
const originalSource = fs.readFileSync(join(moduleDirectory, "app.js"), "utf8");
const autocastSource = fs.readFileSync(autocastPath, "utf8");
const digest = (text: string) =>
  createHash("sha256").update(text).digest("hex");
assert.equal(
  digest(originalSource),
  logrotateSourceHashes.original,
  "Unknown module source must never run in this check.",
);
assert.equal(
  digest(autocastSource),
  "4989fdc18ed6e74e2e01930a6ce4dc16119a0aeb06cc7460786378efbfd0ac5f",
  "Unknown Autocast source must never run in this check.",
);
const exported: { exports: unknown } = { exports: undefined };
runInNewContext(autocastSource, { module: exported }, { timeout: 1000 });
const callable = (
  value: unknown,
): value is (input: unknown, fallback?: boolean) => unknown =>
  typeof value === "function";
assert(callable(exported.exports));
const autocast = exported.exports;
const converted: unknown = autocast({ compress: "true" });
assert(converted && typeof converted === "object" && "compress" in converted);
assert.equal(
  converted.compress,
  true,
  "PMX must turn the string into a native boolean for the failure control.",
);

fs.mkdirSync(join(root, ".scratch"), { recursive: true });
const work = fs.mkdtempSync(join(root, ".scratch/log-policy-check-"));
fs.chmodSync(work, 0o700);
const privateFile = (path: string, text: string) =>
  fs.writeFileSync(path, text, { mode: 0o600 });
let count = 0;
const fixture = () => {
  const directory = join(work, `module-${++count}`);
  fs.mkdirSync(directory, { mode: 0o700 });
  privateFile(
    join(directory, "package.json"),
    JSON.stringify({ name: "pm2-logrotate", version: "3.0.0" }),
  );
  fs.writeFileSync(join(directory, "app.js"), originalSource, { mode: 0o640 });
  return directory;
};
const info = (directory: string) => {
  const file = join(directory, "app.js");
  const value = fs.statSync(file);
  return {
    text: fs.readFileSync(file, "utf8"),
    uid: value.uid,
    gid: value.gid,
    mode: value.mode & 0o7777,
    ino: value.ino,
    mtimeMs: value.mtimeMs,
  };
};
const tools = join(work, "tools");
fs.mkdirSync(tools, { mode: 0o700 });
const called = join(work, "forbidden-call");
for (const name of ["pm2", "ssh"]) {
  fs.writeFileSync(
    join(tools, name),
    '#!/usr/bin/env bash\nprintf "%s\\n" "$0" >"$FORBIDDEN_CALL"\nexit 9\n',
    { mode: 0o700 },
  );
}
const cli = (...args: string[]) =>
  spawnSync("node", [join(root, "dist/cli.js"), "log-policy", ...args], {
    cwd: root,
    env: {
      ...process.env,
      PATH: `${tools}:${process.env.PATH ?? ""}`,
      FORBIDDEN_CALL: called,
    },
    encoding: "utf8",
    timeout: 10000,
  });

// Execute only the two reviewed source files. All third-party imports, timers and PM2 calls are stubs.
// Real filesystem streams and zlib are used only in this private fixture directory.
async function rotate(source: string, compress: unknown, expectGzip: boolean) {
  const directory = join(work, `rotation-${++count}`);
  fs.mkdirSync(directory, { mode: 0o700 });
  fs.mkdirSync(join(directory, "logs"), { mode: 0o700 });
  const path = join(directory, "fixture.log");
  const payload = Buffer.from("fixture line\n".repeat(2048));
  fs.writeFileSync(path, payload, { mode: 0o600 });
  let resolveRotation: (() => void) | undefined;
  let rejectRotation: ((error: unknown) => void) | undefined;
  const complete = new Promise<void>((resolve, reject) => {
    resolveRotation = resolve;
    rejectRotation = reject;
  });
  const conf: unknown = autocast({
    compress,
    rotateModule: "false",
    max_size: "1K",
  });
  const realFiles = {
    ...fs,
    truncate: (
      file: string,
      callback: (error: NodeJS.ErrnoException | null) => void,
    ) => {
      assert.equal(file, path, "The fixture must never truncate another file.");
      fs.truncate(file, (error) => {
        callback(error);
        if (error) rejectRotation?.(error);
        else resolveRotation?.();
      });
    },
  };
  const context = createContext({
    require: (name: string): unknown => {
      if (name === "graceful-fs") return realFiles;
      if (name === "path") return nodePath;
      if (name === "zlib") return zlib;
      if (name === "pmx")
        return {
          initModule: () => conf,
          probe: () => ({ metric: () => ({ set: () => {} }) }),
          notify: (error: unknown) => rejectRotation?.(error),
          action: () => {},
        };
      if (name === "pm2") return { connect: () => {} };
      if (name === "moment-timezone")
        return () => ({ format: () => "2000-01-01_00-00-00" });
      if (name === "node-schedule")
        return {
          scheduleJob: () =>
            assert.fail("The check must not schedule a real PM2 rotation."),
        };
      throw new Error(`An unreviewed dependency was requested: ${name}`);
    },
    process: { env: { PM2_HOME: directory } },
    console: {
      log: () => {},
      error: (error: unknown) => rejectRotation?.(error),
    },
    setInterval: () => 0,
  });
  runInContext(source, context, { timeout: 1000 });
  assert.equal(runInContext("COMPRESSION", context), expectGzip);
  assert.equal(
    runInContext("ROTATE_MODULE", context),
    digest(source) === logrotateSourceHashes.original,
    "The same parser fix must cover rotateModule:false.",
  );
  const parser: unknown = runInContext("parseBool", context);
  assert(callable(parser));
  for (const input of [true, false, "true", "false"]) {
    const expected = input === true || input === "true";
    assert.equal(
      parser(input),
      digest(source) === logrotateSourceHashes.original && input === true
        ? false
        : expected,
    );
  }
  assert.equal(
    parser(false, true),
    digest(source) === logrotateSourceHashes.original,
    "A native false must beat a true fallback after the fix.",
  );
  for (const input of [undefined, null, "TRUE", 1, "yes"]) {
    assert.equal(parser(input), false);
    assert.equal(parser(input, true), true);
  }
  runInContext(`proceed_file(${JSON.stringify(path)}, true)`, context, {
    timeout: 1000,
  });
  const timer = setTimeout(
    () =>
      rejectRotation?.(
        new Error("The fixture rotation did not finish within 10 seconds."),
      ),
    10000,
  );
  try {
    await complete;
  } finally {
    clearTimeout(timer);
  }
  const rotated = join(
    directory,
    `fixture__2000-01-01_00-00-00.log${expectGzip ? ".gz" : ""}`,
  );
  const bytes = fs.readFileSync(rotated);
  assert.equal(
    fs.statSync(path).size,
    0,
    "The reviewed rotation path did not finish its private fixture.",
  );
  if (expectGzip) {
    assert.deepEqual(
      [...bytes.subarray(0, 3)],
      [0x1f, 0x8b, 0x08],
      "A .gz suffix alone is not compression proof.",
    );
    assert.deepEqual(zlib.gunzipSync(bytes), payload);
    execFileSync("gzip", ["-t", rotated]);
  } else assert.deepEqual(bytes, payload);
}

try {
  const directory = fixture();
  const before = info(directory);
  const plan = await patchPm2Logrotate(directory);
  assert.equal(plan.state, "original");
  assert.equal(plan.changed, false);
  assert.deepEqual(info(directory), before);
  assert.deepEqual(fs.readdirSync(directory).sort(), [
    "app.js",
    "package.json",
  ]);
  await rotate(originalSource, "true", false);
  const applied = await patchPm2Logrotate(directory, true);
  assert.equal(applied.changed, true);
  assert.equal(applied.state, "fixed");
  const after = info(directory);
  assert.deepEqual(
    [after.uid, after.gid, after.mode],
    [before.uid, before.gid, before.mode],
  );
  assert.equal(digest(after.text), logrotateSourceHashes.fixed);
  await rotate(after.text, "true", true);
  await rotate(after.text, false, false);
  const unchanged = await patchPm2Logrotate(directory, true);
  assert.equal(unchanged.changed, false);
  assert.deepEqual(
    info(directory),
    after,
    "A repeat apply must not rewrite the source.",
  );
  const rollbackPlan = await patchPm2Logrotate(directory, false, true);
  assert.equal(rollbackPlan.state, "fixed");
  assert.deepEqual(info(directory), after);
  const rollback = await patchPm2Logrotate(directory, true, true);
  assert.equal(rollback.state, "original");
  assert.equal(rollback.changed, true);
  const restored = info(directory);
  assert.equal(restored.text, before.text);
  assert.deepEqual(
    [restored.uid, restored.gid, restored.mode],
    [before.uid, before.gid, before.mode],
  );
  assert.equal((await patchPm2Logrotate(directory, true, true)).changed, false);

  for (const kind of [
    "version",
    "name",
    "changed-source",
    "symlink",
    "hardlink",
    "writable-file",
    "writable-parent",
    "lock",
  ]) {
    const module = fixture();
    const app = join(module, "app.js");
    if (kind === "version")
      privateFile(
        join(module, "package.json"),
        '{"name":"pm2-logrotate","version":"4.0.0"}',
      );
    if (kind === "name")
      privateFile(
        join(module, "package.json"),
        '{"name":"other-module","version":"3.0.0"}',
      );
    if (kind === "changed-source")
      fs.appendFileSync(app, "\n// unrelated change\n");
    if (kind === "symlink") {
      fs.renameSync(app, join(module, "real.js"));
      fs.symlinkSync(join(module, "real.js"), app);
    }
    if (kind === "hardlink") fs.linkSync(app, join(module, "another.js"));
    if (kind === "writable-file") fs.chmodSync(app, 0o666);
    if (kind === "writable-parent") fs.chmodSync(module, 0o777);
    if (kind === "lock")
      fs.mkdirSync(join(module, ".infrakit-logrotate.lock"), { mode: 0o700 });
    const snapshot = info(module);
    await assert.rejects(
      patchPm2Logrotate(module, true),
      `Unsafe ${kind} source was accepted.`,
    );
    assert.deepEqual(
      info(module),
      snapshot,
      `Unsafe ${kind} source was replaced.`,
    );
  }
  const module = fixture();
  const result = cli("pm2-parser", module);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(info(module).text, originalSource);
  assert(result.stdout.includes('"changed": false'));
  assert.notEqual(cli("pm2-parser", module, "--apply", "--apply").status, 0);
  assert.notEqual(cli("pm2-parser", module, "--force").status, 0);
  assert.equal(cli("--help").status, 0);
  assert.equal(cli("pm2-parser", module, "--apply").status, 0);
  assert.equal(digest(info(module).text), logrotateSourceHashes.fixed);
  assert.equal(cli("pm2-parser", module, "--rollback").status, 0);
  assert.equal(digest(info(module).text), logrotateSourceHashes.fixed);
  assert.equal(cli("pm2-parser", module, "--rollback", "--apply").status, 0);
  assert.equal(info(module).text, originalSource);

  const reopenCommand = [
    "/usr/bin/printf",
    "plain",
    "two words",
    "a'b",
    'a"b',
    "a\\b",
    "$(touch forbidden)",
  ];
  const policy = {
    version: 1,
    docker: { maxLogBytes: 1234567, maxLogFiles: 3 },
    journald: { systemMaxUseBytes: 123456789, runtimeMaxUseBytes: 9876543 },
    opsLogs: [
      {
        path: "/var/log/nightly backup.log",
        owner: "root",
        group: "root",
        maxBytes: 123456,
        rotate: 7,
        reopenCommand,
      },
    ],
    pm2: {
      maxLogBytes: 1234567,
      retain: 8,
      compress: true,
      rotateModule: false,
      workerIntervalSeconds: 31,
    },
  };
  const daemon = {
    "data-root": "/srv/docker",
    features: { buildkit: true },
    "log-driver": "local",
    "log-opts": { "max-file": "1" },
  };
  const originalDaemon = structuredClone(daemon);
  const rendered = renderLogPolicy(policy, daemon);
  assert.deepEqual(
    daemon,
    originalDaemon,
    "Rendering must not mutate existing settings.",
  );
  const dockerJson: unknown = JSON.parse(rendered.configs["daemon.json"] ?? "");
  assert.deepEqual(dockerJson, {
    ...daemon,
    "log-driver": "json-file",
    "log-opts": { "max-size": "1234567", "max-file": "3" },
  });
  assert.match(
    rendered.configs["compose-logging.yaml"] ?? "",
    /max-size: "1234567"/,
  );
  assert.equal(
    rendered.configs["journald.conf"],
    "[Journal]\nSystemMaxUse=123456789\nRuntimeMaxUse=9876543\n",
  );
  assert.match(
    rendered.configs["logrotate.conf"] ?? "",
    /"\/var\/log\/nightly backup.log"/,
  );
  assert(
    (rendered.configs["logrotate.conf"] ?? "").includes(
      `        ${reopenCommand.map(quote).join(" ")}\n`,
    ),
  );
  const roundTrip = spawnSync(
    "bash",
    ["-c", `printf '%s\\0' ${reopenCommand.map(quote).join(" ")}`],
    {
      encoding: "utf8",
      cwd: work,
      timeout: 10000,
    },
  );
  assert.equal(roundTrip.status, 0, roundTrip.stderr);
  assert.deepEqual(roundTrip.stdout.split("\0").slice(0, -1), reopenCommand);
  assert(
    !fs.existsSync(join(work, "forbidden")),
    "Quoted shell syntax ran as code.",
  );
  const logrotate = rendered.configs["logrotate.conf"] ?? "";
  assert.match(logrotate, /^ {4}nocopytruncate$/m);
  assert.match(logrotate, /^ {4}nodateext$/m);
  assert.doesNotMatch(logrotate, /^ {4}(?:copytruncate|dateext)$/m);
  const serviceLog = renderLogPolicy({
    version: 1,
    opsLogs: [{ ...policy.opsLogs[0], owner: "nobody", group: "nogroup" }],
  }).configs["logrotate.conf"];
  assert.match(serviceLog ?? "", /^ {4}su root root$/m);
  assert.match(serviceLog ?? "", /^ {4}create 0640 nobody nogroup$/m);
  assert.match(
    rendered.configs["pm2-settings.sh"] ?? "",
    /pm2 set pm2-logrotate:rotateModule 'false'/,
  );
  // These validators read config text only. Neither contacts a daemon nor runs the script.
  if (spawnSync("docker", ["compose", "version"]).status === 0) {
    const compose = `${rendered.configs["compose-logging.yaml"]}services:\n  fixture:\n    image: busybox:latest\n    logging: *logging\n`;
    const parsed = spawnSync(
      "docker",
      ["compose", "-f", "-", "config", "--format", "json"],
      { input: compose, encoding: "utf8", timeout: 10000 },
    );
    assert.equal(parsed.status, 0, parsed.stderr);
    const config: unknown = JSON.parse(parsed.stdout);
    assert(config && typeof config === "object" && "services" in config);
    assert(
      config.services &&
        typeof config.services === "object" &&
        "fixture" in config.services,
    );
    const service = config.services.fixture;
    assert(service && typeof service === "object" && "logging" in service);
    assert.deepEqual(service.logging, {
      driver: "json-file",
      options: { "max-size": "1234567", "max-file": "3" },
    });
    const broken = spawnSync("docker", ["compose", "-f", "-", "config"], {
      input: compose.replace("*logging", "*missing"),
      encoding: "utf8",
      timeout: 10000,
    });
    assert.notEqual(
      broken.status,
      0,
      "The native compose validator must reject a planted missing anchor.",
    );
    console.log(
      "Native Docker Compose config passed, including a failing positive control. No container was started.",
    );
  }
  const shell = spawnSync("shellcheck", ["--shell=bash", "-"], {
    input: rendered.configs["pm2-settings.sh"],
    encoding: "utf8",
    timeout: 10000,
  });
  assert.equal(shell.status, 0, shell.stdout + shell.stderr);
  const file = join(work, "policy.json");
  privateFile(file, JSON.stringify(policy));
  const baseFile = join(work, "daemon.json");
  privateFile(baseFile, JSON.stringify(daemon));
  fs.chmodSync(baseFile, 0o644);
  const renderedCli = cli(file, "--daemon-json", baseFile);
  assert.equal(renderedCli.status, 0, renderedCli.stderr);
  assert.deepEqual(JSON.parse(renderedCli.stdout), rendered);
  assert.equal(fs.readFileSync(file, "utf8"), JSON.stringify(policy));
  assert.equal(fs.readFileSync(baseFile, "utf8"), JSON.stringify(daemon));
  assert.notEqual(
    cli(file, "--apply").status,
    0,
    "Config rendering must have no implicit installation mode.",
  );
  const fifo = join(work, "policy.fifo");
  execFileSync("mkfifo", [fifo]);
  fs.chmodSync(fifo, 0o600);
  for (const args of [[fifo], [file, "--daemon-json", fifo]]) {
    const rejected = cli(...args);
    assert.equal(rejected.error, undefined, "A FIFO read timed out.");
    assert.equal(rejected.signal, null);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /wrong file type/);
  }
  const replacement = join(work, "replacement.json");
  privateFile(replacement, JSON.stringify(policy));
  // Replace the checked file just before open, in a child isolated from the real gzip checks.
  const replacementCheck = spawnSync(
    process.execPath,
    [
      "--eval",
      `import assert from "node:assert/strict";
       import { mock } from "bun:test";
       import { lstat, open } from "node:fs/promises";
       import { unlinkSync, chmodSync } from "node:fs";
       import { execFileSync } from "node:child_process";
       const realOpen = open;
       const realLstat = lstat;
       const target = ${JSON.stringify(replacement)};
       let swapped = false;
       mock.module("node:fs/promises", () => ({
         lstat: realLstat,
         open: async (path, flags) => {
           assert.equal(path, target);
           unlinkSync(target);
           execFileSync("mkfifo", [target]);
           chmodSync(target, 0o600);
           swapped = true;
           return realOpen(path, flags);
         },
       }));
       const { readSafeFile } = await import(${JSON.stringify(join(root, "src/files.ts"))});
       await assert.rejects(readSafeFile(target, { privateFile: true }), /one link/);
       assert.equal(swapped, true);
       console.log("Replacement FIFO rejected without blocking.");`,
    ],
    { cwd: root, encoding: "utf8", timeout: 10000 },
  );
  assert.equal(
    replacementCheck.status,
    0,
    replacementCheck.error?.message ?? replacementCheck.stderr,
  );
  assert.match(replacementCheck.stdout, /Replacement FIFO rejected/);
  for (const mode of [0o400, 0o640, 0o644, 0o660, 0o1600, 0o2600, 0o4600]) {
    fs.chmodSync(file, mode);
    assert.notEqual(
      cli(file).status,
      0,
      "A policy without exact private mode 0600 was accepted.",
    );
  }
  fs.chmodSync(file, 0o600);
  fs.chmodSync(baseFile, 0o664);
  assert.notEqual(cli(file, "--daemon-json", baseFile).status, 0);
  fs.chmodSync(baseFile, 0o644);
  const policyLink = join(work, "linked-policy.json");
  fs.symlinkSync(file, policyLink);
  assert.notEqual(cli(policyLink).status, 0);
  const policyHardlink = join(work, "policy-copy.json");
  fs.linkSync(file, policyHardlink);
  assert.notEqual(cli(file).status, 0);
  fs.rmSync(policyHardlink);
  privateFile(file, '{"secret":"Do-not-print-this",');
  const invalidCli = cli(file);
  assert.notEqual(invalidCli.status, 0);
  assert(
    !(invalidCli.stdout + invalidCli.stderr).includes("Do-not-print-this"),
  );

  for (const input of [
    {},
    { version: 1 },
    { version: 2, docker: policy.docker },
    { ...policy, unknown: true },
    { version: 1, docker: { maxLogBytes: 0, maxLogFiles: 3 } },
    { version: 1, docker: { maxLogBytes: 1.5, maxLogFiles: 3 } },
    {
      version: 1,
      docker: { maxLogBytes: Number.MAX_SAFE_INTEGER + 1, maxLogFiles: 3 },
    },
    { version: 1, docker: { maxLogBytes: 1024, maxLogFiles: 0 } },
    { version: 1, journald: { systemMaxUseBytes: 0, runtimeMaxUseBytes: 1 } },
    { version: 1, opsLogs: [policy.opsLogs[0], policy.opsLogs[0]] },
    ...[
      "/var/lib/docker/containers/test.log",
      "/srv/docker/containers/" + "a".repeat(64) + "/x.log",
      "/other/x-json.log",
      "/var/log/*.log",
      "/var/log/../x.log",
      "/var/log/a\npostrotate",
    ].map((path) => ({
      version: 1,
      opsLogs: [{ ...policy.opsLogs[0], path }],
    })),
    { version: 1, pm2: { ...policy.pm2, compress: "true" } },
    { version: 1, pm2: { ...policy.pm2, workerIntervalSeconds: 0 } },
  ])
    assert.throws(
      () => renderLogPolicy(input),
      "An invalid policy was accepted.",
    );
  assert(
    !fs.existsSync(called),
    "The compiled log-policy CLI called PM2 or SSH.",
  );
  console.log(
    "Passed: rendering and compiled Node CLI safety; FIFO rejection before open and after a replacement; exact 0600 policy mode; actual PMX boolean failure before patch; boolean/string true and false after patch; real module gzip bytes and payload; dry-run, idempotence, rollback, source guards, locks and UID/GID/mode preservation. No real PM2 daemon was used.",
  );
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
