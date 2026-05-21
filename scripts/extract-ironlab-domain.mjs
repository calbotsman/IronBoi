#!/usr/bin/env node
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import vm from "node:vm";

const root = resolve(new URL("..", import.meta.url).pathname);
const appPath = resolve(root, "src/App.jsx");
const outPath = resolve(root, "functions/src/domain/ironlab-seed.json");
const source = await readFile(appPath, "utf8");

const names = [
  "MUSCLE_GROUPS",
  "EXERCISE_LIBRARY",
  "SWAP_OPTIONS",
  "EXERCISE_DB",
  "PHILOSOPHY",
  "DEFAULT_PLAN",
  "DAILY_HABITS",
];

function extractLiteral(name) {
  const needle = `const ${name}`;
  const start = source.indexOf(needle);
  if (start === -1) throw new Error(`Missing ${name}`);
  const equals = source.indexOf("=", start);
  const first = source.slice(equals + 1).search(/[\[{]/);
  if (first === -1) throw new Error(`Missing literal start for ${name}`);

  const literalStart = equals + 1 + first;
  const opener = source[literalStart];
  const closer = opener === "{" ? "}" : "]";
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  for (let i = literalStart; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];

    if (lineComment) {
      if (ch === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (ch === "*" && next === "/") {
        blockComment = false;
        i += 1;
      }
      continue;
    }
    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === quote) {
        quote = null;
      }
      continue;
    }
    if (ch === "/" && next === "/") {
      lineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      blockComment = true;
      i += 1;
      continue;
    }
    if (ch === "\"" || ch === "'" || ch === "`") {
      quote = ch;
      continue;
    }
    if (ch === opener) depth += 1;
    if (ch === closer) {
      depth -= 1;
      if (depth === 0) return source.slice(literalStart, i + 1);
    }
  }

  throw new Error(`Could not close literal for ${name}`);
}

const seed = {};
for (const name of names) {
  const literal = extractLiteral(name);
  seed[name] = vm.runInNewContext(`(${literal})`);
}

await mkdir(dirname(outPath), { recursive: true });
await writeFile(outPath, `${JSON.stringify(seed, null, 2)}\n`);
console.log(`Wrote ${outPath}`);
