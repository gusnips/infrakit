import { createHash } from "node:crypto";
import { mkdir, open, rename, rm, rmdir } from "node:fs/promises";
import { join } from "node:path";
import { absolutePath, readSafeFile } from "./files.js";

// npm pm2-logrotate@3.0.0 app.js, not a fuzzy parser-fragment match.
export const logrotateSourceHashes = {
  original: "00a399ea13cdc1b3326d26389adafeaca3e03f321a5531bd684ef362fb0ce5b7",
  fixed: "4be0f6657ed09bd62cc2639e284136d0d5a08851b1e293db765dababc00f5950",
};
const originalParser = `const parseBool = (str, defaultVal = false) => {
  if (str === 'true') return true;
  if (str === 'false') return false;
  return defaultVal;
};`;
const fixedParser = `const parseBool = (str, defaultVal = false) => {
  if (str === true || str === 'true') return true;
  if (str === false || str === 'false') return false;
  return defaultVal;
};`;
const digest = (text: string) =>
  createHash("sha256").update(text).digest("hex");

async function installedSource(directory: string) {
  const metadata: unknown = JSON.parse(
    (await readSafeFile(join(directory, "package.json"))).text,
  );
  if (
    !metadata ||
    typeof metadata !== "object" ||
    !("name" in metadata) ||
    metadata.name !== "pm2-logrotate" ||
    !("version" in metadata) ||
    metadata.version !== "3.0.0"
  )
    throw new Error(
      "This patch supports only pm2-logrotate 3.0.0. Inspect the installed version and source before adding support; nothing changed.",
    );
  const source = await readSafeFile(join(directory, "app.js"));
  const hash = digest(source.text);
  const state =
    hash === logrotateSourceHashes.original
      ? "original"
      : hash === logrotateSourceHashes.fixed
        ? "fixed"
        : null;
  if (state === null)
    throw new Error(
      "The installed app.js does not match the reviewed original or fixed source. Inspect its changes; do not force this patch. Nothing changed.",
    );
  return { ...source, state };
}

export async function patchPm2Logrotate(
  directory: string,
  apply = false,
  rollback = false,
) {
  absolutePath(directory);
  const target = rollback ? "original" : "fixed";
  let source = await installedSource(directory);
  const result = {
    module: "pm2-logrotate@3.0.0",
    action: rollback ? "rollback" : "patch",
    state: source.state,
    changed: false,
    requiredReloads: [
      "After a source change, the process owner must restart only pm2-logrotate in its existing PM2_HOME. No app or PM2 daemon restart is needed. Source state does not prove the running module reloaded.",
    ],
  };
  if (!apply || source.state === target) return result;
  if (source.info.uid !== process.getuid?.())
    throw new Error(
      "The module belongs to another user. Run the patch as its process owner with the existing PM2_HOME; nothing changed.",
    );

  // One source-file transaction only. No PM2 calls and no app configuration changes.
  const lock = join(directory, ".infrakit-logrotate.lock");
  try {
    await mkdir(lock, { mode: 0o700 });
  } catch {
    throw new Error(
      "The source patch lock could not be created. Check directory access and whether another patch is running; remove a stale lock only after checking it.",
    );
  }
  try {
    source = await installedSource(directory);
    if (source.state === target) return { ...result, state: target };
    const next = source.text.replace(
      rollback ? fixedParser : originalParser,
      rollback ? originalParser : fixedParser,
    );
    if (digest(next) !== logrotateSourceHashes[target])
      throw new Error(
        "The parser replacement did not match its expected source. Inspect the module; nothing changed.",
      );
    const temporary = join(lock, "app.js");
    const file = await open(temporary, "wx", 0o600);
    try {
      await file.writeFile(next, "utf8");
      await file.chown(source.info.uid, source.info.gid);
      await file.chmod(source.info.mode & 0o7777);
      await file.sync();
    } finally {
      await file.close();
    }
    const current = await installedSource(directory);
    if (
      current.text !== source.text ||
      (
        [
          "dev",
          "ino",
          "mode",
          "uid",
          "gid",
          "nlink",
          "mtimeMs",
          "ctimeMs",
        ] as const
      ).some((key) => current.info[key] !== source.info[key])
    )
      throw new Error(
        "The module changed while the patch was being prepared. Inspect the new source, then retry; this command did not replace it.",
      );
    await rename(temporary, join(directory, "app.js"));
    return { ...result, state: target, changed: true };
  } finally {
    await rm(join(lock, "app.js"), { force: true });
    await rmdir(lock);
  }
}
