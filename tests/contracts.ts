import assert from "node:assert/strict";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const work = mkdtempSync(join(homedir(), ".infrakit-contract-"));
chmodSync(work, 0o700);
const privateFile = (file: string, contents: string | Buffer) => {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  writeFileSync(file, contents, { mode: 0o600 });
};
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
const realAge = execFileSync("which", ["age"], { encoding: "utf8" }).trim();
const realMv = execFileSync("which", ["mv"], { encoding: "utf8" }).trim();
const realFind = execFileSync("which", ["find"], { encoding: "utf8" }).trim();
const identity = join(work, "identity");
execFileSync("age-keygen", ["-o", identity], { stdio: "pipe" });
const recipient = execFileSync("age-keygen", ["-y", identity], {
  encoding: "utf8",
}).trim();
const bin = join(work, "bin");
mkdirSync(bin, { mode: 0o700 });
for (const tool of [
  "rclone",
  "pg_dump",
  "pg_restore",
  "docker",
  "age",
  "redis-cli",
  "curl",
  "mv",
  "find",
]) {
  const wrapper = join(bin, tool);
  privateFile(
    wrapper,
    `#!/usr/bin/env bash\nexec ${quote(process.execPath)} ${quote(join(root, "tests/fakes.ts"))} ${quote(tool)} "$@"\n`,
  );
  chmodSync(wrapper, 0o700);
}
let count = 0;
const fixture = (profile = "files") => {
  const dir = join(work, `case-${++count}`);
  mkdirSync(dir, { mode: 0o700 });
  const archive = join(dir, "archive");
  const state = join(dir, "state");
  const remote = join(dir, "remote");
  const source = join(dir, "source with spaces", "settings.conf");
  privateFile(source, "private source\n");
  const service = join(dir, "pg_service.conf");
  const pass = join(dir, "pgpass");
  privateFile(service, "[backup]\n");
  privateFile(pass, "test-only\n");
  const redisConfig = join(dir, "redis.conf");
  const rdb = join(dir, "dump.rdb");
  privateFile(redisConfig, "requirepass Test-only-secret-do-not-log\n");
  privateFile(rdb, "REDIS0011fixture");
  const init = join(dir, "recovery", "init.sql");
  const pgsodium = join(dir, "recovery", "pgsodium_root.key");
  privateFile(init, "CREATE EXTENSION example;\n");
  privateFile(pgsodium, "recovery-key-fixture\n");
  const container = join(dir, "container");
  privateFile(
    join(container, "recovery", "init.sql"),
    "CREATE EXTENSION example;\n",
  );
  privateFile(
    join(container, "recovery", "key with spaces", "pgsodium_root.key"),
    "recovery-key-fixture\n",
  );
  privateFile(
    join(container, "data", "dump.rdb"),
    "REDIS0011container-fixture",
  );
  const d1Env = join(dir, "d1.conf");
  privateFile(
    d1Env,
    "CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nCF_DATABASE_ID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\nCF_API_TOKEN=Test-only-secret-do-not-log\n",
  );
  const job = join(dir, "job.conf");
  const text = `JOB_ID=nightly\nPROFILE=${profile}\nBACKEND=local\nARCHIVE_DIR=${quote(archive)}\nSTATE_DIR=${quote(state)}\nLOCAL_REMOTE_DIR=${quote(remote)}\nREMOTE_PREFIX=test/nightly\nBACKUP_AGE_RECIPIENT=${quote(recipient)}\nCONFIG_PATHS=(${quote(source)}${profile === "supabase-docker" ? ` ${quote(init)} ${quote(pgsodium)}` : ""})\nCONTAINER=database\nDB_USER=postgres\nDB_NAMES=(postgres _supabase)\nPG_SERVICE=backup\nPG_SERVICE_FILE=${quote(service)}\nPG_PASS_FILE=${quote(pass)}\nHOSTED_EXPORT_SCOPE='All schemas available to the backup role; no globals.'\nD1_ENV=${quote(d1Env)}\nD1_DOWNLOAD_HOSTS=(test.r2.cloudflarestorage.com)\nD1_TIMEOUT_SECONDS=10\n`;
  privateFile(job, text);
  return {
    dir,
    archive,
    state,
    remote,
    source,
    service,
    pass,
    redisConfig,
    rdb,
    init,
    pgsodium,
    container,
    d1Env,
    job,
    text,
    trace: join(dir, "trace"),
    capture: join(dir, "curl-capture"),
  };
};
type Fixture = ReturnType<typeof fixture>;
const environment = (f: Fixture, extra: Record<string, string> = {}) => ({
  ...process.env,
  PATH: `${bin}:${process.env.PATH ?? ""}`,
  TRACE: f.trace,
  TEST_ARCHIVE: f.archive,
  REAL_AGE: realAge,
  REAL_MV: realMv,
  REAL_FIND: realFind,
  REDIS_MARKER: join(f.dir, "redis-marker"),
  TEST_REDIS_RDB: f.rdb,
  CONTAINER_ROOT: f.container,
  D1_MARKER: join(f.dir, "d1-marker"),
  TEST_D1_ESCAPE: join(f.dir, "sql-escape.db"),
  CURL_CAPTURE: f.capture,
  ...extra,
});
const run = (
  f: Fixture,
  script = "backup",
  args = [f.job],
  extra: Record<string, string> = {},
  input = "",
) => {
  const result = spawnSync("bash", [join(root, `jobs/${script}.sh`), ...args], {
    cwd: root,
    env: environment(f, extra),
    encoding: "utf8",
    input,
    timeout: 30000,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  const output = result.stdout + result.stderr;
  assert(
    !output.includes("Test-only-secret"),
    `A credential leaked in ${script} output.`,
  );
  if (existsSync(f.trace))
    assert(
      !readFileSync(f.trace, "utf8").includes("Test-only-secret"),
      "A credential reached argv.",
    );
  return { ...result, output };
};
const trace = (f: Fixture) =>
  existsSync(f.trace) ? readFileSync(f.trace, "utf8") : "";
const completionSteps = ["copy", "check", "lsf", "copyto", "check", "lsf"];
const snapshots = (f: Fixture) =>
  existsSync(f.archive)
    ? readdirSync(f.archive).filter((name) => /^\d{8}T\d{6}Z-/.test(name))
    : [];
const lastProof = (f: Fixture) =>
  readFileSync(join(f.state, "last-success"), "utf8");
const backupOK = (f: Fixture, extra: Record<string, string> = {}) => {
  const result = run(f, "backup", [f.job], extra);
  assert.equal(result.status, 0, result.output);
  assert(result.output.includes("Offsite verified:"));
  const proof = lastProof(f).trimEnd().split("\n");
  assert.equal(proof.length, 5);
  assert.equal(proof[0], "infrakit-snapshot-v1");
  assert.equal(proof[1], "nightly");
  assert.match(proof[2] ?? "", /^\d{8}T\d{6}Z-[A-Za-z0-9]{6}$/);
  assert.equal(proof[4], `backup:${f.remote}/test/nightly`);
  assert.equal(
    lastProof(f),
    readFileSync(join(f.state, "receipts", proof[2] ?? "", "proof"), "utf8"),
  );
  const snapshot = proof[2] ?? "";
  const remote = join(f.remote, "test/nightly", snapshot);
  const completion = trace(f)
    .split("\n")
    .filter(
      (line) => line.startsWith("rclone ") && line.includes(`backup:${remote}`),
    );
  assert.deepEqual(
    completion.map((line) => line.split(" ")[1]),
    completionSteps,
    "The marker must follow payload download and exact-set checks, then pass its own download and exact-set checks.",
  );
  assert(completion[0]?.includes("--exclude /complete.age"));
  assert(completion[1]?.includes("--exclude /complete.age"));
  assert(!completion[4]?.includes("--exclude"));
  assert.equal(
    readFileSync(join(f.state, "receipts", snapshot, "files"), "utf8"),
    `${readdirSync(remote).sort().join("\n")}\n`,
  );
  assert.equal(
    readFileSync(
      join(f.state, "receipts", snapshot, "complete.sha256"),
      "utf8",
    ),
    `${createHash("sha256")
      .update(readFileSync(join(remote, "complete.age")))
      .digest("hex")}\n`,
  );
  return snapshot;
};
const oldName = "20200101T010101Z-AbCd12";
const oldCopy = (f: Fixture) => {
  const remote = join(f.remote, "test/nightly", oldName);
  const local = join(f.archive, oldName);
  const receipt = join(f.state, "receipts", oldName);
  for (const dir of [remote, local, receipt])
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  const proof = `infrakit-snapshot-v1\nnightly\n${oldName}\n${Math.floor(Date.now() / 1000) - 40 * 86400}\nbackup:${f.remote}/test/nightly\n`;
  privateFile(join(receipt, "proof"), proof);
  privateFile(join(local, "COMPLETE"), proof);
  for (const name of [
    "complete.age",
    "configs.tar.gz.age",
    "manifest.txt.age",
  ]) {
    execFileSync(realAge, ["-r", recipient, "-o", join(remote, name)], {
      input: proof,
    });
    chmodSync(join(remote, name), 0o600);
  }
  privateFile(
    join(receipt, "files"),
    "complete.age\nconfigs.tar.gz.age\nmanifest.txt.age\n",
  );
  privateFile(
    join(receipt, "complete.sha256"),
    `${createHash("sha256")
      .update(readFileSync(join(remote, "complete.age")))
      .digest("hex")}\n`,
  );
  return { remote, local, receipt };
};
const unchangedFailure = (
  f: Fixture,
  failure: string,
  extra: Record<string, string> = {},
) => {
  const before = lastProof(f);
  const offsite = readFileSync(join(f.state, "offsite-enabled"));
  const old = oldCopy(f);
  const oldLocal = readFileSync(join(old.local, "COMPLETE"));
  const oldRemote = readdirSync(old.remote).map((name) => ({
    name,
    contents: readFileSync(join(old.remote, name)),
  }));
  const receipts = readdirSync(join(f.state, "receipts"));
  const previous = snapshots(f);
  privateFile(f.trace, "");
  const result = run(f, "backup", [f.job], {
    FAKE_FAIL: failure,
    OLD_NAME: oldName,
    ...extra,
  });
  assert.notEqual(result.status, 0, `The planted ${failure} failure passed.`);
  assert.equal(
    lastProof(f),
    before,
    `The ${failure} failure changed last-success.`,
  );
  assert.deepEqual(readFileSync(join(f.state, "offsite-enabled")), offsite);
  assert.deepEqual(readdirSync(join(f.state, "receipts")), receipts);
  assert.deepEqual(readFileSync(join(old.local, "COMPLETE")), oldLocal);
  assert.deepEqual(
    readdirSync(old.remote),
    oldRemote.map(({ name }) => name),
  );
  for (const { name, contents } of oldRemote)
    assert.deepEqual(readFileSync(join(old.remote, name)), contents);
  const failed = snapshots(f).filter((name) => !previous.includes(name));
  assert.equal(failed.length, 1);
  const snapshot = failed[0] ?? "";
  assert(existsSync(join(f.archive, snapshot, "INCOMPLETE")));
  assert(!existsSync(join(f.archive, snapshot, "COMPLETE")));
  assert(!trace(f).includes("rclone deletefile"));
  return { snapshot, old };
};
const redisFields = (f: Fixture, docker = false) =>
  `REDIS_CONFIG=${quote(f.redisConfig)}\nREDIS_RDB=${quote(docker ? "/data/dump.rdb" : f.rdb)}\nREDIS_WAIT_SECONDS=1\n${docker ? "REDIS_CONTAINER=cache\n" : ""}`;
const hostConfig = (f: Fixture) => {
  const file = join(f.dir, "host.conf");
  privateFile(
    file,
    `HEARTBEAT_START_URL='https://monitor.example.com/Test-only-secret-start'\nHEARTBEAT_FAIL_URL='https://monitor.example.com/Test-only-secret-fail'\nHEARTBEAT_SUCCESS_URL='https://monitor.example.com/Test-only-secret-success'\nBACKUP_STATE_DIRS=(${quote(f.state)})\nBACKUP_MAX_AGE_SECONDS=(3600)\n`,
  );
  return file;
};

try {
  {
    const f = fixture();
    const result = spawnSync(
      "bash",
      ["-c", 'source "$1"', "source-check", join(root, "jobs/lib.sh")],
      { env: environment(f), encoding: "utf8" },
    );
    assert.equal(result.status, 0);
    assert.equal(result.stdout + result.stderr, "");
    assert.equal(trace(f), "", "Sourcing lib.sh made a request.");
  }
  {
    const f = fixture();
    privateFile(f.job, `${f.text}\nprintf '%s' Test-only-secret-do-not-log\n`);
    backupOK(f);
  }
  {
    const f = fixture();
    privateFile(
      f.job,
      `${f.text}\nprintf '%s' Test-only-secret-do-not-log\nreturn 1\n`,
    );
    assert.notEqual(run(f).status, 0);
    assert.equal(trace(f), "", "A failed configuration started a command.");
  }
  for (const damage of [
    "",
    "directory",
    "mode",
    "special-mode",
    "symlink",
    "hardlink",
    "owner",
    "parent",
    "publication",
  ]) {
    const f = fixture();
    const destination = join(f.dir, "last-success");
    const old = "old private proof\n";
    const replacement = "new private proof\n";
    privateFile(destination, old);
    if (damage === "directory") {
      rmSync(destination);
      mkdirSync(destination, { mode: 0o700 });
      privateFile(join(destination, "keep"), old);
    }
    if (damage === "mode") chmodSync(destination, 0o644);
    if (damage === "special-mode") chmodSync(destination, 0o1600);
    if (damage === "symlink") {
      rmSync(destination);
      privateFile(join(f.dir, "unowned-proof"), old);
      symlinkSync(join(f.dir, "unowned-proof"), destination);
    }
    if (damage === "hardlink") linkSync(destination, join(f.dir, "keep"));
    if (damage === "parent") chmodSync(f.dir, 0o770);
    const extra: Record<string, string> = {
      ATOMIC_DESTINATION: destination,
      FAKE_FAIL: damage === "publication" ? "atomic-publication" : "",
    };
    if (damage === "owner") {
      const ownerBin = join(f.dir, "owner-bin");
      mkdirSync(ownerBin, { mode: 0o700 });
      const stat = execFileSync("which", ["stat"], { encoding: "utf8" }).trim();
      const wrapper = join(ownerBin, "stat");
      privateFile(
        wrapper,
        `#!/usr/bin/env bash\nif [[ $1 == -c && $2 == %u && \${!#} == ${quote(destination)} ]]; then printf '4294967294\\n'; else exec ${quote(stat)} "$@"; fi\n`,
      );
      chmodSync(wrapper, 0o700);
      extra.PATH = `${ownerBin}:${environment(f).PATH}`;
    }
    const before = lstatSync(destination);
    const result = spawnSync(
      "bash",
      [
        "-c",
        'source "$1"; infra_runtime; infra_atomic "$2"',
        "atomic-check",
        join(root, "jobs/lib.sh"),
        destination,
      ],
      {
        env: environment(f, extra),
        encoding: "utf8",
        input: replacement,
        timeout: 10000,
      },
    );
    assert.equal(result.error, undefined);
    assert.equal(
      result.status === 0,
      !damage,
      `Atomic ${damage || "regular proof"}: ${result.stderr}`,
    );
    if (damage) {
      const after = lstatSync(destination);
      assert.deepEqual(
        [after.ino, after.uid, after.gid, after.mode, after.nlink],
        [before.ino, before.uid, before.gid, before.mode, before.nlink],
      );
    }
    if (damage === "directory") {
      assert.deepEqual(readdirSync(destination), ["keep"]);
      assert.equal(readFileSync(join(destination, "keep"), "utf8"), old);
    } else {
      assert.equal(
        readFileSync(destination, "utf8"),
        damage ? old : replacement,
      );
    }
    assert(
      !readdirSync(f.dir).some((name) => name.startsWith(".infra-state.")),
    );
    if (damage === "publication")
      assert(trace(f).includes(` ${destination}\n`));
    if (!damage) {
      rmSync(destination);
      const created = spawnSync(
        "bash",
        [
          "-c",
          'source "$1"; infra_runtime; infra_atomic "$2"',
          "atomic-check",
          join(root, "jobs/lib.sh"),
          destination,
        ],
        {
          env: environment(f),
          encoding: "utf8",
          input: replacement,
          timeout: 10000,
        },
      );
      assert.equal(created.status, 0, created.stderr);
      assert.equal(readFileSync(destination, "utf8"), replacement);
      assert.equal(
        execFileSync("stat", ["-c", "%a:%h", destination], {
          encoding: "utf8",
        }).trim(),
        "600:1",
      );
    }
  }
  console.log(
    "Atomic controls passed: directories and unsafe targets stay unchanged; new and prior private proofs publish; failed publication keeps the prior proof.",
  );
  for (const inherited of ["environment", "job", "d1-env"]) {
    const f = fixture(inherited === "d1-env" ? "d1" : "supabase-docker");
    const excludes =
      "--exclude=settings.conf --exclude=init.sql --exclude=pgsodium_root.key --exclude=dump.rdb";
    const control = join(f.dir, "omission-control.tar.gz");
    execFileSync("tar", ["-czf", control, "-C", f.container, "."], {
      env: { ...process.env, TAR_OPTIONS: excludes },
    });
    const omitted = execFileSync("tar", ["-tzf", control], {
      encoding: "utf8",
    });
    assert(
      !omitted.includes("pgsodium_root.key") && !omitted.includes("init.sql"),
      "The omission control needs GNU tar with TAR_OPTIONS support.",
    );
    const configured = `\nCONTAINER_CONFIG_PATHS=(/recovery/init.sql '/recovery/key with spaces/pgsodium_root.key')\nSTORAGE_PATHS=(${quote(f.rdb)})\nDUMP_ARGS=('--exclude-table-data=public.events')\n`;
    privateFile(
      f.job,
      `${f.text}${configured}${inherited === "job" ? `export TAR_OPTIONS=${quote(excludes)}\n` : ""}`,
    );
    if (inherited === "d1-env")
      privateFile(
        f.d1Env,
        `${readFileSync(f.d1Env, "utf8")}\nexport TAR_OPTIONS=${quote(excludes)}\n`,
      );
    const snapshot = backupOK(
      f,
      inherited === "environment" ? { TAR_OPTIONS: excludes } : {},
    );
    for (const [artifact, required] of [
      [
        "configs",
        inherited === "d1-env"
          ? [f.source.slice(1)]
          : [f.source.slice(1), f.init.slice(1), f.pgsodium.slice(1)],
      ],
      ["storage", [f.rdb.slice(1)]],
      [
        "container-configs",
        ["./recovery/init.sql", "./recovery/key with spaces/pgsodium_root.key"],
      ],
    ] as const) {
      const recovered = execFileSync(realAge, [
        "-d",
        "-i",
        identity,
        join(f.remote, "test/nightly", snapshot, `${artifact}.tar.gz.age`),
      ]);
      const paths = execFileSync("tar", ["-tzf", "-"], {
        input: recovered,
        encoding: "utf8",
      })
        .trimEnd()
        .split("\n");
      for (const path of required)
        assert(
          paths.includes(path),
          `Inherited ${inherited} TAR_OPTIONS omitted ${path} from the recovered ${artifact} archive.`,
        );
    }
    if (inherited !== "d1-env")
      assert(
        trace(f).includes("--exclude-table-data=public.events"),
        "Clearing tar options changed deliberate dump exclusions.",
      );
  }
  console.log(
    "Tar controls passed: inherited environment, job and D1 config exclusions cannot omit selected host, storage or container recovery files.",
  );
  for (const unread of ["archive", "state"] as const) {
    for (const failure of ["", "adoption-read"]) {
      const f = fixture();
      mkdirSync(f.archive, { mode: 0o700 });
      mkdirSync(f.state, { mode: 0o700 });
      const oldProof = `infrakit-snapshot-v1\nnightly\n${oldName}\n1\nbackup:${f.remote}/test/nightly\n`;
      const protectedFiles = [
        [join(f.state, "last-success"), oldProof],
        [join(f.state, "receipts", oldName, "proof"), oldProof],
        [
          join(f.remote, "test/nightly", oldName, "keep.age"),
          "unowned remote bytes\n",
        ],
        ...(unread === "archive"
          ? [[join(f.archive, oldName, "COMPLETE"), oldProof]]
          : []),
      ];
      for (const [path, contents] of protectedFiles) {
        assert(path && contents);
        privateFile(path, contents);
      }
      const result = run(f, "backup", [f.job], {
        FAKE_FAIL: failure,
        UNREAD_DIRECTORY: f[unread],
      });
      assert.notEqual(
        result.status,
        0,
        `A ${failure || "nonempty"} ${unread} directory was adopted.`,
      );
      assert(
        !existsSync(join(f[unread], ".infrakit-owner")),
        "An unread or nonempty directory received an ownership marker.",
      );
      for (const [path, contents] of protectedFiles) {
        assert(path && contents);
        assert.equal(readFileSync(path, "utf8"), contents);
      }
      assert.equal(snapshots(f).length, unread === "archive" ? 1 : 0);
      assert(
        !/^(?:rclone|age|docker|pg_dump|curl) /m.test(trace(f)),
        "A failed adoption started collection, upload or pruning.",
      );
      if (failure)
        assert(
          trace(f).includes(`find ${f[unread]} `),
          "The failed-read control did not run.",
        );
      if (unread === "state")
        assert(
          existsSync(join(f.archive, ".infrakit-owner")),
          "The separately validated empty sibling should still be bound.",
        );
    }
  }
  {
    const f = fixture();
    for (const directory of [f.archive, f.state])
      mkdirSync(directory, { mode: 0o700 });
    backupOK(f);
    assert(
      existsSync(join(f.archive, ".infrakit-owner")) &&
        existsSync(join(f.state, ".infrakit-owner")),
    );
  }
  console.log(
    "Adoption controls passed: empty directories bind; successful nonempty reads and failed reads preserve old archive, state and remote bytes.",
  );
  for (const profile of [
    "files",
    "postgres-docker",
    "supabase-docker",
    "hosted-postgres",
    "d1",
  ]) {
    const f = fixture(profile);
    const snapshot = backupOK(f, {
      FAKE_NOISY: "1",
      PGPASSWORD: "Test-only-secret-unrelated-cron",
    });
    const manifest = execFileSync(
      realAge,
      [
        "-d",
        "-i",
        identity,
        join(f.remote, "test/nightly", snapshot, "manifest.txt.age"),
      ],
      { encoding: "utf8" },
    );
    assert(manifest.includes(`profile=${profile}`));
    assert.equal(
      execFileSync(
        realAge,
        [
          "-d",
          "-i",
          identity,
          join(f.remote, "test/nightly", snapshot, "complete.age"),
        ],
        { encoding: "utf8" },
      ),
      lastProof(f),
      "The verified remote marker does not contain the saved completion proof.",
    );
    const listing = execFileSync(
      "tar",
      ["-tzf", join(f.archive, snapshot, "plain/configs.tar.gz")],
      { encoding: "utf8" },
    );
    assert(
      listing.includes(f.source.slice(1)),
      "Tar lost the source's root-relative shape or spaces.",
    );
    assert(
      readdirSync(join(f.remote, "test/nightly", snapshot)).every((name) =>
        name.endsWith(".age"),
      ),
    );
    if (profile.endsWith("-docker")) {
      assert(trace(f).includes("docker exec -i database pg_restore --list"));
      assert(
        !trace(f)
          .split("\n")
          .some((line) => line.startsWith("pg_restore ")),
        "A Docker dump used the host's PostgreSQL client.",
      );
    }
    if (profile === "supabase-docker") {
      assert(
        listing.includes(f.init.slice(1)) &&
          listing.includes(f.pgsodium.slice(1)),
        "Supabase recovery files were not archived.",
      );
      const sealed = join(
        f.remote,
        "test/nightly",
        snapshot,
        "configs.tar.gz.age",
      );
      const decrypted = execFileSync(realAge, ["-d", "-i", identity, sealed]);
      assert.equal(
        createHash("sha256").update(decrypted).digest("hex"),
        createHash("sha256")
          .update(
            readFileSync(join(f.archive, snapshot, "plain/configs.tar.gz")),
          )
          .digest("hex"),
      );
    }
    if (profile === "d1") {
      assert.equal(
        execFileSync(
          "sqlite3",
          [
            join(f.archive, snapshot, "d1-validation.sqlite"),
            "SELECT id FROM sample",
          ],
          { encoding: "utf8" },
        ).trim(),
        "1",
      );
    }
  }
  {
    const f = fixture("postgres-docker");
    const dockerOnly = join(f.dir, "docker-only-bin");
    mkdirSync(dockerOnly, { mode: 0o700 });
    // A positive control with no pg_dump or pg_restore installed on the host PATH.
    for (const tool of [
      "bash",
      "dirname",
      "cat",
      "stat",
      "date",
      "readlink",
      "mktemp",
      "chmod",
      "mv",
      "curl",
      "age",
      "rclone",
      "flock",
      "sha256sum",
      "tar",
      "gzip",
      "cmp",
      "sort",
      "find",
      "timeout",
      "comm",
      "sed",
      "head",
      "grep",
      "rm",
      "mkdir",
      "cp",
      "wc",
      "tr",
      "docker",
    ]) {
      symlinkSync(
        existsSync(join(bin, tool))
          ? join(bin, tool)
          : execFileSync("which", [tool], { encoding: "utf8" }).trim(),
        join(dockerOnly, tool),
      );
    }
    backupOK(f, { PATH: dockerOnly });
  }
  for (const [failure, lastStep, markerPresent] of [
    ["payload-upload", 0, false],
    ["check", 1, false],
    ["corrupt", 1, false],
    ["payload-list", 2, false],
    ["payload-missing", 2, false],
    ["payload-extra", 2, false],
    ["marker-upload", 3, false],
    ["marker-partial", 3, true],
    ["marker-missing", 4, false],
    ["marker-check", 4, true],
    ["marker-corrupt", 4, true],
    ["final-list", 5, true],
    ["final-extra", 5, true],
  ] as const) {
    const f = fixture();
    backupOK(f);
    const { snapshot, old } = unchangedFailure(f, failure, {
      FAKE_EXTRA: failure === "payload-extra" ? "1" : "",
    });
    const remote = join(f.remote, "test/nightly", snapshot);
    const marker = join(remote, "complete.age");
    if (failure === "payload-upload" && existsSync(marker))
      assert.equal(
        execFileSync(realAge, ["-d", "-i", identity, marker], {
          encoding: "utf8",
        }),
        readFileSync(join(f.archive, snapshot, "proof.txt"), "utf8"),
        "The reproduction did not leave a valid encrypted completion proof.",
      );
    assert.equal(
      existsSync(marker),
      markerPresent,
      `The ${failure} failure left the wrong completion marker state.`,
    );
    const commands = trace(f)
      .split("\n")
      .filter(
        (line) =>
          line.startsWith("rclone ") && line.includes(`backup:${remote}`),
      );
    assert.deepEqual(
      commands.map((line) => line.split(" ")[1]),
      completionSteps.slice(0, lastStep + 1),
      `The ${failure} failure did not stop at the expected completion step.`,
    );
    const partial = readdirSync(remote).map((name) => ({
      name,
      contents: readFileSync(join(remote, name)),
    }));
    privateFile(f.trace, "");
    const retried = backupOK(f);
    assert(
      !existsSync(old.local) && readdirSync(old.remote).length === 0,
      "A fully verified retry did not prune the old copies.",
    );
    const retryCommands = trace(f).split("\n");
    const finalList = retryCommands.lastIndexOf(
      `rclone lsf backup:${join(f.remote, "test/nightly", retried)} --recursive --files-only`,
    );
    assert(
      finalList >= 0 &&
        retryCommands.findIndex((line) =>
          line.startsWith("rclone deletefile"),
        ) > finalList,
      "The retry pruned before the full completion download and exact-set checks.",
    );
    assert(existsSync(join(f.archive, snapshot, "INCOMPLETE")));
    assert(!existsSync(join(f.state, "receipts", snapshot)));
    assert.deepEqual(
      readdirSync(remote),
      partial.map(({ name }) => name),
      "A retry cleaned an unverified remote snapshot.",
    );
    for (const { name, contents } of partial)
      assert.deepEqual(readFileSync(join(remote, name)), contents);
  }
  for (const failure of [
    "dump",
    "empty-dump",
    "invalid-dump",
    "seal",
    "upload",
    "check",
    "corrupt",
    "lsf",
    "collision",
  ]) {
    const f = fixture("hosted-postgres");
    backupOK(f);
    // The collision stand-in chooses the current run from this otherwise empty archive.
    for (const name of snapshots(f))
      rmSync(join(f.archive, name), { recursive: true });
    unchangedFailure(f, failure);
  }
  {
    const f = fixture();
    backupOK(f);
    const old = oldCopy(f);
    const foreign = join(f.remote, "test/nightly", "19990101T000000Z-Other1");
    privateFile(join(foreign, "keep.age"), "not owned by this job");
    backupOK(f);
    assert(
      !existsSync(old.local) && readdirSync(old.remote).length === 0,
      "The positive retention control did not prune.",
    );
    assert(
      existsSync(join(foreign, "keep.age")),
      "Retention adopted a foreign snapshot.",
    );
    const commands = trace(f).split("\n");
    const deletes = commands.filter((line) =>
      line.startsWith("rclone deletefile"),
    );
    assert(
      deletes.at(-1)?.endsWith("/complete.age"),
      "Retention deleted its ownership marker before the data.",
    );
    assert(
      commands.findIndex((line) => line.startsWith("rclone check")) <
        commands.findIndex((line) => line.startsWith("rclone deletefile")),
    );
  }
  for (const failure of [
    "prune-list",
    "unknown-object",
    "marker-changed",
    "partial-prune",
  ]) {
    const f = fixture();
    backupOK(f);
    const old = oldCopy(f);
    if (failure === "unknown-object")
      privateFile(join(old.remote, "foreign.age"), "foreign");
    if (failure === "marker-changed")
      privateFile(join(old.remote, "complete.age"), "different marker");
    const result = run(f, "backup", [f.job], {
      FAKE_FAIL: failure,
      OLD_NAME: oldName,
    });
    assert.notEqual(result.status, 0, `Retention passed ${failure}.`);
    assert(
      existsSync(old.local) && existsSync(join(old.remote, "complete.age")),
    );
    if (failure !== "partial-prune")
      assert(!trace(f).includes("rclone deletefile"));
    else {
      assert(!existsSync(join(old.remote, "configs.tar.gz.age")));
      backupOK(f);
      assert(
        readdirSync(old.remote).length === 0,
        "An interrupted prune could not resume.",
      );
    }
  }
  for (const replacement of [
    "REMOTE_PREFIX=''",
    "REMOTE_PREFIX=../other",
    "REMOTE_PREFIX=test/./nightly",
    "REMOTE_PREFIX='test/*'",
    "BACKUP_AGE_RECIPIENT=''",
    "ARCHIVE_DIR=/",
    "STATE_DIR=/var/backups",
    "BACKEND=r2",
    "unset DB_NAMES; DB_NAMES=scalar",
  ]) {
    const f = fixture();
    const field = replacement.split("=")[0];
    privateFile(f.job, `${f.text}\n${replacement}\n`);
    const result = run(f);
    assert.notEqual(result.status, 0, `Invalid ${field} was accepted.`);
    assert(
      !trace(f).includes("rclone copy") &&
        !trace(f).includes("rclone deletefile"),
    );
  }
  for (const kind of [
    "mode",
    "owner",
    "symlink",
    "hardlink",
    "parent",
    "traversal",
    "missing",
  ]) {
    const f = fixture();
    let path = f.job;
    const extra: Record<string, string> = {};
    if (kind === "mode") chmodSync(path, 0o644);
    if (kind === "owner") {
      // Plant a foreign UID for just the config file; no privileged chown is needed.
      const ownerBin = join(f.dir, "owner-bin");
      mkdirSync(ownerBin, { mode: 0o700 });
      const stat = execFileSync("which", ["stat"], { encoding: "utf8" }).trim();
      const wrapper = join(ownerBin, "stat");
      privateFile(
        wrapper,
        `#!/usr/bin/env bash\nif [[ $1 == -c && $2 == %u && \${!#} == ${quote(f.job)} ]]; then printf '4294967294\\n'; else exec ${quote(stat)} "$@"; fi\n`,
      );
      chmodSync(wrapper, 0o700);
      extra.PATH = `${ownerBin}:${environment(f).PATH}`;
    }
    if (kind === "symlink") {
      path = join(f.dir, "link.conf");
      symlinkSync(f.job, path);
    }
    if (kind === "hardlink") linkSync(f.job, join(f.dir, "second.conf"));
    if (kind === "parent") chmodSync(f.dir, 0o777);
    if (kind === "traversal")
      path = `${f.dir}/../${f.dir.split("/").at(-1)}/job.conf`;
    if (kind === "missing") path = join(f.dir, "missing.conf");
    const result = run(f, "backup", [path], extra);
    assert.notEqual(
      result.status,
      0,
      `Unsafe ${kind} configuration was sourced.`,
    );
    assert.equal(trace(f), "");
  }
  {
    const f = fixture();
    const link = join(f.dir, "linked-source");
    symlinkSync(dirname(f.source), link);
    privateFile(
      f.job,
      `${f.text}\nCONFIG_PATHS=(${quote(join(link, "settings.conf"))})\n`,
    );
    assert.notEqual(
      run(f).status,
      0,
      "A symlinked source parent was accepted.",
    );
    assert(!trace(f).includes("rclone copy"));
  }
  {
    const f = fixture();
    mkdirSync(f.state, { mode: 0o700 });
    privateFile(join(f.state, "foreign-file"), "keep");
    assert.notEqual(
      run(f).status,
      0,
      "A nonempty state directory was adopted.",
    );
    assert(existsSync(join(f.state, "foreign-file")));
  }
  {
    const f = fixture();
    backupOK(f);
    const before = lastProof(f);
    const result = spawnSync(
      "bash",
      [
        "-c",
        'exec 9>"$1"; flock -n 9 || exit; bash "$2" "$3"; result=$?; exit "$result"',
        "lock-holder",
        join(f.state, "job.lock"),
        join(root, "jobs/backup.sh"),
        f.job,
      ],
      { env: environment(f), encoding: "utf8", timeout: 10000 },
    );
    assert.notEqual(result.status, 0);
    assert(result.stderr.includes("already running"));
    assert.equal(lastProof(f), before);
  }
  {
    const f = fixture("supabase-docker");
    const result = run(f, "backup", [f.job], { FAKE_FAIL: "first-dump" });
    assert.notEqual(result.status, 0);
    const snapshot = snapshots(f)[0] ?? "";
    assert(existsSync(join(f.archive, snapshot, "plain/db-002.dump")));
    assert(existsSync(join(f.archive, snapshot, "plain/configs.tar.gz")));
    assert(existsSync(join(f.archive, snapshot, "INCOMPLETE")));
    assert(!trace(f).includes("rclone copy"));
  }
  for (const recovery of ["init", "pgsodium"] as const) {
    const f = fixture("supabase-docker");
    rmSync(f[recovery]);
    const result = run(f);
    assert.notEqual(
      result.status,
      0,
      `Missing Supabase ${recovery} was accepted.`,
    );
    assert(
      existsSync(join(f.archive, snapshots(f)[0] ?? "", "plain/db-002.dump")),
    );
    assert(!trace(f).includes("rclone copy"));
  }
  for (const failure of ["globals", "empty-dump", "invalid-dump"]) {
    const f = fixture("postgres-docker");
    const result = run(f, "backup", [f.job], { FAKE_FAIL: failure });
    assert.notEqual(result.status, 0, `Docker ${failure} was accepted.`);
    assert(
      existsSync(
        join(f.archive, snapshots(f)[0] ?? "", "plain/configs.tar.gz"),
      ),
    );
    assert(!trace(f).includes("rclone copy"));
  }
  for (const failure of [
    "",
    "container-copy",
    "container-missing",
    "container-symlink",
  ]) {
    const f = fixture("supabase-docker");
    privateFile(
      f.job,
      `${f.text}\nCONFIG_PATHS=()\nCONTAINER_CONFIG_PATHS=(/recovery/init.sql '/recovery/key with spaces/pgsodium_root.key')\n`,
    );
    const result = run(f, "backup", [f.job], { FAKE_FAIL: failure });
    if (failure) {
      assert.notEqual(result.status, 0);
      assert(!trace(f).includes("rclone copy"));
      assert(
        existsSync(join(f.archive, snapshots(f)[0] ?? "", "plain/db-001.dump")),
      );
    } else {
      assert.equal(result.status, 0, result.output);
      const listing = execFileSync(
        "tar",
        [
          "-tzf",
          join(
            f.archive,
            snapshots(f)[0] ?? "",
            "plain/container-configs.tar.gz",
          ),
        ],
        { encoding: "utf8" },
      );
      assert(
        listing.includes("./recovery/init.sql") &&
          listing.includes("./recovery/key with spaces/pgsodium_root.key"),
      );
      assert.equal(
        execFileSync(
          "tar",
          [
            "-xzOf",
            join(
              f.archive,
              snapshots(f)[0] ?? "",
              "plain/container-configs.tar.gz",
            ),
            "./recovery/key with spaces/pgsodium_root.key",
          ],
          { encoding: "utf8" },
        ),
        "recovery-key-fixture\n",
      );
    }
  }
  for (const docker of [false, true]) {
    for (const failure of [
      "",
      "stale-redis",
      "redis-error",
      "busy-redis",
      "redis-path",
      "redis-settings",
      "redis-start",
    ]) {
      const f = fixture();
      privateFile(f.job, `${f.text}\n${redisFields(f, docker)}`);
      const result = run(f, "backup", [f.job], { FAKE_FAIL: failure });
      if (failure) {
        assert.notEqual(result.status, 0, `Redis ${failure} passed.`);
        assert(!trace(f).includes("rclone copy"));
        assert(
          !existsSync(
            join(f.archive, snapshots(f)[0] ?? "", "plain/redis.rdb"),
          ),
          "An old RDB was copied.",
        );
      } else {
        assert.equal(result.status, 0, result.output);
        if (docker)
          assert(
            trace(f).includes(
              "docker exec --env REDISCLI_AUTH cache redis-cli",
            ),
          );
        assert(
          existsSync(join(f.archive, snapshots(f)[0] ?? "", "plain/redis.rdb")),
        );
      }
    }
  }
  for (const docker of [false, true]) {
    for (const damage of ["", "missing", "mode", "empty"]) {
      const f = fixture();
      const password = join(f.dir, "redis-password");
      const exactPassword = "Test-only-secret-with spaces'\\quote";
      privateFile(password, exactPassword);
      rmSync(f.redisConfig);
      privateFile(
        f.job,
        `${f.text}\n${redisFields(f, docker)}\nunset REDIS_CONFIG\nCONFIG_PATHS=()\nREDIS_PASSWORD_FILE=${quote(password)}\n`,
      );
      if (damage === "missing") rmSync(password);
      if (damage === "mode") chmodSync(password, 0o644);
      if (damage === "empty") privateFile(password, "");
      const result = run(f, "backup", [f.job], {
        REDIS_EXPECTED_PASSWORD: exactPassword,
      });
      assert.equal(
        result.status === 0,
        !damage,
        `Redis password file ${damage || "without host config"}: ${result.output}`,
      );
      assert.equal(
        existsSync(join(f.archive, snapshots(f)[0] ?? "", "plain/redis.rdb")),
        !damage,
      );
      if (damage) assert(!trace(f).includes("rclone copy"));
    }
  }
  {
    const f = fixture("d1");
    const snapshot = backupOK(f);
    assert(existsSync(join(f.archive, snapshot, "plain/database.sql")));
    assert(
      !existsSync(join(f.archive, snapshot, "plain/database.sql.partial")),
    );
    assert(
      existsSync(join(f.remote, "test/nightly", snapshot, "database.sql.age")),
    );
    const before = lastProof(f);
    const old = oldCopy(f);
    const oldLocal = readFileSync(join(old.local, "COMPLETE"));
    const oldRemote = readdirSync(old.remote).map((name) => ({
      name,
      contents: readFileSync(join(old.remote, name)),
    }));
    privateFile(f.trace, "");
    rmSync(join(f.dir, "d1-marker"));
    const result = run(f, "backup", [f.job], { FAKE_FAIL: "d1-final-rename" });
    const failed = snapshots(f).filter(
      (name) => name !== snapshot && name !== oldName,
    );
    assert.equal(failed.length, 1);
    const failedRun = join(f.archive, failed[0] ?? "");
    assert(
      trace(f).includes(
        `mv ${failedRun}/plain/database.sql.partial ${failedRun}/plain/database.sql`,
      ),
      "The planted failure did not reach the final SQL rename.",
    );
    assert.notEqual(
      result.status,
      0,
      "D1 passed after its final SQL rename failed.",
    );
    assert(existsSync(join(failedRun, "INCOMPLETE")));
    assert(!existsSync(join(failedRun, "COMPLETE")));
    assert(
      readFileSync(join(failedRun, "plain/database.sql.partial")).length > 0,
    );
    assert(!existsSync(join(failedRun, "plain/database.sql")));
    assert(existsSync(join(failedRun, "plain/configs.tar.gz")));
    assert.equal(lastProof(f), before);
    assert.deepEqual(readFileSync(join(old.local, "COMPLETE")), oldLocal);
    assert.deepEqual(
      readdirSync(old.remote),
      oldRemote.map(({ name }) => name),
    );
    for (const { name, contents } of oldRemote)
      assert.deepEqual(readFileSync(join(old.remote, name)), contents);
    assert(!trace(f).includes("rclone copy"));
    assert(!trace(f).includes("rclone deletefile"));
  }
  for (const failure of [
    "d1-host",
    "d1-sql",
    "d1-empty-sql",
    "d1-shell",
    "d1-attach",
    "d1-api",
    "d1-timeout",
    "d1-json",
    "d1-null-errors",
    "d1-object-errors",
    "d1-missing-errors",
    "d1-array-result",
    "d1-null-status",
    "d1-false-status",
    "d1-unknown-status",
    "d1-false-success",
    "d1-wrong-type",
    "d1-invalid-bookmark",
    "d1-invalid-url",
  ]) {
    const f = fixture("d1");
    assert.notEqual(
      run(f, "backup", [f.job], { FAKE_FAIL: failure }).status,
      0,
      `D1 ${failure} passed.`,
    );
    assert(!trace(f).includes("rclone copy"));
    assert(
      !existsSync(join(f.dir, "sql-escape.db")),
      "D1 SQL wrote outside its isolated scratch database.",
    );
    assert(
      existsSync(
        join(f.archive, snapshots(f)[0] ?? "", "plain/configs.tar.gz"),
      ),
    );
  }
  {
    const f = fixture("d1");
    const snapshot = backupOK(f, {
      FAKE_D1_OPTIONAL_SUCCESS: "1",
      FAKE_D1_MULTILINE_SQL: "1",
    });
    assert.equal(
      execFileSync(
        "sqlite3",
        [
          join(f.archive, snapshot, "d1-validation.sqlite"),
          "SELECT value FROM sample",
        ],
        { encoding: "utf8" },
      ).trim(),
      "first line\n.quit\nlast line",
    );
  }
  {
    const f = fixture();
    const mail = join(f.dir, "alert.conf");
    privateFile(
      mail,
      `SMTP_HOST=smtp.example.com\nSMTP_USER=login\nSMTP_PASS='Test-only-secret-do-not-log\\"quoted'\nSMTP_FROM=ops@example.com\nSMTP_TO=(one@example.com two@example.com)\n`,
    );
    const ok = run(
      f,
      "alert",
      ["--test", "Backup check"],
      { ALERT_CONFIG: mail, FAKE_NOISY: "1" },
      "Check the setup.\n",
    );
    assert.equal(ok.status, 0, ok.output);
    assert(
      readFileSync(`${f.capture}.message`, "utf8").includes(
        "To: one@example.com, two@example.com\r\nSubject: [Setup test] Backup check",
      ),
    );
    assert.notEqual(
      run(
        f,
        "alert",
        ["Backup check"],
        { ALERT_CONFIG: mail, FAKE_FAIL: "curl" },
        "body",
      ).status,
      0,
    );
    assert.notEqual(
      run(f, "alert", ["Backup check"], { ALERT_CONFIG: "" }).status,
      0,
    );
    assert.notEqual(
      run(f, "alert", ["subject\r\nBcc: attacker@example.com"], {
        ALERT_CONFIG: mail,
      }).status,
      0,
    );
    privateFile(f.job, `${f.text}\nALERT_CONFIG=${quote(mail)}\n`);
    const failure = run(f, "backup", [f.job], {
      FAKE_FAIL: "upload",
      FAKE_ALERT_FAIL: "1",
    });
    assert.notEqual(failure.status, 0);
    assert(existsSync(`${f.capture}.message`));
    assert(
      failure.output.includes("Request failed"),
      "The failed alert was hidden from the operator.",
    );
  }
  {
    const f = fixture();
    backupOK(f);
    const before = lastProof(f);
    const old = oldCopy(f);
    const file = hostConfig(f);
    privateFile(f.job, `${f.text}\nHEARTBEAT_CONFIG=${quote(file)}\n`);
    const result = run(f, "backup", [f.job], { FAKE_FAIL: "curl" });
    assert.notEqual(
      result.status,
      0,
      "A failed configured heartbeat reported a clean job.",
    );
    assert.notEqual(
      lastProof(f),
      before,
      "The verified backup lost its valid proof on a monitor failure.",
    );
    assert(
      existsSync(old.local) && existsSync(join(old.remote, "complete.age")),
    );
    assert(
      !trace(f).includes("rclone deletefile"),
      "Retention ran during a monitor outage.",
    );
  }
  for (const damage of [
    "",
    "stale",
    "future",
    "receipt",
    "owner",
    "offsite",
    "truncated",
    "unsafe-mode",
  ]) {
    const f = fixture();
    backupOK(f);
    const file = hostConfig(f);
    const proof = lastProof(f).trimEnd().split("\n");
    const snapshot = proof[2] ?? "";
    if (damage === "stale" || damage === "future") {
      proof[3] = String(
        Math.floor(Date.now() / 1000) + (damage === "future" ? 1000 : -7200),
      );
      privateFile(join(f.state, "last-success"), `${proof.join("\n")}\n`);
      copyFileSync(
        join(f.state, "last-success"),
        join(f.state, "receipts", snapshot, "proof"),
      );
    }
    if (damage === "receipt")
      privateFile(
        join(f.state, "receipts", snapshot, "proof"),
        "different proof\n",
      );
    if (damage === "owner")
      privateFile(join(f.state, ".infrakit-owner"), "different owner\n");
    if (damage === "offsite") rmSync(join(f.state, "offsite-enabled"));
    if (damage === "truncated")
      privateFile(join(f.state, "last-success"), "infrakit-snapshot-v1\n");
    if (damage === "unsafe-mode")
      chmodSync(join(f.state, "last-success"), 0o644);
    const result = run(f, "heartbeat", [file]);
    assert.equal(
      result.status === 0,
      !damage,
      `Host heartbeat accepted ${damage || "valid proof"}: ${result.output}`,
    );
    const capture = readFileSync(f.capture, "utf8");
    assert(
      capture.includes(
        damage ? "Test-only-secret-fail" : "Test-only-secret-success",
      ),
    );
    assert(!damage || !capture.includes("Test-only-secret-success"));
  }
  {
    const f = fixture();
    const missing = join(f.dir, "heartbeat.conf");
    privateFile(missing, "# Not configured\n");
    assert.notEqual(run(f, "heartbeat", [missing]).status, 0);
    assert.equal(trace(f), "");
    const file = hostConfig(f);
    assert.equal(run(f, "heartbeat", [file, "start"]).status, 0);
    assert.equal(run(f, "heartbeat", [file, "fail"]).status, 0);
    assert.notEqual(
      run(f, "heartbeat", [file], { FAKE_FAIL: "curl" }).status,
      0,
    );
    assert.notEqual(
      run(f, "heartbeat", [file, "start"], { FAKE_FAIL: "redirect" }).status,
      0,
      "A redirected ping was reported as sent.",
    );
  }
  for (const backend of ["r2", "s3"]) {
    const f = fixture();
    const remoteFile = join(f.dir, "remote.conf");
    privateFile(
      remoteFile,
      backend === "r2"
        ? "R2_ACCOUNT_ID=0123456789abcdef0123456789abcdef\nR2_ACCESS_KEY_ID=test-key\nR2_SECRET_ACCESS_KEY=Test-only-secret-do-not-log\nR2_BUCKET=test-bucket\n"
        : "S3_PROVIDER=AWS\nS3_REGION=sa-east-1\nS3_ACCESS_KEY_ID=test-key\nS3_SECRET_ACCESS_KEY=Test-only-secret-do-not-log\nS3_BUCKET=test-bucket\n",
    );
    privateFile(
      f.job,
      `${f.text}\nBACKEND=${backend}\nS3_ENV=${quote(remoteFile)}\n`,
    );
    const extra = { FAKE_S3_ROOT: join(f.dir, "fake-s3") };
    const result = run(f, "backup", [f.job], extra);
    assert.equal(result.status, 0, result.output);
    const before = lastProof(f);
    privateFile(
      remoteFile,
      readFileSync(remoteFile, "utf8") +
        "\nS3_PROVIDER=Other\nS3_REGION=auto\nS3_ENDPOINT=https://different.example.com\nS3_ACCESS_KEY_ID=key\nS3_SECRET_ACCESS_KEY=secret\nS3_BUCKET=test-bucket\n",
    );
    const switched = run(f, "backup", [f.job], extra);
    assert.notEqual(
      switched.status,
      0,
      "A different endpoint with the same bucket reused old state.",
    );
    assert.equal(lastProof(f), before);
  }
  console.log(
    `Contracts passed: ${count} isolated fixtures, all profiles, failure controls and retention ordering.`,
  );
} finally {
  rmSync(work, { recursive: true, force: true });
}
