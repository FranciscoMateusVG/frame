/**
 * Accepted document types for quotes and invoices (PDF/JPEG/PNG/WebP),
 * identified by their magic bytes — the same sniffing the upstream does.
 * Upstream refuses a part whose declared type differs from its content.
 */
export const DOCUMENT_MIME_TYPES = [
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
] as const;

export type DocumentMime = (typeof DOCUMENT_MIME_TYPES)[number];

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function ascii(bytes: Uint8Array, start: number, end: number): string {
  return String.fromCharCode(...bytes.subarray(start, end));
}

/** The document type of `bytes`, or null when it is none of the accepted ones. */
export function sniffDocumentMime(bytes: Uint8Array): DocumentMime | null {
  if (ascii(bytes, 0, 5) === '%PDF-') return 'application/pdf';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 8 && PNG_SIGNATURE.every((b, i) => bytes[i] === b)) return 'image/png';
  if (ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP') return 'image/webp';
  return null;
}
