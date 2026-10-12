import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const workflow = readFileSync(
  new URL("../.github/workflows/ci.yml", import.meta.url),
  "utf8",
);
const types = /^on:\n {2}pull_request:\n {4}types: \[([^\]]+)\]$/m.exec(
  workflow,
);
assert(
  types,
  "CI needs explicit pull-request events, including ready_for_review.",
);
assert.deepEqual(types[1]?.split(/,\s*/), [
  "opened",
  "synchronize",
  "reopened",
  "ready_for_review",
]);
console.log(
  "CI trigger check passed: default PR events and ready_for_review are enabled.",
);
