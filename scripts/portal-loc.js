// Lines of code of the print-shop portal only (the Cat example excluded),
// for the TS / Rust / Elixir benchmark. Counts non-blank lines and total
// lines per group. Usage: node scripts/portal-loc.js
import { readdirSync, readFileSync } from 'node:fs';

const PORTAL = {
  src: [
    /^src\/domain\/(money|monthly-close|portal-session|print-batch)\.ts$/,
    /^src\/adapters\/(print-api|session-store|login-throttle)[.a-z-]*\.ts$/,
    /^src\/errors\/(csrf-failed|invalid-credentials|invalid-request|login-rate-limited|unauthenticated|upstream-[a-z]+)\.error\.ts$/,
    /^src\/use-cases\/(?!create-cat)[a-z-]+\.ts$/,
    /^src\/http\/[a-z-]+\.ts$/,
  ],
  tests: [
    /^tests\/(unit|integration)\/(portal|print)[a-z.-]*\.test\.ts$/,
    /^tests\/helpers\/(fake-print-upstream|print-[a-z.-]+|portal-harness)\.ts$/,
  ],
  other: [
    /^examples\/print-portal\.hono\.ts$/,
    /^scripts\/(smoke-portal-bundle|portal-loc)\.js$/,
    /^tsup\.portal\.config\.ts$/,
  ],
};

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const path = dir === '.' ? e.name : `${dir}/${e.name}`;
    if (e.isDirectory())
      return /^(node_modules|dist|dist-portal|coverage|\.git)$/.test(e.name) ? [] : walk(path);
    return [path];
  });
}

const files = walk('.');
let grand = 0;
for (const [group, patterns] of Object.entries(PORTAL)) {
  const matched = files.filter((f) => patterns.some((p) => p.test(f))).sort();
  let total = 0;
  let code = 0;
  for (const f of matched) {
    const lines = readFileSync(f, 'utf8').split('\n');
    total += lines.length;
    code += lines.filter((l) => l.trim() !== '').length;
  }
  grand += code;
  console.log(
    `${group.padEnd(6)} files=${String(matched.length).padStart(3)}  lines=${String(total).padStart(6)}  non-blank=${String(code).padStart(6)}`,
  );
}
console.log(`total non-blank: ${grand}`);
