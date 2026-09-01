import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = mkdtempSync(join(tmpdir(), "gegenlesen-fs-"));
process.env.GEGENLESEN_WORKSPACE = root;

const { resolveUnderWorkspace, readWorkspaceTextFile, writeWorkspaceTextFile } = await import(
  "../lib/workspace-fs.mjs"
);

writeWorkspaceTextFile("sample.txt", "alpha\nbeta\ngamma\n");
assert.equal(readFileSync(join(root, "sample.txt"), "utf8"), "alpha\nbeta\ngamma\n");
assert.deepEqual(readWorkspaceTextFile("sample.txt", 2, 2), { content: "beta\ngamma" });

assert.throws(() => resolveUnderWorkspace("/etc/passwd"), /outside workspace/);

rmSync(root, { recursive: true, force: true });
console.log("workspace-fs.test.mjs: ok");
