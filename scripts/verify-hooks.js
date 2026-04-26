import { accessSync, constants, existsSync } from 'node:fs';
import { join } from 'node:path';
import { exit } from 'node:process';

const hooksDir = join(import.meta.dirname, '..', '.husky');
const requiredHooks = ['pre-commit', 'pre-push'];
let failed = false;

for (const hook of requiredHooks) {
  const hookPath = join(hooksDir, hook);
  if (!existsSync(hookPath)) {
    console.error(`❌ Missing git hook: .husky/${hook}`);
    failed = true;
    continue;
  }
  try {
    accessSync(hookPath, constants.R_OK);
    console.log(`✅ Hook exists: .husky/${hook}`);
  } catch {
    console.error(`❌ Hook not readable: .husky/${hook}`);
    failed = true;
  }
}

if (failed) {
  console.error('\n🚨 Git hooks are misconfigured. Run: pnpm prepare');
  exit(1);
} else {
  console.log('\n✅ All git hooks verified.');
}
