const os = require('node:os');
// Validate the DSH profile patch we added against the schemas read from the shipped packages.
const path = require('node:path');
const fs = require('node:fs');

// Derived from the environment: a hardcoded C:/Users/<name>/ path leaked the
// maintainer's username and pointed at the wrong profile on every other machine.
const PROFILE = path.join(os.homedir(), '.dsh', 'profiles', 'desktop');
const yaml = require(path.join(PROFILE, 'node_modules', 'js-yaml'));

// Field sets copied from @deepseek-ai/dsh-llm-pi-ai (lib/index.js, `profile` / `modelFields`).
const PROVIDER_KEYS = new Set([
  'apiKeyEnv', 'displayName', 'api', 'baseURL', 'models', 'modelOverrides', 'compat',
  'defaultContextWindow', 'defaultMaxTokens', 'defaultInput', 'headers', 'reasoning',
  'thinkingBudgets', 'cacheRetention', 'transport', 'timeoutMs', 'websocketConnectTimeoutMs',
  'streamIdleTimeoutMs', 'maxRequestImageBytes', 'requestImagePixelBudget',
  'requestImageMaxBytes', 'retryPolicy',
]);
const MODEL_KEYS = new Set(['id', 'name', 'contextWindow', 'maxTokens', 'input', 'reasoningEfforts', 'compat']);
const MODALITIES = new Set(['text', 'image']);
const PROTOCOLS = new Set(['openai-completions', 'openai-responses', 'anthropic-messages']);

const problems = [];
const notes = [];

const doc = yaml.load(fs.readFileSync(path.join(PROFILE, 'cordis.patch.yml'), 'utf8'));
if (!Array.isArray(doc)) problems.push('patch root is not a YAML array');

const rows = new Map();
for (const row of doc) {
  if (row && typeof row === 'object' && row.id) rows.set(row.id, row);
}

const providerRow = rows.get('llm-pi-ai');
let providers = null;
if (!providerRow) problems.push('llm-pi-ai row missing');
else {
  providers = providerRow.config?.providers;
  if (!providers || typeof providers !== 'object') problems.push('llm-pi-ai.config.providers missing');
  else {
    for (const [route, profile] of Object.entries(providers)) {
      notes.push(`provider route "${route}" -> ${profile.baseURL} (api=${profile.api})`);
      for (const key of Object.keys(profile)) {
        if (!PROVIDER_KEYS.has(key)) problems.push(`provider "${route}" has unknown field "${key}"`);
      }
      if (!PROTOCOLS.has(profile.api)) problems.push(`provider "${route}" api "${profile.api}" is not one of ${[...PROTOCOLS].join(', ')}`);
      if (!Array.isArray(profile.models) || profile.models.length === 0) problems.push(`provider "${route}" needs a non-empty models list`);
      for (const model of profile.models ?? []) {
        for (const key of Object.keys(model)) {
          if (!MODEL_KEYS.has(key)) problems.push(`model "${model.id}" has unknown field "${key}"`);
        }
        if (!model.id) problems.push('a model entry has no id');
        for (const modality of model.input ?? []) {
          if (!MODALITIES.has(modality)) problems.push(`model "${model.id}" declares unsupported input modality "${modality}"`);
        }
        if (!(model.contextWindow > 0)) problems.push(`model "${model.id}" needs a positive contextWindow`);
        if (!(model.maxTokens > 0)) problems.push(`model "${model.id}" needs a positive maxTokens`);
        if (model.maxTokens > model.contextWindow) problems.push(`model "${model.id}" maxTokens exceeds contextWindow`);
        notes.push(`  model "${model.id}" context=${model.contextWindow} maxTokens=${model.maxTokens} input=[${(model.input ?? []).join(',')}] reasoningEfforts=${JSON.stringify(model.reasoningEfforts)}`);
      }
      if (profile.apiKeyEnv === undefined) notes.push('  no apiKeyEnv; relying on the Authorization header placeholder (expected for a keyless local server)');
    }
  }
}

const selectionRow = rows.get('subagent-model-selection-settings');
if (!selectionRow) problems.push('subagent-model-selection-settings row missing');
else {
  const allowed = selectionRow.config?.allowedModels;
  if (selectionRow.config?.enabled !== true) problems.push('subagent model selection is not enabled');
  if (!Array.isArray(allowed) || allowed.length === 0) problems.push('enabled subagent model selection needs at least one allowed model');
  else {
    const seen = new Set();
    for (const route of allowed) {
      if (!route.provider || !route.model) problems.push('an allowedModels entry is missing provider or model');
      const key = `${route.provider}\0${route.model}`;
      if (seen.has(key)) problems.push(`allowedModels repeats ${route.provider}/${route.model}`);
      seen.add(key);
      notes.push(`allowed subagent route "${route.provider}/${route.model}"`);
      const declared = providers?.[route.provider]?.models?.some((m) => m.id === route.model);
      if (providers?.[route.provider] && !declared) problems.push(`allowed route "${route.provider}/${route.model}" is not declared by that provider's models list`);
    }
  }
}

console.log(notes.join('\n'));
console.log('');
if (problems.length === 0) {
  console.log('VALID: the profile patch parses and matches the shipped provider/model schemas.');
} else {
  console.log('PROBLEMS:');
  for (const problem of problems) console.log(' - ' + problem);
  process.exitCode = 1;
}
