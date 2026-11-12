// Generates Packy app icon candidates with Runway's text-to-image API.
// Run it yourself: it uses your RUNWAYML_API_SECRET and spends credits on your Runway project.
//   cd ios && node scripts/generate-icon.mjs
// Optional: RUNWAY_MODEL=gemini_image3_pro (default), RUNWAY_COUNT=4
// Output: ios/icon-candidates/packy-icon-1.png ... (not committed)

import { mkdir, writeFile } from 'node:fs/promises';

const key = process.env.RUNWAYML_API_SECRET;
if (!key) {
  console.error('RUNWAYML_API_SECRET is not set. Add it to your shell profile, open a new terminal, and run again.');
  process.exit(1);
}

const API = 'https://api.dev.runwayml.com';
const headers = { authorization: `Bearer ${key}`, 'X-Runway-Version': '2024-11-06', 'content-type': 'application/json' };
const model = process.env.RUNWAY_MODEL || 'gemini_image3_pro';
const count = Number(process.env.RUNWAY_COUNT || 4);

const promptText = [
  'A modern iOS app icon for "Packy", an app for packing orders into boxes.',
  'Centered subject: a single cardboard shipping box with its top flaps slightly open, soft 3D render, smooth matte materials, gentle rounded edges,',
  'rendered in white and pale blue tones, lit softly from the top left with a subtle shadow below.',
  'Background: full-bleed smooth gradient from royal blue #3B4BDB to a lighter blue #6B7BFF, no texture.',
  'Bold, simple, readable at small sizes, in the style of current Apple app icons.',
  'Square image, edge to edge, no rounded corners, no border, no text, no letters, no logos, no watermark.',
].join(' ');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, path, body) {
  const res = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${res.status} ${json.error || json.message || JSON.stringify(json)}`);
  return json;
}

async function generateOne() {
  const { id } = await api('POST', '/v1/text_to_image', { model, promptText, ratio: '1024:1024' });
  console.log(`task ${id} started`);
  for (;;) {
    await sleep(5000);
    const task = await api('GET', `/v1/tasks/${id}`);
    if (task.status === 'SUCCEEDED') return task;
    if (task.status === 'FAILED' || task.status === 'CANCELLED') {
      throw new Error(`task ${id} ${task.status}: ${task.failureCode ?? ''} ${task.failure ?? ''}`.trim());
    }
  }
}

await mkdir(new URL('../icon-candidates/', import.meta.url), { recursive: true });
let n = 0;
let credits = 0;
for (let i = 0; i < count; i++) {
  try {
    const task = await generateOne();
    credits += task.cost?.credits ?? 0;
    for (const url of task.output ?? []) {
      const img = Buffer.from(await (await fetch(url)).arrayBuffer());
      n += 1;
      const file = new URL(`../icon-candidates/packy-icon-${n}.png`, import.meta.url);
      await writeFile(file, img);
      console.log(`saved ${file.pathname}`);
    }
  } catch (error) {
    console.error(`generation ${i + 1} failed: ${error.message}`);
    console.error('Stopping so nothing is charged twice. Check the task in your Runway Dev dashboard.');
    break;
  }
}
console.log(`${n} image(s) saved with ${model}${credits ? `, ${credits} credits used` : ''}.`);
