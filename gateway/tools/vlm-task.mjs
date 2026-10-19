// One-command bridge to the local model: hand it an instruction (optionally pointing
// at input files and an output path) and print only the receipt.
//
//   node vlm-task.mjs "<instruction>" <output-path>
//   node vlm-task.mjs <prompt-file.txt> <output-path>
//
// The instruction may contain [[file:<path>]] (gateway inlines the file) and the
// output path is appended as [[save:<path>]], so neither the input nor the result
// has to pass through the caller's own output stream.
import fs from 'node:fs';

const [instructionArg, outputPath] = process.argv.slice(2);
if (!instructionArg || !outputPath) {
  console.error('usage: node vlm-task.mjs "<instruction>" <output-path>');
  process.exit(2);
}

const instruction = fs.existsSync(instructionArg) && instructionArg.toLowerCase().endsWith('.txt')
  ? fs.readFileSync(instructionArg, 'utf8')
  : instructionArg;

const prompt = `${instruction.trim()}\n\n[[save:${outputPath}]]`;

const t0 = Date.now();
const res = await fetch('http://127.0.0.1:8099/v1/chat/completions', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    model: 'local-vl',
    messages: [{ role: 'user', content: prompt }],
    max_tokens: 3000,
    temperature: 0,
  }),
});
const json = await res.json();
const text = json.choices?.[0]?.message?.content ?? JSON.stringify(json.error ?? json);

console.log(`[${res.status}] ${Date.now() - t0}ms`);
console.log(text);
if (!res.ok) process.exit(1);
