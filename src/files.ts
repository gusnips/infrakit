import { constants, type Stats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname } from "node:path";

export function absolutePath(value: unknown, allowRoot = false): string {
  if (
    typeof value !== "string" ||
    !value.startsWith("/") ||
    value.length > 4096 ||
    /[\p{Cc}\p{Cf}]/u.test(value) ||
    (!(allowRoot && value === "/") &&
      value
        .split("/")
        .slice(1)
        .some((part) => !part || part === "." || part === ".."))
  )
    throw new Error(
      "A path is not a clean absolute path. Remove relative segments, repeated slashes and control characters, then retry.",
    );
  return value;
}

// Shared local trust boundary. Private configs are read as data, never executed.
export async function readSafeFile(
  path: string,
  { privateFile = false, metadataOnly = false } = {},
): Promise<{ text: string; info: Stats }> {
  absolutePath(path);
  const uid = process.getuid?.();
  if (uid === undefined)
    throw new Error(
      "File ownership could not be checked. Run this command on Linux or macOS.",
    );
  for (let cursor = path; ; cursor = dirname(cursor)) {
    const info = await lstat(cursor);
    if (
      info.isSymbolicLink() ||
      (cursor === path ? !info.isFile() : !info.isDirectory()) ||
      (info.uid !== 0 && info.uid !== uid) ||
      (info.mode & 0o022) !== 0
    )
      throw new Error(
        "A file path has an unsafe owner, writable parent, symlink or wrong file type. Use a regular file in directories owned by you or root, without group or other write access.",
      );
    if (cursor === "/") break;
  }
  // Reject special leaves before open; nonblocking open also covers a raced-in FIFO.
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const info = await file.stat();
    if (
      !info.isFile() ||
      info.nlink !== 1 ||
      info.size > 1024 * 1024 ||
      (info.uid !== 0 && info.uid !== uid) ||
      (info.mode & 0o022) !== 0 ||
      (privateFile && (info.mode & 0o7777) !== 0o600)
    )
      throw new Error(
        "A file must have one link, at most 1 MB and no group or other write access. Private files need exact mode 0600 with no special bits. Fix its owner and mode, then retry.",
      );
    return { text: metadataOnly ? "" : await file.readFile("utf8"), info };
  } finally {
    await file.close();
  }
}
