// Replay the fixture's explicit expected pairing, NOT a replacement for Hono's pairing policy.
import type { BatchItem } from './batch-state.js';
import { type ContractFreeze, sha256 } from './contract-freeze.js';
import type pairingType from './contracts/print-portal-v2.legacy-pairing.fixture.json';

const normalized = (s: string) => s.normalize('NFC').trim();
function invariant(ok: unknown): asserts ok {
  if (!ok) throw new Error('PAIRING_FIXTURE_INVALID');
}
function uuid(input: string) {
  const h = sha256(input);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
export function pairingCases(freeze: ContractFreeze) {
  return (freeze.pairing as typeof pairingType).cases;
}
export function pairingSeedItem(freeze: ContractFreeze, name: string): BatchItem {
  const c = pairingCases(freeze).find((c) => c.name === name);
  invariant(c);
  const item = structuredClone(freeze.fixture.batches[0].items[0]);
  invariant(item);
  const matchedBlocks = new Set<number>();
  item.jobs = c.expectedPairs.map((pair) => {
    const blocks = c.metadata.printJobs
      .map((b, index) => ({ b, index }))
      .filter(({ b }) => normalized(b.fileTitle) === pair.title);
    invariant(blocks.length === 1);
    const block = blocks[0];
    invariant(block);
    const file = c.files.find((file) => file.id === pair.fileId);
    invariant(file);
    matchedBlocks.add(block.index);
    return {
      id: uuid(`ttp-pairing/${name}/${file.id}`),
      title: pair.title,
      copies: Number(block.b.copies),
      instructions: block.b.printInstructions,
      file: structuredClone(file),
    };
  });
  const residualBlocks = c.metadata.printJobs.filter((_, i) => !matchedBlocks.has(i));
  invariant(
    JSON.stringify(residualBlocks.map((b) => normalized(b.fileTitle))) ===
      JSON.stringify(c.expectedResidualTitles),
  );
  const residualFiles = c.expectedResidualFileIds.map((id) => {
    const f = c.files.find((f) => f.id === id);
    invariant(f);
    return structuredClone(f);
  });
  const text = [c.details, ...residualBlocks.map((b) => JSON.stringify(b))]
    .filter(Boolean)
    .join('\n');
  delete item.generalInstructions;
  if (text || residualFiles.length) item.generalInstructions = { text, files: residualFiles };
  const exposed = [...item.jobs.map((j) => j.file.id), ...residualFiles.map((f) => f.id)];
  invariant(exposed.length === c.files.length && new Set(exposed).size === exposed.length);
  freeze.validate('BatchItem', item);
  return item;
}
