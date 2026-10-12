import { isIP } from "node:net";
import { absolutePath, readSafeFile } from "./files.js";

export interface Disk {
  path: string;
  maxUsedPercent: number;
  maxInodePercent: number;
  minFreeBytes: number;
}
export interface Inventory {
  docker: {
    containers: string[];
    maxLogBytes: number;
    maxLogFiles: number;
    maxReclaimableBytes: number;
  } | null;
  pm2: {
    unit: string;
    pidFile: string;
    logsPath: string;
    after: string[];
    minStopSeconds: number;
    maxRotationAgeSeconds: number;
  }[];
  envFiles: string[];
  backups: {
    name: string;
    statePath: string;
    archivePath: string;
    remoteRoot: string;
    ownerUid: number;
    maxAgeSeconds: number;
  }[];
  certificates: {
    name: string;
    kind: "caddy" | "postgres";
    path: string;
    container?: string;
    minValidDays: number;
  }[];
  redis: {
    name: string;
    port: number;
    authFile?: string;
    maxUsedPercent: number;
  }[];
  mail: {
    configPath: string;
    testProofPath: string;
    maxAgeSeconds: number;
  } | null;
}
export interface Manifest {
  version: 1;
  host: string;
  port: number;
  sudo: boolean;
  disks: Disk[];
  maxJournalBytes: number;
  sshd?: {
    user: string;
    clientAddress: string;
    clientHost: string;
    permitRootLogin: "no" | "prohibit-password";
  };
  inventory?: Inventory;
  install?: {
    packageVersion: string;
    prefix: string;
    jobs: {
      name: string;
      configPath: string;
      user: string;
      schedule: string;
    }[];
  };
}

const invalid = () =>
  new Error(
    "The manifest has an invalid or unknown field. Follow the version 1 schema and retry.",
  );
function record(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw invalid();
  const result: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (!keys.includes(key)) throw invalid();
    result[key] = item;
  }
  return result;
}
function text(value: unknown, pattern: RegExp): string {
  if (
    typeof value !== "string" ||
    /[\p{Cc}\p{Cf}]/u.test(value) ||
    !pattern.test(value)
  )
    throw invalid();
  return value;
}
function integer(
  value: unknown,
  fallback: number,
  min = 1,
  max = Number.MAX_SAFE_INTEGER,
): number {
  if (value === undefined) return fallback;
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < min ||
    value > max
  )
    throw invalid();
  return value;
}
function list<T>(value: unknown, parse: (item: unknown) => T): T[] {
  if (!Array.isArray(value) || value.length > 100) throw invalid();
  return value.map(parse);
}
const name = (value: unknown) =>
  text(value, /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$/);
const user = (value: unknown) => text(value, /^[a-z_][a-z0-9_-]{0,31}$/);
const unit = (value: unknown) =>
  text(value, /^[A-Za-z0-9_][A-Za-z0-9_.@-]{0,100}\.service$/);
export function host(value: unknown): string {
  const result = text(
    value,
    /^(?:[a-z_][a-z0-9_-]{0,31}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/,
  );
  if (
    result.endsWith(".") ||
    result.includes("..") ||
    result
      .split("@")
      .at(-1)
      ?.split(".")
      .some(
        (part) =>
          part.length > 63 || part.startsWith("-") || part.endsWith("-"),
      )
  )
    throw invalid();
  return result;
}
function cron(value: unknown): string {
  const result = text(value, /^[0-9*,/ -]+$/);
  const fields = result.split(" ");
  if (fields.length !== 5) throw invalid();
  const bounds = [
    [0, 59],
    [0, 23],
    [1, 31],
    [1, 12],
    [0, 7],
  ] as const;
  fields.forEach((field, index) => {
    const bound = bounds[index];
    if (!bound) throw invalid();
    for (const part of field.split(",")) {
      const match = /^(\*|\d+(?:-\d+)?)(?:\/(\d+))?$/.exec(part);
      if (!match?.[1]) throw invalid();
      if (match[2] && (Number(match[2]) < 1 || Number(match[2]) > bound[1]))
        throw invalid();
      if (match[1] === "*") continue;
      const [start, end = start] = match[1].split("-").map(Number);
      if (
        start === undefined ||
        end === undefined ||
        start < bound[0] ||
        end > bound[1] ||
        start > end
      )
        throw invalid();
    }
  });
  return result;
}
function inventory(value: unknown): Inventory {
  const input = record(value, [
    "docker",
    "pm2",
    "envFiles",
    "backups",
    "certificates",
    "redis",
    "mail",
  ]);
  let docker: Inventory["docker"] = null;
  if (input.docker !== null) {
    const item = record(input.docker, [
      "containers",
      "maxLogBytes",
      "maxLogFiles",
      "maxReclaimableBytes",
    ]);
    docker = {
      containers: list(item.containers, name),
      maxLogBytes: integer(item.maxLogBytes, 10 * 1024 ** 2),
      maxLogFiles: integer(item.maxLogFiles, 5, 1, 1000),
      maxReclaimableBytes: integer(item.maxReclaimableBytes, 5 * 1024 ** 3),
    };
  }
  let mail: Inventory["mail"] = null;
  if (input.mail !== null) {
    const item = record(input.mail, [
      "configPath",
      "testProofPath",
      "maxAgeSeconds",
    ]);
    mail = {
      configPath: absolutePath(item.configPath),
      testProofPath: absolutePath(item.testProofPath),
      maxAgeSeconds: integer(item.maxAgeSeconds, 30 * 86400),
    };
  }
  return {
    docker,
    pm2: list(input.pm2, (value) => {
      const item = record(value, [
        "unit",
        "pidFile",
        "logsPath",
        "after",
        "minStopSeconds",
        "maxRotationAgeSeconds",
      ]);
      return {
        unit: unit(item.unit),
        pidFile: absolutePath(item.pidFile),
        logsPath: absolutePath(item.logsPath),
        after: list(item.after, unit),
        minStopSeconds: integer(item.minStopSeconds, 120),
        maxRotationAgeSeconds: integer(item.maxRotationAgeSeconds, 7 * 86400),
      };
    }),
    envFiles: list(input.envFiles, (value) => absolutePath(value)),
    backups: list(input.backups, (value) => {
      const item = record(value, [
        "name",
        "statePath",
        "archivePath",
        "remoteRoot",
        "ownerUid",
        "maxAgeSeconds",
      ]);
      const jobName = name(item.name);
      const remoteRoot = text(
        item.remoteRoot,
        /^[A-Za-z0-9_][A-Za-z0-9_-]*:[A-Za-z0-9_][A-Za-z0-9_./-]{0,4095}$/,
      );
      if (
        jobName.includes("..") ||
        remoteRoot.includes("..") ||
        remoteRoot.endsWith("/") ||
        remoteRoot.includes("//") ||
        remoteRoot.split("/").includes(".")
      )
        throw invalid();
      return {
        name: jobName,
        statePath: absolutePath(item.statePath),
        archivePath: absolutePath(item.archivePath),
        remoteRoot,
        ownerUid: integer(item.ownerUid, 0, 0, 4294967294),
        maxAgeSeconds: integer(item.maxAgeSeconds, 36 * 3600),
      };
    }),
    certificates: list(input.certificates, (value) => {
      const item = record(value, [
        "name",
        "kind",
        "path",
        "container",
        "minValidDays",
      ]);
      const kind = item.kind;
      if (kind !== "caddy" && kind !== "postgres") throw invalid();
      return {
        name: name(item.name),
        kind,
        path: absolutePath(item.path),
        ...(item.container === undefined
          ? {}
          : { container: name(item.container) }),
        minValidDays: integer(item.minValidDays, 30, 1, 3650),
      };
    }),
    redis: list(input.redis, (value) => {
      const item = record(value, [
        "name",
        "port",
        "authFile",
        "maxUsedPercent",
      ]);
      return {
        name: name(item.name),
        port: integer(item.port, 6379, 1, 65535),
        ...(item.authFile === undefined
          ? {}
          : { authFile: absolutePath(item.authFile) }),
        maxUsedPercent: integer(item.maxUsedPercent, 90, 1, 100),
      };
    }),
    mail,
  };
}
export function parseManifest(value: unknown): Manifest {
  const input = record(value, [
    "version",
    "host",
    "port",
    "sudo",
    "disks",
    "maxJournalBytes",
    "sshd",
    "inventory",
    "install",
  ]);
  if (
    input.version !== 1 ||
    (input.sudo !== undefined && typeof input.sudo !== "boolean")
  )
    throw invalid();
  const result: Manifest = {
    version: 1,
    host: host(input.host),
    port: integer(input.port, 22, 1, 65535),
    sudo: input.sudo ?? false,
    disks:
      input.disks === undefined
        ? [
            {
              path: "/",
              maxUsedPercent: 90,
              maxInodePercent: 90,
              minFreeBytes: 1024 ** 3,
            },
          ]
        : list(input.disks, (value) => {
            const item = record(value, [
              "path",
              "maxUsedPercent",
              "maxInodePercent",
              "minFreeBytes",
            ]);
            return {
              path: absolutePath(item.path, true),
              maxUsedPercent: integer(item.maxUsedPercent, 90, 1, 100),
              maxInodePercent: integer(item.maxInodePercent, 90, 1, 100),
              minFreeBytes: integer(item.minFreeBytes, 1024 ** 3, 0),
            };
          }),
    maxJournalBytes: integer(input.maxJournalBytes, 1024 ** 3),
  };
  if (result.disks.length === 0) throw invalid();
  if (input.sshd !== undefined) {
    const item = record(input.sshd, [
      "user",
      "clientAddress",
      "clientHost",
      "permitRootLogin",
    ]);
    const permitRootLogin =
      item.permitRootLogin === undefined ? "no" : item.permitRootLogin;
    if (permitRootLogin !== "no" && permitRootLogin !== "prohibit-password")
      throw invalid();
    result.sshd = {
      user: user(item.user),
      clientAddress: text(item.clientAddress, /^[0-9a-fA-F:.]{1,45}$/),
      clientHost: host(item.clientHost),
      permitRootLogin,
    };
    if (
      result.sshd.clientHost.includes("@") ||
      isIP(result.sshd.clientAddress) === 0
    )
      throw invalid();
  }
  if (input.inventory !== undefined)
    result.inventory = inventory(input.inventory);
  if (input.install !== undefined) {
    const item = record(input.install, ["packageVersion", "prefix", "jobs"]);
    result.install = {
      packageVersion: text(item.packageVersion, /^\d+\.\d+\.\d+$/),
      prefix: absolutePath(item.prefix),
      jobs: list(item.jobs, (value) => {
        const job = record(value, ["name", "configPath", "user", "schedule"]);
        return {
          name: text(job.name, /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/),
          configPath: absolutePath(job.configPath),
          user: user(job.user),
          schedule: cron(job.schedule),
        };
      }),
    };
    const names = result.install.jobs.map((job) => job.name);
    if (new Set(names).size !== names.length || names.length === 0)
      throw invalid();
  }
  return result;
}

export async function loadManifest(path: string): Promise<Manifest> {
  let contents: string;
  try {
    contents = (await readSafeFile(path, { privateFile: true })).text;
  } catch {
    throw new Error(
      "The manifest could not be read safely. Use an absolute path to your 0600 file, without symlinks or writable parents, then retry.",
    );
  }
  let value: unknown;
  try {
    value = JSON.parse(contents);
  } catch {
    throw new Error(
      "The manifest is not valid JSON. Fix its syntax and retry; its contents were not printed.",
    );
  }
  return parseManifest(value);
}
