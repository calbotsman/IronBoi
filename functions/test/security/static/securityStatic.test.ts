import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const srcRoot = path.resolve(process.cwd(), "src");

function walk(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(fullPath);
    return entry.isFile() && fullPath.endsWith(".ts") ? [fullPath] : [];
  });
}

function filesUnder(...segments: string[]) {
  return walk(path.join(srcRoot, ...segments));
}

describe("agent static security guards", () => {
  it("no_collectionGroup_in_coach", () => {
    const matches = filesUnder("coach").filter((file) =>
      fs.readFileSync(file, "utf8").includes("collectionGroup("),
    );
    expect(matches).toEqual([]);
  });

  it("no_collectionGroup_in_tools", () => {
    const matches = filesUnder("tools").filter((file) =>
      fs.readFileSync(file, "utf8").includes("collectionGroup("),
    );
    expect(matches).toEqual([]);
  });

  it("no_collectionGroup_in_agents", () => {
    const matches = filesUnder("agents").filter((file) =>
      fs.readFileSync(file, "utf8").includes("collectionGroup("),
    );
    expect(matches).toEqual([]);
  });

  it("console_log_banned_in_agent_paths", () => {
    const banned = /\bconsole\.(log|warn|error)\s*\(|\blogger\.(debug|info|warn|error)\s*\(/;
    const matches = ["coach", "tools", "agents"]
      .flatMap((segment) => filesUnder(segment))
      .filter((file) => banned.test(fs.readFileSync(file, "utf8")));
    expect(matches).toEqual([]);
  });

  it("tool_handlers_must_not_read_args_userId", () => {
    const matches = filesUnder("tools", "handlers").filter((file) =>
      /\bargs\.userId\b/.test(fs.readFileSync(file, "utf8")),
    );
    expect(matches).toEqual([]);
  });
});
