/**
 * Synthetic print fixtures: tiny but real PDF/PNG bytes (distinct hashes),
 * and a seeded two-job order shaped like spec §8 P1 (copies 2 and 7,
 * different instructions, Unicode file name).
 */
import type { PrintApiMemory } from '../../src/adapters/print-api.memory.js';
import type { Order } from '../../src/domain/print-order.js';

export const PDF_BYTES = new TextEncoder().encode(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n',
);

export const PNG_BYTES = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

export function seedTwoFileOrder(api: PrintApiMemory, title?: string): Order {
  return api.seedOrder({
    ...(title ? { title } : {}),
    jobs: [
      {
        title: 'Apostila de Matemática',
        copies: 2,
        instructions: 'Frente e verso, grampeado',
        file: { name: 'matematica.pdf', mime: 'application/pdf', bytes: PDF_BYTES },
      },
      {
        title: 'Lista de Física',
        copies: 7,
        instructions: 'Só frente, colorido',
        file: { name: 'física final.png', mime: 'image/png', bytes: PNG_BYTES },
      },
    ],
  });
}
