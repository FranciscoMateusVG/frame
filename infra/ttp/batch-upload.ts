import type { Context } from 'hono';
import type { Upload } from './batch-runtime.js';
import { BatchError } from './batch-state.js';

const maxFile = 5 * 1024 * 1024;
const maxBody = maxFile + 512 * 1024;
function reject(status: number, code: string): never {
  throw new BatchError(status, code);
}
function magic(bytes: Buffer) {
  if (bytes.subarray(0, 5).equals(Buffer.from('%PDF-'))) return 'application/pdf';
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)
    return 'image/jpeg';
  if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])))
    return 'image/png';
  if (
    bytes.length >= 12 &&
    bytes.toString('ascii', 0, 4) === 'RIFF' &&
    bytes.toString('ascii', 8, 12) === 'WEBP'
  )
    return 'image/webp';
  return null;
}
async function readBounded(c: Context) {
  if (Number(c.req.header('content-length')) > maxBody) reject(413, 'FILE_TOO_LARGE');
  const reader = c.req.raw.body?.getReader();
  if (!reader) reject(400, 'INVALID_REQUEST');
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > maxBody) {
        await reader.cancel();
        reject(413, 'FILE_TOO_LARGE');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks);
}
export async function multipart(
  c: Context,
  field: 'amountCents' | 'declaredTotalCents',
): Promise<{ upload: Upload; amount: number }> {
  const contentType = c.req.header('content-type') ?? '';
  if (!contentType.toLowerCase().startsWith('multipart/form-data;')) reject(400, 'INVALID_REQUEST');
  const bytes = await readBounded(c);
  let data: FormData;
  try {
    data = await new Response(bytes, {
      headers: { 'Content-Type': contentType },
    }).formData();
  } catch {
    return reject(400, 'INVALID_REQUEST');
  }
  return parseFields(data, field);
}
async function parseFields(
  data: FormData,
  field: string,
): Promise<{ upload: Upload; amount: number }> {
  if (
    [...data.keys()].length !== 2 ||
    data.getAll('file').length !== 1 ||
    data.getAll(field).length !== 1
  )
    reject(400, 'INVALID_REQUEST');
  const file = data.get('file');
  const raw = data.get(field);
  if (!(file instanceof File) || typeof raw !== 'string' || !/^[1-9]\d*$/.test(raw))
    reject(400, 'INVALID_REQUEST');
  const amount = Number(raw);
  if (!Number.isSafeInteger(amount) || amount > 2147483647) reject(400, 'INVALID_REQUEST');
  if (!file.size) reject(400, 'INVALID_REQUEST');
  if (file.size > maxFile) reject(413, 'FILE_TOO_LARGE');
  const bytes = Buffer.from(await file.arrayBuffer());
  const detected = magic(bytes);
  if (!detected || detected !== file.type.toLowerCase()) reject(415, 'UNSUPPORTED_MEDIA_TYPE');
  // Approved fake deviation: images retained verbatim, not transcoded. Hash STORED bytes.
  const name =
    [...file.name]
      .map((ch) =>
        ch.charCodeAt(0) < 32 || ch.charCodeAt(0) === 127 || ch === '/' || ch === '\\' ? '_' : ch,
      )
      .join('')
      .slice(0, 160) || 'document';
  return { upload: { bytes, mime: detected, name }, amount };
}
