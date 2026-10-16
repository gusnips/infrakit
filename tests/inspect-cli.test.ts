import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  readdir,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  checks,
  parseResults,
  printResults,
  quote,
  scriptFor,
  sshRead,
  type Check,
} from "../src/inspect.js";
import { host, loadManifest, parseManifest } from "../src/manifest.js";
import { absolutePath, readSafeFile } from "../src/files.js";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const scratch = join(root, ".scratch");
await mkdir(scratch, { mode: 0o700, recursive: true });
const temporary = await mkdtemp(join(scratch, "cli-"));
const tools = join(temporary, "tools");
await mkdir(tools, { mode: 0o700 });
const gnuPath =
  process.platform === "darwin"
    ? "/usr/local/opt/bash/bin:/usr/local/opt/coreutils/libexec/gnubin:/usr/local/opt/util-linux/bin:/usr/local/bin"
    : (process.env.PATH ?? "/usr/bin:/bin");
const originalPath = process.env.PATH;
const originalConnection = process.env.SSH_CONNECTION;
const originalMode = process.umask(0o077);
process.env.PATH = `${tools}:${gnuPath}:/usr/bin:/bin`;
process.env.TEST_TOOLS = tools;
process.env.GNU_BASH = "bash";
const realOpenSSL = spawnSync("sh", ["-c", "command -v openssl"], {
  encoding: "utf8",
}).stdout.trim();
assert(realOpenSSL);
process.env.TEST_OPENSSL = realOpenSSL;
const secret = "not-a-real-password-93827";
const connection = "192.0.2.10 52111 192.0.2.20 22";
process.env.SSH_CONNECTION = connection;
const sudoCommand =
  'sudo -n env SSH_CONNECTION="${SSH_CONNECTION-}" bash --noprofile --norc -s -- infrakit-inspect-sudo';
async function privateWrite(path: string, contents: string) {
  await writeFile(path, contents, { mode: 0o600 });
}
async function tool(name: string, body: string) {
  await writeFile(join(tools, name), `#!/usr/bin/env bash\n${body}\n`, {
    mode: 0o700,
  });
}
function execute(script: string, args: string[] = []) {
  const result = spawnSync(
    "bash",
    ["--noprofile", "--norc", "-s", "--", ...args],
    {
      input: script,
      encoding: "utf8",
      env: process.env,
      timeout: 10_000,
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert(!result.stdout.includes(secret));
  return result.stdout;
}
function status(items: Check[], output: string, label: string) {
  return parseResults(items, output).find(
    (result) => result.check.label === label,
  )?.status;
}
try {
  for (const value of [
    "-oProxyCommand=bad",
    "ops@server.example.net;touch /tmp/x",
    "ops@host\n",
    "ops@host\r",
    "a..b",
    "-bad.example.net",
    `${"a".repeat(64)}.example.net`,
  ])
    assert.throws(() => host(value));
  assert.equal(host("ops@server.example.net"), "ops@server.example.net");
  assert.equal(
    parseManifest({ version: 1, host: "server.example.net" }).sudo,
    false,
  );
  assert.equal(
    parseManifest({ version: 1, host: "server.example.net", sudo: false }).sudo,
    false,
  );
  assert.equal(
    parseManifest({ version: 1, host: "server.example.net", sudo: true }).sudo,
    true,
  );
  for (const sudo of ["true", "sudo -S", 1, null, {}, []])
    assert.throws(() =>
      parseManifest({ version: 1, host: "server.example.net", sudo }),
    );
  for (const value of [
    "/var/../etc",
    "/var//data",
    "/var/data\n",
    "/var/\u009bdata",
    `/var/${String.fromCharCode(0x202e)}data`,
    "/var/",
    "/",
    "relative",
  ])
    assert.throws(() => absolutePath(value));
  assert.equal(absolutePath("/", true), "/");
  assert.throws(() =>
    parseManifest({ version: 1, host: "server.example.net", secret }),
  );
  assert.throws(() =>
    parseManifest({
      version: 1,
      host: "server.example.net",
      inventory: { docker: null },
    }),
  );
  const emptyInventory = {
    docker: null,
    pm2: [],
    envFiles: [],
    backups: [],
    certificates: [],
    redis: [],
    mail: null,
  };
  const declaredAbsent = checks(
    parseManifest({
      version: 1,
      host: "server.example.net",
      inventory: emptyInventory,
    }),
  );
  assert(
    declaredAbsent.every(
      (check) =>
        !/^(Docker|PM2|Env file|Backup|Caddy|PostgreSQL|Redis|Mail)/.test(
          check.label,
        ),
    ),
  );
  assert.throws(() =>
    parseManifest({
      version: 1,
      host: "server.example.net",
      inventory: {
        ...emptyInventory,
        backups: [{ name: "nightly", statePath: "/var/lib/infrakit/nightly" }],
      },
    }),
  );
  const file = join(temporary, "private.json");
  await privateWrite(file, '{"version":1,"host":"server.example.net"}');
  assert.equal((await loadManifest(file)).host, "server.example.net");
  await chmod(file, 0o644);
  await assert.rejects(loadManifest(file));
  await chmod(file, 0o600);
  const linked = join(temporary, "linked.json");
  await symlink(file, linked);
  await assert.rejects(readSafeFile(linked, { privateFile: true }));
  const hardlink = join(temporary, "hardlink.json");
  await link(file, hardlink);
  await assert.rejects(readSafeFile(file, { privateFile: true }));
  await rm(hardlink);
  for (const mode of [0o1600, 0o2600, 0o4600]) {
    await chmod(file, mode);
    await assert.rejects(
      loadManifest(file),
      "Private files must reject special mode bits.",
    );
    await assert.rejects(
      readSafeFile(file, { privateFile: true, metadataOnly: true }),
    );
  }
  await chmod(file, 0o600);
  const metadata = await readSafeFile(file, {
    privateFile: true,
    metadataOnly: true,
  });
  assert.equal(
    metadata.text,
    "",
    "Plan validation must return metadata without contents.",
  );
  assert.equal(metadata.info.size, Buffer.byteLength(await readFile(file)));
  await privateWrite(file, "x".repeat(1024 * 1024));
  assert.equal(
    (await readSafeFile(file, { privateFile: true })).text.length,
    1024 * 1024,
  );
  await privateWrite(file, "x".repeat(1024 * 1024 + 1));
  await assert.rejects(readSafeFile(file, { privateFile: true }));
  await assert.rejects(
    readSafeFile(file, { privateFile: true, metadataOnly: true }),
  );
  await assert.rejects(readSafeFile(temporary));
  const parentLink = join(temporary, "parent-link");
  await symlink(tools, parentLink);
  await privateWrite(join(tools, "linked-parent.json"), "{}");
  await assert.rejects(
    readSafeFile(join(parentLink, "linked-parent.json"), { privateFile: true }),
  );
  await chmod(temporary, 0o770);
  await assert.rejects(loadManifest(file));
  await chmod(temporary, 0o700);
  await privateWrite(file, `{${secret}`);
  await assert.rejects(
    loadManifest(file),
    (error: unknown) =>
      error instanceof Error && !error.message.includes(secret),
  );

  await tool(
    "find",
    `[[ \${TEST_FIND:-} != fail ]] || exit 1\nif [[ $1 == /run ]]; then exit 0; fi\nnode --input-type=module -e 'import {readdirSync} from "node:fs"; const args=process.argv.slice(1); const delimiter=args.at(-1)==="%f\\\\0"?"\\u0000":"\\n"; for(const file of readdirSync(args[0],{withFileTypes:true})) { if(!file.isFile()&&!file.isSymbolicLink()) continue; if(args.includes("*__*.log")&&!/^.*__.*[.]log([.]gz)?$/s.test(file.name)) continue; process.stdout.write(file.name+delimiter); }' "$@"\n[[ \${TEST_FIND:-} != partial-fail ]] || exit 1`,
  );
  await tool(
    "df",
    '[[ ${TEST_DF:-} != fail ]] || exit 1\nif [[ $* == *ipcent* ]]; then printf "IUse%%\\n10%%\\n"; else printf "Use%% Avail\\n10%% 9000000\\n"; fi',
  );
  await tool(
    "journalctl",
    '[[ ${TEST_JOURNAL:-} != fail ]] || exit 1\nprintf "Archived and active journals take up 10.0M in the file system.\\n"',
  );
  await tool(
    "systemctl",
    '[[ ${TEST_SYSTEMCTL:-} != fail ]] || exit 1\nif [[ $1 == is-enabled ]]; then printf "enabled\\n"; elif [[ $1 == is-active ]]; then [[ ${TEST_UPGRADE_TIMER:-} != inactive ]] || exit 1; printf "active\\n"; elif [[ $* == *LoadState* ]]; then printf "loaded\\n"; else exit 1; fi',
  );
  await tool(
    "apt-config",
    '[[ ${TEST_APT:-} != fail ]] || exit 1\n[[ ${TEST_APT:-} != disabled ]] || printf \'APT::Periodic::Enable "0";\\n\'\nprintf \'APT::Periodic::Update-Package-Lists "1";\\nAPT::Periodic::Unattended-Upgrade "1";\\n\'',
  );
  await tool(
    "sshd",
    'printf "%s\\n" "${!#}" >>"$TEST_TOOLS/sshd-contexts"\nprintf "passwordauthentication no\\nkbdinteractiveauthentication no\\npermitrootlogin no\\n"',
  );
  await tool(
    "docker",
    'printf "%s\\n" "$*" >>"$TEST_TOOLS/docker-argv"\ncase $1 in\nps) [[ ${TEST_DOCKER:-} != unreadable ]] || exit 1; printf "database\\n" ;;\ninspect) if [[ ${TEST_DOCKER:-} == uncapped ]]; then printf "true|json-file||\\n"; else printf "true|json-file|10m|3\\n"; fi ;;\nsystem) printf "1GB (50%%)\\n0B (0%%)\\n" ;;\nexec) [[ $3 == cat ]] || exit 9; printf "public certificate fixture\\n" ;;\n*) exit 9 ;;\nesac',
  );
  await tool(
    "openssl",
    'if [[ ${TEST_CERT:-} == real ]]; then exec "$TEST_OPENSSL" "$@"; fi\n[[ $* == *" -in "* ]] || cat >/dev/null\nif [[ ${TEST_CERT:-} == expiring ]]; then printf "notAfter=Jan 1 00:00:00 2020 GMT\\n"; else printf "notAfter=Jan 1 00:00:00 2030 GMT\\n"; fi',
  );
  process.env.TEST_SECRET = secret;
  await tool(
    "redis-cli",
    'printf "%s\\n" "$*" >"$TEST_TOOLS/redis-argv"\n[[ ${REDISCLI_AUTH:-} == "$TEST_SECRET" ]] || exit 1\nif [[ ${TEST_REDIS:-} == uncapped ]]; then printf "used_memory:100000\\r\\nmaxmemory:0\\r\\n"; else printf "used_memory:100000\\r\\nmaxmemory:1000000\\r\\n"; fi',
  );
  await tool("pm2", 'touch "$TEST_TOOLS/pm2-called"; exit 9');
  await tool(
    "ssh",
    'printf "%s\\n" "$@" >"$TEST_TOOLS/ssh-argv"\nif [[ ${TEST_SSH:-} == fail || ( ${TEST_SSH:-} == sudo-denied && ${!#} == sudo\\ -n\\ env\\ * ) ]]; then printf "%s\\n" "$TEST_SECRET" >&2; exit 255; fi\nexec sh -c "${!#}"',
  );
  // Drop the connection field as sudo normally does; keep the local command-fake controls.
  await tool(
    "sudo",
    '[[ $# == 9 && $1 == -n && $2 == env && $3 == SSH_CONNECTION=* && $4 == bash && $5 == --noprofile && $6 == --norc && $7 == -s && $8 == -- && $9 == infrakit-inspect-sudo ]] || exit 9\nunset SSH_CONNECTION\nSUDO_UID=$(id -u); export SUDO_UID\nshift\nexec "$@"',
  );

  const now = Math.floor(Date.now() / 1000);
  const envPath = join(temporary, "env's $(printf injected) file");
  await privateWrite(envPath, `PASSWORD=${secret}\n`);
  const authPath = join(temporary, "redis.auth");
  await privateWrite(authPath, `${secret}\n`);
  const mailPath = join(temporary, "mail.conf");
  await privateWrite(
    mailPath,
    `SMTP_HOST=mail.example.net\nSMTP_USER=ops\nSMTP_PASS='${secret}'\nSMTP_FROM=ops@example.net\nSMTP_TO=(reader@example.net)\n`,
  );
  const mailProof = join(temporary, "mail-proof");
  await privateWrite(
    mailProof,
    `infrakit-mail-test-v1\n${now + 1}\nrecipient-confirmed\n`,
  );
  // Keep the confirmation after the configuration mtime but not in the server's future.
  await new Promise((resolve) => setTimeout(resolve, 1100));
  const state = join(temporary, "state");
  const archive = join(temporary, "archive");
  await mkdir(archive, { mode: 0o700 });
  const snapshot = "20261011T120000Z-abc123";
  const receipt = join(state, "receipts", snapshot);
  await mkdir(receipt, { recursive: true, mode: 0o700 });
  const remote = "archive:bucket/host/nightly";
  const proof = `infrakit-snapshot-v1\nnightly\n${snapshot}\n${now}\n${remote}\n`;
  await privateWrite(join(state, "last-success"), proof);
  const owner = `infrakit-owner-v1\nnightly\n${archive}\n${remote}\n`;
  await privateWrite(join(state, ".infrakit-owner"), owner);
  await privateWrite(join(archive, ".infrakit-owner"), owner);
  await privateWrite(join(state, "offsite-enabled"), `${remote}/${snapshot}\n`);
  await privateWrite(join(receipt, "proof"), proof);
  const receiptFiles = "complete.age\ndatabase.dump.age\nmanifest.txt.age\n";
  await privateWrite(join(receipt, "files"), receiptFiles);
  await privateWrite(join(receipt, "complete.sha256"), `${"a".repeat(64)}\n`);
  const logs = join(temporary, "logs");
  await mkdir(logs, { mode: 0o700 });
  const rotated = join(logs, "worker__2026-10-11_12-00-00.log.gz");
  const compressed = spawnSync("gzip", ["-c"], {
    input: "a real rotated log\n",
  });
  assert.equal(compressed.status, 0);
  await writeFile(rotated, compressed.stdout, { mode: 0o600 });
  const manifest = parseManifest({
    version: 1,
    host: "ops@server.example.net",
    sshd: {
      user: "ops",
      clientAddress: "192.0.2.10",
      clientHost: "client.example.net",
    },
    inventory: {
      docker: { containers: ["database"] },
      pm2: [
        {
          unit: "pm2-ops.service",
          pidFile: join(temporary, "missing.pid"),
          logsPath: logs,
          after: ["redis-server.service", "docker.service"],
        },
      ],
      envFiles: [envPath],
      backups: [
        {
          name: "nightly",
          statePath: state,
          archivePath: archive,
          remoteRoot: remote,
          ownerUid: process.getuid?.(),
        },
      ],
      certificates: [
        {
          name: "shared",
          kind: "caddy",
          path: "/var/lib/caddy/certificates/shared.crt",
        },
        {
          name: "database",
          kind: "postgres",
          path: "/etc/postgres/server.crt",
          container: "database",
        },
      ],
      redis: [{ name: "cache", authFile: authPath }],
      mail: { configPath: mailPath, testProofPath: mailProof },
    },
  });
  const all = checks(manifest);
  const positive = all.filter((check) => !check.label.startsWith("PM2 unit"));
  const script = await scriptFor(positive);
  const output = execute(script);
  assert.deepEqual(
    parseResults(positive, output)
      .map((result) => [result.check.label, result.status])
      .filter(([, state]) => state !== "pass"),
    [],
  );
  // Both users need the real local endpoint. Invalid evidence must not call sshd at all.
  const sshItems = positive.filter(
    (check) => check.label === "SSH login rules",
  );
  const sshScript = await scriptFor(sshItems);
  const fakeSshd = await readFile(join(tools, "sshd"), "utf8");
  const sshdRules =
    "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n";
  for (const [rules, expected] of [
    [sshdRules, "pass"],
    [sshdRules.replace(/^\S+/gm, (key) => key.toUpperCase()), "pass"],
    [
      sshdRules.replace(
        "PasswordAuthentication no",
        "PasswordAuthentication yes",
      ),
      "finding",
    ],
    [
      sshdRules.replace(
        "KbdInteractiveAuthentication no",
        "KbdInteractiveAuthentication yes",
      ),
      "finding",
    ],
    [sshdRules.replace("PermitRootLogin no", "PermitRootLogin yes"), "finding"],
    [
      sshdRules.replace(
        "PasswordAuthentication no",
        "PasswordAuthentication NO",
      ),
      "unknown",
    ],
    [sshdRules.replace("KbdInteractiveAuthentication no\n", ""), "unknown"],
  ]) {
    assert(rules && expected);
    await tool("sshd", `printf '%s' ${quote(rules)}`);
    assert.equal(
      status(sshItems, execute(sshScript), "SSH login rules"),
      expected,
      rules,
    );
  }
  await writeFile(join(tools, "sshd"), fakeSshd);
  for (const address of [
    "192.0.2.20",
    "0.0.0.0",
    "255.255.255.255",
    "2001:db8::20",
    "::",
    "::1",
    "2001:db8:0:0:0:0:0:20",
    "::ffff:192.0.2.20",
    "2001:db8:0:0:0:0:192.0.2.20",
  ]) {
    await rm(join(tools, "sshd-contexts"), { force: true });
    process.env.SSH_CONNECTION = `192.0.2.10 52111 ${address} 2222`;
    assert.equal(
      status(sshItems, execute(sshScript), "SSH login rules"),
      "pass",
    );
    assert.deepEqual(
      (await readFile(join(tools, "sshd-contexts"), "utf8"))
        .trimEnd()
        .split("\n"),
      ["ops", "root"].map(
        (user) =>
          `user=${user},addr=192.0.2.10,host=client.example.net,laddr=${address},lport=2222`,
      ),
    );
  }
  for (const badConnection of [
    "",
    "192.0.2.10 52111",
    "192.0.2.10 52111 192.0.2.20 22 extra",
    "192.0.2.10 52111 192.0.2.20 0",
    "192.0.2.10 52111 192.0.2.20 65536",
    "192.0.2.10 65536 192.0.2.20 22",
    "192.0.2.10 52111 192.0.2.20 022",
    "192.0.2.10 52111 host.example.net 22",
    "192.0.2.10 52111 192.0.2.999 22",
    "192.0.2.10 52111 192.00.2.20 22",
    "192.0.2.10 52111 1:2:3:4:5:6:7 22",
    "192.0.2.10 52111 1:2:3:4:5:6:7:8:9 22",
    "192.0.2.10 52111 1:2:3:4:5:6:7::8 22",
    "192.0.2.10 52111 2001:db8:::20 22",
    "192.0.2.10 52111 2001::db8::20 22",
    "192.0.2.10 52111 ::ffff:192.0.2.999 22",
    "192.0.2.10 52111 2001:db8::20%eth0 22",
    "client.example.net 52111 192.0.2.20 22",
    `${connection}\n`,
    connection.replace(" ", "\t"),
  ]) {
    await rm(join(tools, "sshd-contexts"), { force: true });
    process.env.SSH_CONNECTION = badConnection;
    assert.equal(
      status(sshItems, execute(sshScript), "SSH login rules"),
      "unknown",
    );
    await assert.rejects(readFile(join(tools, "sshd-contexts")));
  }
  delete process.env.SSH_CONNECTION;
  assert.equal(
    status(sshItems, execute(sshScript), "SSH login rules"),
    "unknown",
  );
  process.env.SSH_CONNECTION = connection;

  // Evaluate a real Match rule offline. This never starts a daemon or opens an SSH connection.
  const realSshd = spawnSync("sh", ["-c", "command -v sshd"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${gnuPath}:/usr/bin:/bin:/usr/sbin:/sbin` },
  }).stdout.trim();
  assert(realSshd, "Install OpenSSH sshd for the offline Match rule check.");
  const hostKey = join(temporary, "host-key");
  const keygen = spawnSync(
    "ssh-keygen",
    ["-q", "-t", "ed25519", "-N", "", "-f", hostKey],
    {
      encoding: "utf8",
      timeout: 10_000,
    },
  );
  assert.equal(keygen.status, 0, keygen.stderr);
  const sshConfig = join(temporary, "sshd.conf");
  const sshConfigText = `HostKey "${hostKey}"\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nMatch LocalAddress 192.0.2.20\n  PasswordAuthentication yes\n`;
  await privateWrite(sshConfig, sshConfigText);
  const omittedEndpoint = spawnSync(
    realSshd,
    [
      "-T",
      "-f",
      sshConfig,
      "-C",
      "user=ops,addr=192.0.2.10,host=client.example.net",
    ],
    {
      encoding: "utf8",
      timeout: 10_000,
    },
  );
  assert.equal(omittedEndpoint.status, 0, omittedEndpoint.stderr);
  assert.match(omittedEndpoint.stdout, /^passwordauthentication no$/im);
  await tool("sshd", `exec ${quote(realSshd)} -f ${quote(sshConfig)} "$@"`);
  assert.equal(
    status(sshItems, execute(sshScript), "SSH login rules"),
    "finding",
  );
  process.env.SSH_CONNECTION = "192.0.2.10 52111 192.0.2.21 22";
  assert.equal(status(sshItems, execute(sshScript), "SSH login rules"), "pass");
  await privateWrite(
    sshConfig,
    sshConfigText.replace(
      "Match LocalAddress 192.0.2.20",
      "Match LocalAddress 192.0.2.20 LocalPort 22",
    ),
  );
  process.env.SSH_CONNECTION = connection;
  assert.equal(
    status(sshItems, execute(sshScript), "SSH login rules"),
    "finding",
  );
  process.env.SSH_CONNECTION = "192.0.2.10 52111 192.0.2.20 2222";
  assert.equal(status(sshItems, execute(sshScript), "SSH login rules"), "pass");
  process.env.SSH_CONNECTION = connection;
  await writeFile(join(tools, "sshd"), fakeSshd);

  const display: string[] = [];
  assert.equal(
    printResults(parseResults(positive, output), (line) => display.push(line)),
    0,
  );
  assert(
    display.every(
      (line) =>
        !line.includes("\u001b") &&
        !line.includes(String.fromCharCode(0x2014)) &&
        !line.includes(secret),
    ),
  );
  assert.equal(
    status(all, execute(await scriptFor(all)), "PM2 unit pm2-ops.service"),
    "unknown",
  );
  await assert.rejects(readFile(join(tools, "pm2-called")));

  // A local /proc fixture checks Linux cgroup logic without creating a daemon.
  const proc = join(temporary, "proc");
  await mkdir(join(proc, "4242"), { recursive: true, mode: 0o700 });
  const cgroup = join(proc, "4242", "cgroup");
  await privateWrite(join(proc, "4242", "cmdline"), "PM2 v6.0.0: God Daemon\0");
  await privateWrite(join(temporary, "missing.pid"), "4242\n");
  await chmod(join(temporary, "missing.pid"), 0o644);
  await privateWrite(cgroup, "0::/system.slice/pm2-ops.service\n");
  await tool(
    "systemctl",
    '[[ ${TEST_SYSTEMCTL:-} != fail ]] || exit 1\nif [[ $1 == is-enabled ]]; then printf "enabled\\n"; elif [[ $1 == is-active ]]; then [[ ${TEST_UPGRADE_TIMER:-} != inactive ]] || exit 1; printf "active\\n"; elif [[ $2 == pm2-ops.service && ${TEST_UNIT:-active} != active ]]; then printf "LoadState=loaded\\nActiveState=%s\\nControlGroup=\\nAfter=redis-server.service docker.service\\nTimeoutStopUSec=2min\\n" "$TEST_UNIT"; elif [[ $2 == pm2-ops.service ]]; then printf "LoadState=loaded\\nActiveState=active\\nControlGroup=/system.slice/pm2-ops.service\\nAfter=%s\\nTimeoutStopUSec=%s\\n" "${TEST_AFTER:-redis-server.service docker.service}" "${TEST_TIMEOUT:-2min}"; elif [[ $* == *LoadState* ]]; then printf "loaded\\n"; else exit 1; fi',
  );
  const pm2Script = (await scriptFor(all)).replaceAll("/proc/", `${proc}/`);
  assert.equal(
    status(all, execute(pm2Script), "PM2 unit pm2-ops.service"),
    "pass",
  );
  await privateWrite(
    cgroup,
    "0::/user.slice/session.scope\n2:cpu:/system.slice/pm2-ops.service\n",
  );
  assert.equal(
    status(all, execute(pm2Script), "PM2 unit pm2-ops.service"),
    "finding",
  );
  await privateWrite(cgroup, "0::/system.slice/pm2-ops.service\n");
  process.env.TEST_TIMEOUT = "1min 30s";
  assert.equal(
    status(all, execute(pm2Script), "PM2 unit pm2-ops.service"),
    "finding",
  );
  delete process.env.TEST_TIMEOUT;
  process.env.TEST_AFTER = "docker.service";
  assert.equal(
    status(all, execute(pm2Script), "PM2 unit pm2-ops.service"),
    "finding",
  );
  delete process.env.TEST_AFTER;
  // A live daemon beside a stopped unit runs outside it. A unit between states is not judged.
  for (const [unitState, expected] of [
    ["inactive", "finding"],
    ["failed", "finding"],
    ["activating", "unknown"],
  ]) {
    process.env.TEST_UNIT = unitState;
    assert.equal(
      status(all, execute(pm2Script), "PM2 unit pm2-ops.service"),
      expected,
    );
  }
  delete process.env.TEST_UNIT;

  assert(!/\beval\b|\bsource\b.*\.conf|pm2 (jlist|start)/.test(script));
  const inventory = manifest.inventory;
  assert(inventory);
  const backupItems = positive.filter(
    (check) =>
      check.label === "Server clock" || check.label === "Backup nightly",
  );
  const backupScript = await scriptFor(backupItems);
  for (const [path, replacement] of [
    [
      join(state, ".infrakit-owner"),
      owner.replace(archive, `${archive}-wrong`),
    ],
    [
      join(archive, ".infrakit-owner"),
      owner.replace(remote, "archive:wrong/path"),
    ],
    [join(receipt, "proof"), proof.replace("nightly", "other")],
    [join(receipt, "files"), "database.dump.age\nmanifest.txt.age\n"],
    [join(receipt, "files"), "complete.age\nmanifest.txt.age\n"],
    [join(receipt, "files"), `${receiptFiles}../unowned.age\n`],
    [join(receipt, "files"), `${receiptFiles}manifest.txt.age\n`],
    [join(receipt, "complete.sha256"), "invalid-hash\n"],
    [join(state, "last-success"), proof.replace(String(now), `0${now}`)],
    [join(state, "last-success"), '{"lastSuccess":1234}\n'],
  ]) {
    assert(path && replacement);
    const saved = await readFile(path, "utf8");
    await privateWrite(path, replacement);
    assert.equal(
      status(backupItems, execute(backupScript), "Backup nightly"),
      "finding",
      path,
    );
    await privateWrite(path, saved);
  }
  for (const time of [now - 200000, now + 10000]) {
    const datedProof = proof.replace(String(now), String(time));
    await privateWrite(join(state, "last-success"), datedProof);
    await privateWrite(join(receipt, "proof"), datedProof);
    assert.equal(
      status(backupItems, execute(backupScript), "Backup nightly"),
      "finding",
    );
  }
  await privateWrite(join(state, "last-success"), proof);
  await privateWrite(join(receipt, "proof"), proof);
  await chmod(join(receipt, "files"), 0o644);
  assert.equal(
    status(backupItems, execute(backupScript), "Backup nightly"),
    "unknown",
  );
  await chmod(join(receipt, "files"), 0o600);
  await rm(join(receipt, "complete.sha256"));
  assert.equal(
    status(backupItems, execute(backupScript), "Backup nightly"),
    "unknown",
  );
  await privateWrite(join(receipt, "complete.sha256"), `${"a".repeat(64)}\n`);
  for (const overrides of [
    { name: "other" },
    { remoteRoot: "archive:wrong/path" },
    { ownerUid: (process.getuid?.() ?? 0) + 1 },
  ]) {
    const changed = checks(
      parseManifest({
        ...manifest,
        inventory: {
          ...inventory,
          backups: inventory.backups.map((backup) => ({
            ...backup,
            ...overrides,
          })),
        },
      }),
    ).filter(
      (check) =>
        check.label === "Server clock" || check.label.startsWith("Backup "),
    );
    assert.notEqual(
      parseResults(changed, execute(await scriptFor(changed))).at(-1)?.status,
      "pass",
    );
  }
  assert.equal(
    status(backupItems, execute(backupScript), "Backup nightly"),
    "pass",
  );

  // OpenSSL reads a real throwaway certificate, not just the command stub.
  const localCert = join(temporary, "certificate.crt");
  const generated = spawnSync(
    realOpenSSL,
    [
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:prime256v1",
      "-nodes",
      "-subj",
      "/CN=server.example.net",
      "-days",
      "45",
      "-keyout",
      join(temporary, "certificate.key"),
      "-out",
      localCert,
    ],
    { encoding: "utf8" },
  );
  assert.equal(generated.status, 0, generated.stderr);
  process.env.TEST_CERT = "real";
  for (const [minValidDays, expected] of [
    [30, "pass"],
    [60, "finding"],
  ] as const) {
    const certItems: Check[] = checks(
      parseManifest({
        ...manifest,
        inventory: {
          ...inventory,
          certificates: [
            { name: "local", kind: "caddy", path: localCert, minValidDays },
          ],
        },
      }),
    ).filter(
      (check) =>
        check.label === "Server clock" ||
        check.label === "Caddy certificate local",
    );
    assert.equal(
      status(
        certItems,
        execute(await scriptFor(certItems)),
        "Caddy certificate local",
      ),
      expected,
    );
  }
  delete process.env.TEST_CERT;

  for (const [key, value, label, expected] of [
    ["TEST_DOCKER", "uncapped", "Docker logs database", "finding"],
    ["TEST_DOCKER", "unreadable", "Docker inventory", "unknown"],
    ["TEST_DF", "fail", "Disk /", "unknown"],
    ["TEST_JOURNAL", "fail", "Journal disk size", "unknown"],
    ["TEST_APT", "fail", "Unattended upgrades", "unknown"],
    ["TEST_APT", "disabled", "Unattended upgrades", "finding"],
    ["TEST_UPGRADE_TIMER", "inactive", "Unattended upgrades", "finding"],
    ["TEST_SYSTEMCTL", "fail", "Unattended upgrades", "unknown"],
    ["TEST_FIND", "fail", "Pending reboot", "unknown"],
    ["TEST_CERT", "expiring", "Caddy certificate shared", "finding"],
    ["TEST_REDIS", "uncapped", "Redis cache", "finding"],
  ]) {
    assert(key && value && label && expected);
    process.env[key] = value;
    assert.equal(status(positive, execute(script), label), expected, label);
    Reflect.deleteProperty(process.env, key);
  }
  await privateWrite(join(state, "offsite-enabled"), "wrong-marker\n");
  assert.equal(status(positive, execute(script), "Backup nightly"), "finding");
  await privateWrite(join(state, "offsite-enabled"), `${remote}/${snapshot}\n`);
  const rotationItems = positive.filter(
    (check) =>
      check.label === "Server clock" ||
      check.label.startsWith("PM2 rotated logs"),
  );
  const rotationScript = await scriptFor(rotationItems);
  const rotationLabel = "PM2 rotated logs pm2-ops.service";
  assert.equal(
    status(rotationItems, execute(rotationScript), rotationLabel),
    "pass",
  );
  const firstGzip = "first__rotation.log.gz";
  const secondGzip = "second__rotation.log.gz";
  const misleading = `${firstGzip}\n${secondGzip}`;
  for (const file of [firstGzip, secondGzip])
    await writeFile(join(logs, file), compressed.stdout, { mode: 0o600 });
  await privateWrite(join(logs, misleading), "not gzip\n");
  const beforeRotation = (await readdir(logs)).sort();
  const currentFind = await readFile(join(tools, "find"), "utf8");
  if (process.platform === "linux") await rm(join(tools, "find"));
  const malformedRotation = parseResults(
    rotationItems,
    execute(rotationScript),
  ).find((result) => result.check.label === rotationLabel);
  assert.equal(
    malformedRotation?.status,
    "finding",
    "A newline filename was split into valid gzip paths and falsely passed.",
  );
  assert.equal(
    malformedRotation?.evidence,
    "1,4",
    "Count each basename once, including its newline.",
  );
  assert.deepEqual(
    (await readdir(logs)).sort(),
    beforeRotation,
    "Inspection wrote rotation scratch files.",
  );
  await writeFile(join(tools, "find"), currentFind, { mode: 0o700 });
  for (const failure of ["fail", "partial-fail"]) {
    process.env.TEST_FIND = failure;
    assert.equal(
      status(rotationItems, execute(rotationScript), rotationLabel),
      "unknown",
      "A failed find was reported as a rotation verdict.",
    );
  }
  delete process.env.TEST_FIND;
  for (const file of [firstGzip, secondGzip, misleading])
    await rm(join(logs, file));
  assert.equal(
    status(rotationItems, execute(rotationScript), rotationLabel),
    "pass",
  );
  await utimes(rotated, now + 10000, now + 10000);
  assert.equal(
    status(
      rotationItems,
      execute(rotationScript),
      "PM2 rotated logs pm2-ops.service",
    ),
    "finding",
  );
  await utimes(rotated, now - 800000, now - 800000);
  assert.equal(
    status(
      rotationItems,
      execute(rotationScript),
      "PM2 rotated logs pm2-ops.service",
    ),
    "unknown",
  );
  await utimes(rotated, now, now);
  await privateWrite(rotated, "not gzip");
  assert.equal(
    status(positive, execute(script), "PM2 rotated logs pm2-ops.service"),
    "finding",
  );
  await rm(rotated);
  assert.equal(
    status(positive, execute(script), "PM2 rotated logs pm2-ops.service"),
    "unknown",
  );
  const envItems = positive.filter(
    (check) => check.label === `Env file ${envPath}`,
  );
  const envScript = await scriptFor(envItems);
  const fakeFind = await readFile(join(tools, "find"), "utf8");
  // Linux uses real GNU find. macOS uses the NUL-aware stand-in with real newline fixtures.
  if (process.platform === "linux") await rm(join(tools, "find"));
  assert.equal(
    status(envItems, execute(envScript), `Env file ${envPath}`),
    "pass",
  );
  for (const suffix of [
    ".bak-old",
    ".old\ncopy.bak-old",
    ".old\ncopy.bak\n",
    ".backup-old",
  ]) {
    const backupPath = `${envPath}${suffix}`;
    await privateWrite(backupPath, secret);
    const result = parseResults(envItems, execute(envScript))[0];
    assert.equal(result?.status, "finding", suffix);
    assert.equal(
      result?.evidence,
      "1",
      "Each basename is counted once, including newlines.",
    );
    await rm(backupPath);
    assert.equal(
      status(envItems, execute(envScript), `Env file ${envPath}`),
      "pass",
    );
  }
  await writeFile(join(tools, "find"), fakeFind, { mode: 0o700 });
  await privateWrite(`${envPath}.old\ncopy.bak-old`, secret);
  for (const failure of ["fail", "partial-fail"]) {
    process.env.TEST_FIND = failure;
    assert.equal(
      status(envItems, execute(envScript), `Env file ${envPath}`),
      "unknown",
    );
  }
  delete process.env.TEST_FIND;
  assert.equal(
    status(envItems, execute(envScript), `Env file ${envPath}`),
    "finding",
  );
  await rm(`${envPath}.old\ncopy.bak-old`);
  assert.equal(
    status(envItems, execute(envScript), `Env file ${envPath}`),
    "pass",
  );
  await chmod(envPath, 0o644);
  assert.equal(
    status(positive, execute(script), `Env file ${envPath}`),
    "finding",
  );
  await chmod(envPath, 0o600);
  const mailItems = positive.filter(
    (check) =>
      check.label === "Server clock" || check.label.startsWith("Mail "),
  );
  const mailScript = await scriptFor(mailItems);
  const mailConfig = await readFile(mailPath, "utf8");
  for (const empty of [
    "",
    "''",
    '""',
    "   ",
    "# no password",
    "'' # no password",
    '"" # no password',
  ]) {
    await privateWrite(
      mailPath,
      mailConfig.replace(`SMTP_PASS='${secret}'`, `SMTP_PASS=${empty}`),
    );
    assert.equal(
      status(mailItems, execute(mailScript), "Mail configuration fields"),
      "finding",
    );
  }
  await privateWrite(
    mailPath,
    mailConfig.replace("SMTP_TO=(reader@example.net)", "SMTP_TO=()"),
  );
  assert.equal(
    status(mailItems, execute(mailScript), "Mail configuration fields"),
    "finding",
  );
  const notExecuted = join(temporary, "must-not-exist");
  await privateWrite(mailPath, `${mailConfig}touch '${notExecuted}'\n`);
  assert.equal(
    status(mailItems, execute(mailScript), "Mail configuration fields"),
    "pass",
  );
  await assert.rejects(readFile(notExecuted));
  await privateWrite(mailPath, mailConfig);
  for (const time of [now - 3000000, now + 10000]) {
    await privateWrite(
      mailProof,
      `infrakit-mail-test-v1\n${time}\nrecipient-confirmed\n`,
    );
    assert.equal(
      status(mailItems, execute(mailScript), "Mail setup test"),
      "finding",
    );
  }
  const confirmed = Math.floor(Date.now() / 1000);
  await privateWrite(
    mailProof,
    `infrakit-mail-test-v1\n${confirmed}\nrecipient-confirmed\n`,
  );
  assert.equal(
    status(mailItems, execute(mailScript), "Mail setup test"),
    "pass",
  );
  // Model owners inside the existing probe fixture. No sudo, chown or root process runs.
  const dataParent = join(temporary, "owner-data");
  await mkdir(dataParent, { mode: 0o700 });
  const dataMail = join(dataParent, "mail.conf");
  const dataProof = join(dataParent, "mail-proof");
  const dataAuth = join(dataParent, "redis.auth");
  const unreadCode = join(dataParent, "must-not-execute");
  const dataMailText = `${mailConfig}touch ${quote(unreadCode)}\n`;
  const dataProofText = `infrakit-mail-test-v1\n${confirmed}\nrecipient-confirmed\n`;
  await privateWrite(dataMail, dataMailText);
  await privateWrite(dataProof, dataProofText);
  await privateWrite(dataAuth, `${secret}\n`);
  await utimes(dataMail, confirmed - 1, confirmed - 1);
  const ownerItems = checks(
    parseManifest({
      ...manifest,
      inventory: {
        ...inventory,
        backups: inventory.backups.map((backup) => ({
          ...backup,
          ownerUid: 5252,
        })),
        redis: [{ name: "cache", authFile: dataAuth }],
        mail: { configPath: dataMail, testProofPath: dataProof },
      },
    }),
  ).filter(
    (check) =>
      check.label === "Server clock" ||
      /^(Backup|Redis|Mail) /.test(check.label),
  );
  const ownerScript = (await scriptFor(ownerItems)).replaceAll(
    "$EUID",
    "$TEST_INSPECT_EUID",
  );
  const ownerModel = `TEST_INSPECT_EUID=0\nSUDO_UID=4242\nINSPECT_OWNER_UID=4242\nTRUSTED_UID=4242\nstat() {\n  if [[ $1 == -c && $2 == %u ]]; then\n    case "\${!#}" in\n      ${quote(dataParent)}|${quote(dataParent)}/*) printf '%s\\n' "\${TEST_INSPECT_DATA_OWNER:-4242}" ;;\n      ${quote(state)}|${quote(state)}/*|${quote(archive)}|${quote(archive)}/*) printf '%s\\n' "\${TEST_INSPECT_BACKUP_OWNER:-5252}" ;;\n      *) printf '0\\n' ;;\n    esac\n  else command stat "$@"; fi\n}\n`;
  const sudoMarker = ["infrakit-inspect-sudo"];
  const modeled = (prefix = "", args = sudoMarker) =>
    execute(ownerModel + prefix + ownerScript, args);
  const unbound = parseResults(ownerItems, modeled("", []));
  assert.equal(
    unbound.find((result) => result.check.label === "Backup nightly")?.status,
    "pass",
  );
  for (const result of unbound.filter((result) =>
    /^(Redis|Mail) /.test(result.check.label),
  ))
    assert.equal(
      result.status,
      "unknown",
      "Inherited owner variables must not authorize data reads.",
    );
  assert(
    parseResults(ownerItems, modeled()).every(
      (result) => result.status === "pass",
    ),
  );
  for (const uid of ["", "4243", "04242", "4294967295", "$(touch forbidden)"])
    assert.equal(
      status(
        ownerItems,
        modeled(`SUDO_UID=${quote(uid)}\n`),
        "Mail configuration fields",
      ),
      "unknown",
    );
  assert.equal(
    status(
      ownerItems,
      modeled("TEST_INSPECT_DATA_OWNER=4243\n"),
      "Redis cache",
    ),
    "unknown",
  );
  assert.equal(
    status(
      ownerItems,
      modeled("TEST_INSPECT_BACKUP_OWNER=5253\n"),
      "Backup nightly",
    ),
    "unknown",
  );
  for (const mode of [0o640, 0o1600]) {
    await chmod(dataMail, mode);
    assert.equal(
      status(ownerItems, modeled(), "Mail configuration fields"),
      "unknown",
    );
  }
  await chmod(dataMail, 0o600);
  await chmod(dataParent, 0o770);
  assert.equal(
    status(ownerItems, modeled(), "Mail configuration fields"),
    "unknown",
  );
  await chmod(dataParent, 0o700);
  const dataLink = join(dataParent, "mail-link");
  await link(dataMail, dataLink);
  assert.equal(
    status(ownerItems, modeled(), "Mail configuration fields"),
    "unknown",
  );
  await rm(dataLink);
  await symlink(dataMail, dataLink);
  execute(
    ownerModel +
      ownerScript +
      `\nif private_file ${quote(dataLink)}; then exit 90; fi\n`,
    sudoMarker,
  );
  await rm(dataLink);
  // Data allowances never flow into sourced code, state writes or job freshness checks.
  execute(
    ownerModel +
      ownerScript +
      `\nif infra_source ${quote(dataMail)}; then exit 91; fi\nif infra_atomic ${quote(dataProof)} </dev/null; then exit 92; fi\nif infra_dir ${quote(dataParent)}; then exit 93; fi\nif infra_read_proof ${quote(join(state, "last-success"))}; then exit 94; fi\nif infra_backup_fresh ${quote(state)} 172800; then exit 95; fi\n`,
    sudoMarker,
  );
  assert.equal(await readFile(dataMail, "utf8"), dataMailText);
  assert.equal(await readFile(dataProof, "utf8"), dataProofText);
  await assert.rejects(readFile(unreadCode));
  assert(
    parseResults(ownerItems, modeled()).every(
      (result) => result.status === "pass",
    ),
  );

  const one = positive.slice(0, 1);
  assert.equal(parseResults(one, "pass\tc0\t\n")[0]?.status, "pass");
  assert.equal(
    parseResults(one, "pass\tc0\t\npass\tc0\t\n")[0]?.status,
    "unknown",
  );
  assert.equal(parseResults(one, secret)[0]?.status, "unknown");
  const bare = checks(
    parseManifest({ version: 1, host: "server.example.net" }),
  );
  assert.equal(
    printResults(parseResults(bare, execute(await scriptFor(bare))), () => {}),
    1,
  );

  process.env.TEST_SECRET = secret;
  process.env.TEST_SSH = "fail";
  await assert.rejects(
    sshRead(manifest, script),
    (error: unknown) =>
      error instanceof Error && !error.message.includes(secret),
  );
  delete process.env.TEST_SSH;
  assert((await sshRead(manifest, script)).includes("pass\tc0\t"));
  const sshArgs = () => readFile(join(tools, "ssh-argv"), "utf8");
  assert.equal(
    (await sshArgs()).trimEnd().split("\n").at(-1),
    "bash --noprofile --norc -s",
  );
  const privilegedManifest = parseManifest({ ...manifest, sudo: true });
  assert((await sshRead(privilegedManifest, script)).includes("pass\tc0\t"));
  const privilegedArgs = (await sshArgs()).trimEnd().split("\n");
  assert.equal(privilegedArgs.at(-1), sudoCommand);
  assert(privilegedArgs.includes("BatchMode=yes"));
  assert(privilegedArgs.includes("-T"));
  assert(
    !privilegedArgs.some((arg) => arg.includes("-S") || arg.includes(secret)),
  );
  const unexecutedConnection = join(temporary, "connection-must-not-execute");
  process.env.SSH_CONNECTION = `$(touch ${quote(unexecutedConnection)}) '${connection}'`;
  assert.equal(
    status(
      sshItems,
      await sshRead(privilegedManifest, sshScript),
      "SSH login rules",
    ),
    "unknown",
  );
  await assert.rejects(readFile(unexecutedConnection));
  delete process.env.SSH_CONNECTION;
  assert.equal(
    status(
      sshItems,
      await sshRead(privilegedManifest, sshScript),
      "SSH login rules",
    ),
    "unknown",
  );
  process.env.SSH_CONNECTION = connection;
  assert.equal(
    status(
      sshItems,
      await sshRead(privilegedManifest, sshScript),
      "SSH login rules",
    ),
    "pass",
  );
  process.env.TEST_SSH = "sudo-denied";
  await assert.rejects(
    sshRead(privilegedManifest, script),
    (error: unknown) =>
      error instanceof Error &&
      error.message.includes("noninteractive sudo") &&
      !error.message.includes(secret),
  );
  delete process.env.TEST_SSH;
  assert(!(await readFile(join(tools, "redis-argv"), "utf8")).includes(secret));
  assert(!(await readFile(join(tools, "ssh-argv"), "utf8")).includes(secret));
  const dockerArgs = await readFile(join(tools, "docker-argv"), "utf8");
  assert(!/restart|recreate|prune|update|daemon/.test(dockerArgs));
  const node = (args: string[]) =>
    spawnSync("node", [join(root, "dist", "cli.js"), ...args], {
      encoding: "utf8",
      env: process.env,
      timeout: 5_000,
    });
  assert.equal(node(["--help"]).status, 0);
  for (const unsafeHost of [
    "ops@host\n",
    "-oProxyCommand=bad",
    "host;printf bad",
  ])
    assert.equal(node(["inspect", unsafeHost]).status, 1);
  await writeFile(rotated, compressed.stdout, { mode: 0o600 });
  const healthyManifest = join(temporary, "healthy.json");
  await privateWrite(
    healthyManifest,
    JSON.stringify({ ...manifest, inventory: { ...inventory, pm2: [] } }),
  );
  const inspected = node(["inspect", healthyManifest]);
  assert.equal(inspected.status, 0, inspected.stderr + inspected.stdout);
  assert(inspected.stdout.includes("0 findings, 0 unverified"));
  assert(!inspected.stdout.includes(secret));
  await privateWrite(
    healthyManifest,
    JSON.stringify({
      ...manifest,
      sudo: true,
      inventory: { ...inventory, pm2: [] },
    }),
  );
  const privilegedInspection = node(["inspect", healthyManifest]);
  assert.equal(
    privilegedInspection.status,
    0,
    privilegedInspection.stderr + privilegedInspection.stdout,
  );
  assert(privilegedInspection.stdout.includes("noninteractive sudo"));
  assert.equal((await sshArgs()).trimEnd().split("\n").at(-1), sudoCommand);
  process.env.TEST_SSH = "sudo-denied";
  const deniedInspection = node(["inspect", healthyManifest]);
  assert.equal(deniedInspection.status, 1);
  assert(deniedInspection.stderr.includes("noninteractive sudo"));
  assert(!(deniedInspection.stdout + deniedInspection.stderr).includes(secret));
  delete process.env.TEST_SSH;
  await rm(join(tools, "ssh-argv"));
  const planPath = join(temporary, "plan.json");
  const { version: packageVersion } = JSON.parse(
    await readFile(join(root, "package.json"), "utf8"),
  ) as { version: string };
  const plan = {
    version: 1,
    host: "ops@server.example.net",
    sudo: true,
    install: {
      packageVersion,
      prefix: "/opt/infrakit",
      jobs: [
        {
          name: "nightly",
          configPath: mailPath,
          user: "root",
          schedule: "17 3 * * *",
        },
      ],
    },
  };
  await privateWrite(planPath, JSON.stringify(plan));
  const rendered = node(["install", planPath]);
  assert.equal(rendered.status, 0, rendered.stderr);
  assert(rendered.stdout.includes("No SSH connection was opened"));
  assert(rendered.stdout.includes("/etc/cron.d/infrakit-nightly"));
  assert(!rendered.stdout.includes(secret));
  for (const name of ["nightly_logs", "nightly-logs"]) {
    assert.equal(
      parseManifest({
        ...plan,
        install: { ...plan.install, jobs: [{ ...plan.install.jobs[0], name }] },
      }).install?.jobs[0]?.name,
      name,
    );
  }
  for (const name of [
    "nightly.logs",
    "nightly.",
    "nightly..logs",
    "nightly+logs",
    "nightly logs",
    "nightly/logs",
    "nightly@logs",
  ]) {
    assert.throws(
      () =>
        parseManifest({
          ...plan,
          install: {
            ...plan.install,
            jobs: [{ ...plan.install.jobs[0], name }],
          },
        }),
      `A cron.d-incompatible name was accepted: ${name}`,
    );
  }
  await privateWrite(
    planPath,
    JSON.stringify({
      ...plan,
      install: {
        ...plan.install,
        jobs: [{ ...plan.install.jobs[0], name: "nightly.logs" }],
      },
    }),
  );
  const dottedPlan = node(["install", planPath]);
  assert.equal(
    dottedPlan.status,
    1,
    "The compiled CLI printed a cron plan Debian would ignore.",
  );
  assert(!dottedPlan.stdout.includes("/etc/cron.d/"));
  await privateWrite(planPath, JSON.stringify(plan));
  assert.equal(
    parseManifest({
      ...manifest,
      inventory: {
        ...inventory,
        backups: inventory.backups.map((backup) => ({
          ...backup,
          name: "nightly.logs",
        })),
        docker: { ...inventory.docker, containers: ["database.logs"] },
      },
    }).inventory?.backups[0]?.name,
    "nightly.logs",
    "Cron filename restrictions leaked into logical inventory names.",
  );
  const rejected = node(["install", planPath, "--apply"]);
  assert.equal(rejected.status, 1);
  assert(rejected.stderr.includes("Apply is not supported"));
  await assert.rejects(readFile(join(tools, "ssh-argv")));
  assert.equal(
    node(["inspect", "ops@server.example.net", "--password", secret]).status,
    1,
  );
  assert.throws(() =>
    parseManifest({
      ...plan,
      install: {
        ...plan.install,
        jobs: [{ ...plan.install.jobs[0], schedule: "61 3 * * *" }],
      },
    }),
  );
  // Every public reader path must reject a FIFO before open. The parent owns the deadline.
  const fifo = join(temporary, "private.fifo");
  const madeFifo = spawnSync("mkfifo", ["-m", "600", fifo], {
    encoding: "utf8",
  });
  assert.equal(madeFifo.status, 0, madeFifo.stderr);
  const policyPath = join(temporary, "log-policy.json");
  const daemonPath = join(temporary, "daemon.json");
  await privateWrite(
    policyPath,
    JSON.stringify({
      version: 1,
      docker: { maxLogBytes: 1024, maxLogFiles: 2 },
    }),
  );
  await privateWrite(daemonPath, "{}");
  assert.equal(node(["log-policy", policyPath]).status, 0);
  assert.equal(
    node(["log-policy", policyPath, "--daemon-json", daemonPath]).status,
    0,
  );
  const fifoPlan = join(temporary, "fifo-plan.json");
  await privateWrite(
    fifoPlan,
    JSON.stringify({
      ...plan,
      install: {
        ...plan.install,
        jobs: plan.install.jobs.map((job) => ({ ...job, configPath: fifo })),
      },
    }),
  );
  const rejectsFifo = (args: string[]) => {
    const result = node(args);
    assert.equal(
      result.error,
      undefined,
      `A reader hung until the external deadline: ${args[0]}`,
    );
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert(/safely|wrong file type/.test(result.stderr), result.stderr);
  };
  for (const args of [
    ["inspect", fifo],
    ["install", fifo],
    ["install", fifoPlan],
    ["log-policy", fifo],
    ["log-policy", policyPath, "--daemon-json", fifo],
  ])
    rejectsFifo(args);
  const modulePath = join(temporary, "pm2-logrotate");
  await mkdir(modulePath, { mode: 0o700 });
  const packagePath = join(modulePath, "package.json");
  const sourcePath = join(modulePath, "app.js");
  const packageText = JSON.stringify({
    name: "pm2-logrotate",
    version: "3.0.0",
  });
  await privateWrite(packagePath, packageText);
  await privateWrite(
    sourcePath,
    "// Not the reviewed source; never execute it.\n",
  );
  // Regular files pass the reader and reach the full-source hash guard.
  assert.equal((await readSafeFile(packagePath)).text, packageText);
  assert.equal(
    (await readSafeFile(sourcePath)).text,
    "// Not the reviewed source; never execute it.\n",
  );
  const regularModule = node(["log-policy", "pm2-parser", modulePath]);
  assert.equal(regularModule.error, undefined);
  assert.equal(regularModule.status, 1);
  assert(
    regularModule.stderr.includes(
      "does not match the reviewed original or fixed source",
    ),
  );
  for (const leaf of [packagePath, sourcePath]) {
    const saved = await readFile(leaf, "utf8");
    await rm(leaf);
    const result = spawnSync("mkfifo", ["-m", "600", leaf], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    for (const flags of [
      [],
      ["--apply"],
      ["--rollback"],
      ["--rollback", "--apply"],
    ])
      rejectsFifo(["log-policy", "pm2-parser", modulePath, ...flags]);
    await rm(leaf);
    await privateWrite(leaf, saved);
  }
  await assert.rejects(readFile(join(tools, "ssh-argv")));
  console.log(
    "CLI checks passed: safe manifests, deadline-bounded FIFO reads for every caller, real offline SSH Match rules, NUL backup filenames, sudo connection forwarding, read-only probes and plan-only installation.",
  );
} finally {
  process.env.PATH = originalPath;
  if (originalConnection === undefined) delete process.env.SSH_CONNECTION;
  else process.env.SSH_CONNECTION = originalConnection;
  process.umask(originalMode);
  await rm(temporary, { recursive: true, force: true });
}
