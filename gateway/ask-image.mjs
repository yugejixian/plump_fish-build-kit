// Ask the local model about an image file, through the gateway's auto-attach.
//   node ask-image.mjs <image-path> [question]
const GW = 'http://127.0.0.1:8099';
const file = process.argv[2];
const question = process.argv[3] ?? '描述这张图片的内容。';

if (!file) {
  console.error('usage: node ask-image.mjs <image-path> [question]');
  process.exit(1);
}

const t0 = Date.now();
const res = await fetch(`${GW}/v1/chat/completions`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    model: 'qwen2.5-omni-3b',
    messages: [{ role: 'user', content: `${question}\n\n图片：${file}` }],
    max_tokens: 300,
    temperature: 0,
  }),
});
const j = await res.json();
console.log(`[${res.status}] ${Date.now() - t0}ms  prompt_tokens=${j.usage?.prompt_tokens ?? 0}`);
console.log(j.choices?.[0]?.message?.content ?? JSON.stringify(j.error));
