// Stand-ins for contracts.ts only. integration.sh uses real local tools.
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const [tool, ...args] = process.argv.slice(2);
const env = process.env;
const trace = env.TRACE;
if (!trace) throw new Error("TRACE is missing from the test fixture.");
appendFileSync(trace, `${tool} ${args.join(" ")}\n`);
const secret = "Test-only-secret-do-not-log";
function fail(message = secret): never {
  console.error(message);
  process.exit(1);
}
const files = (path: string, prefix = ""): string[] =>
  !existsSync(path)
    ? []
    : readdirSync(path, { withFileTypes: true }).flatMap((entry) =>
        entry.isDirectory()
          ? files(join(path, entry.name), `${prefix}${entry.name}/`)
          : [`${prefix}${entry.name}`],
      );
const remote = (value: string | undefined) => {
  if (!value) throw new Error("Missing fake remote path.");
  if (value.startsWith("backup:")) {
    const rest = value.slice("backup:".length);
    if (rest.startsWith("/")) return rest;
    if (env.FAKE_S3_ROOT) return join(env.FAKE_S3_ROOT, rest);
  }
  throw new Error("The fake requires the isolated local or fake S3 backend.");
};
const hash = (file: string) =>
  createHash("sha256").update(readFileSync(file)).digest("hex");
const last = args.at(-1) ?? "";
const redis = () => {
  if (
    args.some(
      (arg) =>
        arg.includes("Test-only-secret") || arg === "-a" || arg === "SAVE",
    )
  )
    fail("Redis credentials or blocking SAVE reached argv.");
  if (env.REDISCLI_AUTH !== (env.REDIS_EXPECTED_PASSWORD ?? secret))
    fail("Redis did not receive REDISCLI_AUTH.");
  const marker = env.REDIS_MARKER ?? "";
  const saves = existsSync(marker) ? Number(readFileSync(marker, "utf8")) : 10;
  if (args.includes("CONFIG")) {
    if (args.slice(-4).join(" ") !== "CONFIG GET dir dbfilename")
      fail("Redis requested unexpected configuration.");
    if (env.FAKE_FAIL === "redis-settings") fail();
    const rdb = args.includes("cache") ? "/data/dump.rdb" : env.TEST_REDIS_RDB;
    if (!rdb) fail("The fake Redis has no snapshot path.");
    console.log(
      `dir\n${env.FAKE_FAIL === "redis-path" ? "/different/path" : dirname(rdb)}\ndbfilename\ndump.rdb`,
    );
  } else if (args.includes("BGSAVE")) {
    if (env.FAKE_FAIL === "redis-start") {
      console.log("ERR snapshot failed");
      return;
    }
    writeFileSync(
      marker,
      String(env.FAKE_FAIL === "stale-redis" ? saves : saves + 1),
    );
    console.log("Background saving started");
  } else if (args.includes("INFO")) {
    console.log(
      `rdb_saves:${saves}\nrdb_bgsave_in_progress:${env.FAKE_FAIL === "busy-redis" ? 1 : 0}\nrdb_last_bgsave_status:${env.FAKE_FAIL === "redis-error" && existsSync(marker) ? "err" : "ok"}`,
    );
  } else fail("Unknown fake Redis command.");
};
const field = (config: string, name: string): string => {
  const match = new RegExp(`^${name} = "(.*)"$`, "m").exec(config);
  if (!match?.[1]) fail(`Missing curl field ${name}.`);
  const value: unknown = JSON.parse(`"${match[1]}"`);
  if (typeof value !== "string") fail("Invalid curl field.");
  return value;
};

switch (tool) {
  case "rclone": {
    const command = args[0];
    if (
      env.FAKE_FAIL === command ||
      (env.FAKE_FAIL === "upload" && command === "copy")
    )
      fail();
    const exclude = args.includes("--exclude")
      ? args[args.indexOf("--exclude") + 1]
      : undefined;
    if (args.includes("--exclude") && exclude !== "/complete.age")
      fail("The fake only supports excluding the root completion marker.");
    switch (command) {
      case "version":
        console.log(env.FAKE_VERSION ?? "rclone v1.75.2");
        break;
      case "mkdir":
        mkdirSync(remote(args[1]), { recursive: true, mode: 0o700 });
        break;
      case "copy": {
        const from = args[1] ?? "";
        const to = remote(args[2]);
        mkdirSync(to, { recursive: true, mode: 0o700 });
        const selected = files(from).filter((file) => `/${file}` !== exclude);
        if (env.FAKE_FAIL === "payload-upload") {
          // Reproduce a marker transferred before the first payload transfer fails.
          if (selected.includes("complete.age"))
            copyFileSync(join(from, "complete.age"), join(to, "complete.age"));
          fail();
        }
        for (const file of selected) {
          mkdirSync(dirname(join(to, file)), { recursive: true, mode: 0o700 });
          copyFileSync(join(from, file), join(to, file));
        }
        if (env.FAKE_EXTRA) writeFileSync(join(to, "unowned.age"), "unowned");
        if (env.FAKE_FAIL === "corrupt")
          writeFileSync(join(to, "manifest.txt.age"), "corrupt");
        if (env.FAKE_NOISY) console.log(secret);
        break;
      }
      case "copyto": {
        const from = args[1] ?? "";
        const to = remote(args[2]);
        if (
          !from.endsWith("/sealed/complete.age") ||
          !to.endsWith("/complete.age")
        )
          fail("Only the completion marker may use copyto.");
        if (env.FAKE_FAIL === "marker-upload") fail();
        if (env.FAKE_FAIL === "marker-missing") break;
        mkdirSync(dirname(to), { recursive: true, mode: 0o700 });
        copyFileSync(from, to);
        if (env.FAKE_FAIL === "marker-partial") fail();
        if (env.FAKE_FAIL === "marker-corrupt") writeFileSync(to, "corrupt");
        if (env.FAKE_FAIL === "final-extra")
          writeFileSync(join(dirname(to), "unowned.age"), "unowned");
        if (env.FAKE_NOISY) console.log(secret);
        break;
      }
      case "check": {
        const from = args[1] ?? "";
        const to = remote(args[2]);
        if (!args.includes("--download") || !args.includes("--one-way"))
          fail("The check must download each object.");
        if (env.FAKE_FAIL === "marker-check" && exclude === undefined) fail();
        for (const file of files(from).filter((file) => `/${file}` !== exclude))
          if (
            !existsSync(join(to, file)) ||
            hash(join(from, file)) !== hash(join(to, file))
          )
            fail();
        if (env.FAKE_FAIL === "payload-missing" && exclude !== undefined)
          rmSync(join(to, "manifest.txt.age"));
        if (env.FAKE_NOISY) console.log(secret);
        break;
      }
      case "lsf": {
        const path = remote(args[1]);
        if (env.FAKE_FAIL === "prune-list" && path.endsWith(`/${env.OLD_NAME}`))
          fail();
        if (args.includes("--dirs-only")) {
          const found = existsSync(path)
            ? readdirSync(path, { withFileTypes: true })
                .filter((entry) => entry.isDirectory())
                .map((entry) => `${entry.name}/`)
            : [];
          if (env.FAKE_FAIL === "collision") {
            const name = readdirSync(env.TEST_ARCHIVE ?? "")
              .filter((entry) => /^\d{8}T\d{6}Z-/.test(entry))
              .sort()
              .at(-1);
            if (!name) fail("The collision fixture has no snapshot.");
            found.push(`${name}/`);
          }
          if (found.length) console.log(found.sort().join("\n"));
        } else {
          const marker = existsSync(join(path, "complete.age"));
          if (
            (env.FAKE_FAIL === "payload-list" && !marker) ||
            (env.FAKE_FAIL === "final-list" && marker)
          )
            fail();
          const found = files(path);
          if (found.length) console.log(found.sort().join("\n"));
        }
        break;
      }
      case "cat":
        process.stdout.write(readFileSync(remote(args[1])));
        break;
      case "deletefile": {
        const target = remote(args[1]);
        if (
          env.FAKE_FAIL === "partial-prune" &&
          target.endsWith("/manifest.txt.age")
        )
          fail();
        rmSync(target);
        break;
      }
      default:
        fail(`Unknown fake rclone command: ${command}`);
    }
    break;
  }
  case "pg_dump":
    if (env.FAKE_FAIL === "dump") fail();
    if (env.FAKE_FAIL !== "empty-dump") console.log("PGDMP\nfixture");
    break;
  case "pg_restore":
    if (
      env.FAKE_FAIL === "invalid-dump" ||
      !readFileSync(last, "utf8").startsWith("PGDMP")
    )
      fail();
    console.log("Archive list");
    break;
  case "docker":
    if (args.includes("redis-cli")) {
      if (
        args[0] !== "exec" ||
        args[1] !== "--env" ||
        args[2] !== "REDISCLI_AUTH"
      )
        fail(
          "Docker Redis did not inherit its password without an argv value.",
        );
      redis();
    } else if (args.includes("pg_restore")) {
      if (args[0] !== "exec" || args[1] !== "-i" || last !== "--list")
        fail("Docker must validate the dump using pg_restore through stdin.");
      if (
        env.FAKE_FAIL === "invalid-dump" ||
        !readFileSync(0, "utf8").startsWith("PGDMP")
      )
        fail();
      console.log("Archive list");
    } else if (args.includes("pg_dumpall")) {
      if (env.FAKE_FAIL === "globals") fail();
      console.log(
        "-- PostgreSQL database cluster dump\n-- PostgreSQL database cluster dump complete",
      );
    } else if (args.includes("pg_dump")) {
      if (
        env.FAKE_FAIL === "dump" ||
        (env.FAKE_FAIL === "first-dump" && last === "postgres")
      )
        fail();
      if (env.FAKE_FAIL !== "empty-dump") console.log("PGDMP\nfixture");
    } else if (args.includes("readlink")) {
      console.log(
        env.FAKE_FAIL === "container-symlink" ? "/different/path" : last,
      );
    } else if (args.includes("test")) {
      if (env.FAKE_FAIL === "container-missing") fail();
    } else if (args[0] === "cp") {
      if (env.FAKE_FAIL === "container-copy") fail();
      const source = args[1]?.split(":")[1];
      if (!source || !env.CONTAINER_ROOT) fail("Missing fake container file.");
      copyFileSync(join(env.CONTAINER_ROOT, source), last);
    } else fail("The Docker profile used an unexpected command.");
    break;
  case "find":
    if (env.FAKE_FAIL === "adoption-read" && args[0] === env.UNREAD_DIRECTORY)
      fail("The fixture directory could not be read.");
    process.stdout.write(execFileSync(env.REAL_FIND ?? "", args));
    break;
  case "mv":
    if (
      env.FAKE_FAIL === "atomic-publication" &&
      last === env.ATOMIC_DESTINATION
    )
      fail("The fixture state could not be published.");
    if (
      env.FAKE_FAIL === "d1-final-rename" &&
      args.length === 2 &&
      args[0]?.endsWith("/plain/database.sql.partial") &&
      last.endsWith("/plain/database.sql")
    )
      fail("D1 final SQL rename failed.");
    execFileSync(env.REAL_MV ?? "", args);
    break;
  case "age":
    if (env.FAKE_FAIL === "seal") fail();
    process.stdout.write(execFileSync(env.REAL_AGE ?? "", args));
    break;
  case "redis-cli":
    redis();
    break;
  case "curl": {
    if (args.length !== 3 || args[0] !== "-q" || args[1] !== "--config")
      fail("curl received a secret or unexpected option in argv.");
    const config = readFileSync(args[2] ?? "", "utf8");
    if (env.CURL_CAPTURE) {
      appendFileSync(env.CURL_CAPTURE, config);
      if (config.includes("upload-file = "))
        writeFileSync(
          `${env.CURL_CAPTURE}.message`,
          readFileSync(field(config, "upload-file")),
        );
    }
    if (
      env.FAKE_FAIL === "curl" ||
      (env.FAKE_ALERT_FAIL && config.includes("smtp://"))
    )
      fail();
    if (config.includes("api.cloudflare.com")) {
      if (!config.includes(`Authorization: Bearer ${secret}`))
        fail("D1 has no private API token.");
      const marker = env.D1_MARKER ?? "";
      if (!existsSync(marker) || env.FAKE_FAIL === "d1-timeout") {
        writeFileSync(marker, "polled");
        const response: Record<string, unknown> = {
          success: true,
          errors: [],
          result: { at_bookmark: "Test-only-secret-bookmark", type: "export" },
        };
        const malformed: Record<string, unknown> = {
          "d1-null-errors": { ...response, errors: null },
          "d1-object-errors": { ...response, errors: {} },
          "d1-missing-errors": { success: true, result: response.result },
          "d1-array-result": { ...response, result: [] },
          "d1-null-status": {
            ...response,
            result: { at_bookmark: "bookmark", status: null },
          },
          "d1-false-status": {
            ...response,
            result: { at_bookmark: "bookmark", status: false },
          },
          "d1-unknown-status": {
            ...response,
            result: { at_bookmark: "bookmark", status: "processing" },
          },
          "d1-false-success": {
            ...response,
            result: { at_bookmark: "bookmark", success: false },
          },
          "d1-wrong-type": {
            ...response,
            result: { at_bookmark: "bookmark", type: "import" },
          },
          "d1-invalid-bookmark": {
            ...response,
            result: { at_bookmark: 42, type: "export" },
          },
        };
        console.log(
          env.FAKE_FAIL === "d1-json"
            ? "not JSON"
            : JSON.stringify(malformed[env.FAKE_FAIL ?? ""] ?? response),
        );
      } else {
        const request = field(config, "data-binary").slice(1);
        if (!readFileSync(request, "utf8").includes("current_bookmark"))
          fail("D1 did not poll using its bookmark.");
        console.log(
          JSON.stringify({
            success: env.FAKE_FAIL !== "d1-api",
            errors: [],
            result: {
              status: "complete",
              type: "export",
              ...(env.FAKE_D1_OPTIONAL_SUCCESS ? {} : { success: true }),
              result: {
                signed_url:
                  env.FAKE_FAIL === "d1-invalid-url"
                    ? null
                    : `https://${env.FAKE_FAIL === "d1-host" ? "not-allowed.example.com" : "test.r2.cloudflarestorage.com"}/export?signature=Test-only-secret-signature`,
              },
            },
          }),
        );
      }
    } else if (config.includes("signature=Test-only-secret-signature")) {
      if (config.includes("Authorization") || config.includes("Bearer"))
        fail("The D1 object download received the API token.");
      const sqlFailures: Record<string, string> = {
        "d1-sql": "CREATE TABLE ;",
        "d1-empty-sql": "",
        "d1-shell": "PRAGMA foreign_keys=OFF;\n.quit\nCREATE TABLE ;",
        "d1-attach": `PRAGMA foreign_keys=OFF;\nATTACH DATABASE '${(env.TEST_D1_ESCAPE ?? "").replaceAll("'", "''")}' AS escaped;`,
      };
      const sql = env.FAKE_D1_MULTILINE_SQL
        ? "CREATE TABLE sample (id INTEGER, value TEXT);\nINSERT INTO sample VALUES (1, 'first line\n.quit\nlast line');\n"
        : "PRAGMA foreign_keys=OFF;\nCREATE TABLE sample (id INTEGER);\nINSERT INTO sample VALUES (1);\n";
      process.stdout.write(sqlFailures[env.FAKE_FAIL ?? ""] ?? sql);
    } else if (config.includes('write-out = "%{http_code}"')) {
      console.log(env.FAKE_FAIL === "redirect" ? "302" : "200");
    } else if (env.FAKE_NOISY) console.log(secret);
    break;
  }
  default:
    fail(`Unknown fake tool: ${tool}`);
}
