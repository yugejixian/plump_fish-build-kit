import { spawnSync } from 'node:child_process';

// Self-check for the DSH local GGUF gateway. Run:
//   node selftest.mjs            (or the full node path, see README)
// It never prints model output; it only reports latency and state.

const GW = 'http://127.0.0.1:8099';
const IMAGE = 'D:\\DSH-LocalLLM\\dsh-local-llm\\test-image.png';

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

function vram() {
  const r = spawnSync('nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader', {
    encoding: 'utf8',
    shell: true,
  });
  return r.status === 0 ? r.stdout.trim() : 'nvidia-smi unavailable';
}

async function json(url, init) {
  const res = await fetch(url, init);
  return { res, body: await res.json().catch(() => null) };
}

async function chat(content, maxTokens = 80) {
  const t0 = Date.now();
  const { res, body } = await json(`${GW}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'qwen2.5-omni-3b', messages: [{ role: 'user', content }], max_tokens: maxTokens, temperature: 0 }),
  });
  return { status: res.status, ms: Date.now() - t0, body };
}

// 1. gateway reachable, model deliberately unloaded
let status;
try {
  const { res, body } = await json(`${GW}/gateway/status`);
  status = body;
  check('gateway reachable', res.ok, `model route ${body?.model?.id}`);
} catch (error) {
  check('gateway reachable', false, `start it with gateway-control.cmd start (${error.message})`);
  process.exit(1);
}

// Start from a clean slate so the cold-start check below is meaningful.
if (status.upstream.running) {
  await json(`${GW}/gateway/unload`, { method: 'POST' });
  await new Promise((r) => setTimeout(r, 1200));
  status = (await json(`${GW}/gateway/status`)).body;
}

// 2. browsing the catalogue must not load weights
const before = vram();
const t0 = Date.now();
const models = await json(`${GW}/v1/models`);
check('catalogue served without loading the model', models.res.ok && !status.upstream.running,
  `${Date.now() - t0}ms, upstream.running=${status.upstream.running}`);
console.log(`      vram before any inference: ${before}`);

// 3. cold text inference (this is what starts llama-server)
const cold = await chat('用中文一句话解释什么是递归。');
check('cold text request', cold.status === 200 && !!cold.body?.choices?.[0]?.message?.content,
  `${cold.ms}ms, ${cold.body?.usage?.completion_tokens ?? 0} tokens out`);
const afterLoad = await json(`${GW}/gateway/status`);
check('llama-server now running', afterLoad.body?.upstream?.running === true, `pid ${afterLoad.body?.upstream?.pid}`);
console.log(`      vram with model loaded: ${vram()}`);

// 4. warm text inference
const warm = await chat('用中文一句话解释什么是哈希表。');
check('warm text request', warm.status === 200, `${warm.ms}ms`);

// 5. vision through automatic image attachment
const vision = await chat(`描述这张图：${IMAGE}`, 120);
const promptTokens = vision.body?.usage?.prompt_tokens ?? 0;
check('vision request with auto-attached image', vision.status === 200 && promptTokens > 300,
  `${vision.ms}ms, prompt ${promptTokens} tokens`);

// 6. streaming
const tStream = Date.now();
const res = await fetch(`${GW}/v1/chat/completions`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'qwen2.5-omni-3b', messages: [{ role: 'user', content: 'Count 1 to 3.' }], max_tokens: 20, stream: true }),
});
const reader = res.body.getReader();
let firstByte = 0;
let bytes = 0;
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  if (!firstByte) firstByte = Date.now() - tStream;
  bytes += value?.length ?? 0;
}
check('streaming pass-through', res.headers.get('content-type')?.includes('event-stream') && bytes > 0,
  `first byte ${firstByte}ms, ${bytes} bytes`);

// 7. unload releases VRAM
await json(`${GW}/gateway/unload`, { method: 'POST' });
await new Promise((r) => setTimeout(r, 1500));
const afterUnload = await json(`${GW}/gateway/status`);
check('unload stops llama-server', afterUnload.body?.upstream?.running === false, '');
console.log(`      vram after unload: ${vram()}`);

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
console.log(`idle auto-unload after ${Math.round((status.lifecycle?.idleTimeoutMs ?? 0) / 1000)}s; change lifecycle.idleTimeoutMs in config.json`);
process.exitCode = failed === 0 ? 0 : 1;
