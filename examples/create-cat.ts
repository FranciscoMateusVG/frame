/**
 * Example: Create a Cat using the Postgres adapter.
 *
 * Fully self-contained — uses Testcontainers to spin up a Postgres instance.
 * No external dependencies required beyond Docker.
 *
 * Usage: pnpm tsx examples/create-cat.ts
 */
import { randomUUID } from 'node:crypto';
import { CatRepositoryPostgres } from '../src/adapters/cat-repository.postgres.js';
import { createCat } from '../src/use-cases/create-cat.js';
import { createTestDatabase } from '../tests/helpers/test-db.js';

console.log('🐱 Frame Example: Create a Cat');
console.log('================================');
console.log('');

const { db, teardown } = await createTestDatabase();

try {
  const catRepository = new CatRepositoryPostgres(db);
  const deps = { catRepository };

  // Create a cat
  const cat = await createCat(deps, {
    id: randomUUID(),
    name: 'Whiskers',
  });
  console.log('✅ Created cat:', cat);

  // Fetch it back
  const fetched = await catRepository.findById(cat.id);
  console.log('✅ Fetched cat:', fetched);

  // Delete it
  const deleted = await catRepository.deleteById(cat.id);
  console.log('✅ Deleted cat:', deleted);

  // Verify deletion
  const afterDelete = await catRepository.findById(cat.id);
  console.log('✅ After delete (should be undefined):', afterDelete);

  console.log('');
  console.log('🎉 Example completed successfully!');
} finally {
  await teardown();
}
