#!/usr/bin/env node
/**
 * DSH local GGUF gateway.
 *
 * Presents a stable OpenAI-compatible endpoint to DeepSeek Harness while owning the
 * lifecycle of llama-server:
 *
 *   - `/v1/models` is answered from config and never loads weights, so DSH can
 *     register and browse the route without spending VRAM.
 *   - the first real inference request starts llama-server, waits for health, then
 *     proxies the call (streaming is passed through chunk by chunk).
 *   - when nothing has used the model for `lifecycle.idleTimeoutMs`, llama-server is
 *     terminated and its VRAM is released. The next request starts it again.
 *   - text prompts that name a local image file get that image attached as an
 *     `image_url` part, so a text-only parent model can still delegate "look at this
 *     picture" work to the local multimodal model without needing tool calling.
 *
 * No dependencies; run with the Node bundled in the DSH runtime.
 */

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');

const HERE = __dirname;
const CONFIG_PATH = process.env.DSH_LOCAL_LLM_CONFIG || path.join(HERE, 'config.json');

//#region logging -----------------------------------------------------------------

let logFd = null;
let logBytes = 0;
let logCfg = { file: null, maxBytes: 5 * 1024 * 1024 };

function rotateLog() {
  if (!logCfg.file) return;
  try {
    const size = fs.statSync(logCfg.file).size;
    if (size > logCfg.maxBytes) {
      fs.renameSync(logCfg.file, `${logCfg.file}.1`);
      if (logFd !== null) { try { fs.closeSync(logFd); } catch {} logFd = null; }
      logBytes = 0;
    }
  } catch {}
}

function openLog() {
  if (!logCfg.file) return;
  try {
    fs.mkdirSync(path.dirname(logCfg.file), { recursive: true });
    rotateLog();
    logFd = fs.openSync(logCfg.file, 'a');
    logBytes = 0;
  } catch (error) {
    process.stderr.write(`gateway: cannot open log file: ${error.message}\n`);
    logFd = null;
  }
}

function log(level, message) {
  const line = `${new Date().toISOString()} ${level.padEnd(5)} ${message}`;
  process.stdout.write(line + '\n');
  if (logFd === null) return;
  try {
    const written = Buffer.byteLength(line) + 1;
    fs.writeSync(logFd, line + '\n');
    logBytes += written;
    if (logBytes > logCfg.maxBytes) { rotateLog(); }
  } catch {}
}

//#endregion
//#region config -----------------------------------------------------------------

let config = null;
let configMtime = 0;
/** Bumped on every successful reload, so "the operator changed the config" is detectable
 *  even when the file's mtime moves backwards (restoring a backup, git checkout). */
let configGeneration = 0;

function loadConfig() {
  const stat = fs.statSync(CONFIG_PATH);
  const mtime = stat.mtimeMs;
  if (config !== null && mtime === configMtime) return config;
  // Editors on Windows happily prepend a UTF-8 BOM; JSON.parse would choke on it.
  const text = fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, '');
  const parsed = JSON.parse(text);
  config = parsed;
  configMtime = mtime;
  configGeneration += 1;
  logCfg = {
    file: parsed.logging?.file ?? null,
    maxBytes: parsed.logging?.maxBytes ?? 5 * 1024 * 1024,
  };
  if (logFd === null) openLog();
  return config;
}

function getConfig() {
  try {
    return loadConfig();
  } catch (error) {
    // A broken edit must not take the endpoint down; keep serving the last good copy.
    log('ERROR', `config reload failed, keeping previous config: ${error.message}`);
    return config;
  }
}

//#endregion
//#region upstream (llama-server) lifecycle ---------------------------------------

const STARTING = Symbol('starting');

/**
 * PID listening on a local TCP port, or null. Used to detect a llama-server left
 * behind by a previous gateway run: a second copy cannot bind the port, and the
 * orphan would keep holding VRAM with nothing left to unload it.
 */
function pidOnPort(port) {
  try {
    const out = execFileSync('netstat', ['-ano', '-p', 'TCP'], { encoding: 'utf8' });
    for (const line of out.split(/\r?\n/)) {
      const m = line.trim().match(/^TCP\s+(\S+):(\d+)\s+(\S+)\s+LISTENING\s+(\d+)$/i);
      if (m && Number(m[2]) === port) return Number(m[4]);
    }
    return null;
  } catch {
    return null;
  }
}

/** Executable basename for a PID, or null. Guards against killing a stranger on our port. */
function imageNameOf(pid) {
  try {
    const out = execFileSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8' });
    const m = out.match(/^"([^"]+)"/m);
    return m === null ? null : m[1];
  } catch {
    return null;
  }
}

class Upstream {
  constructor() {
    this.child = null;
    this.starting = null;
    this.activeRequests = 0;
    this.lastActivity = 0;
    this.startedAt = 0;
    this.starts = 0;
    this.unexpectedExits = 0;
    this.lastError = null;
    this.stopping = false;
    this.tail = [];
    // Start-failure budget: after repeated failures the gateway refuses fast instead of
    // making every caller wait out another start timeout.
    this.consecutiveFailures = 0;
    this.lastFailureAt = 0;
    this.lastFailureMessage = null;
    this.failureGeneration = -1;
  }

  get base() {
    const cfg = getConfig();
    return `http://${cfg.llamaServer.host}:${cfg.llamaServer.port}`;
  }

  get running() {
    return this.child !== null && this.child.exitCode === null;
  }

  /** Args plus forced overrides (e.g. pinning the projector to CPU after an OOM). */
  buildArgs(overrides = []) {
    const cfg = getConfig();
    const s = cfg.llamaServer;
    const args = [
      '-m', s.modelPath,
      '--host', s.host,
      '--port', String(s.port),
      '--alias', cfg.model.id,
    ];
    if (s.mmprojPath) args.push('--mmproj', s.mmprojPath);
    if (Array.isArray(s.args)) args.push(...s.args.map(String));
    for (const extra of overrides) if (!args.includes(extra)) args.push(extra);
    return args;
  }

  /** Report a cooldown while repeated start attempts are still fresh. */
  get cooldown() {
    const cfg = getConfig();
    const limit = cfg.lifecycle?.maxConsecutiveStartFailures ?? 2;
    const windowMs = cfg.lifecycle?.failureCooldownMs ?? 60000;
    if (this.consecutiveFailures < limit) return null;
    const age = Date.now() - this.lastFailureAt;
    if (age >= windowMs) return null;
    return { retryInMs: windowMs - age, message: this.lastFailureMessage ?? 'unknown' };
  }

  /** Does something already answer our upstream health check? */
  async portResponds() {
    try {
      const res = await fetch(`${this.base}/health`, { signal: AbortSignal.timeout(1200) });
      return res.ok;
    } catch {
      return false;
    }
  }

  /**
   * Reclaim the upstream port from a llama-server that outlived its gateway.
   * Never starts a second copy: that would fail to bind and leave the orphan
   * holding VRAM that nothing would ever release.
   */
  async reclaimPort() {
    const cfg = getConfig();
    const s = cfg.llamaServer;
    if (!(await this.portResponds())) return;
    const pid = pidOnPort(s.port);
    if (pid === null) {
      throw new Error(`port ${s.port} already answers health but its owner cannot be identified; free it before delegating`);
    }
    const image = imageNameOf(pid);
    if (image === null || !/llama[-_]?server/i.test(image)) {
      throw new Error(`port ${s.port} is held by "${image ?? 'unknown'}" (pid ${pid}), not llama-server; nothing was started`);
    }
    log('WARN', `reclaiming stale llama-server pid ${pid} still holding port ${s.port} from a previous run`);
    try { execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' }); } catch {}
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      if (!(await this.portResponds())) {
        log('INFO', `port ${s.port} reclaimed`);
        return;
      }
      await sleep(200);
    }
    throw new Error(`stale llama-server (pid ${pid}) did not release port ${s.port}`);
  }

  recordFailure(error) {
    this.consecutiveFailures += 1;
    this.lastFailureAt = Date.now();
    this.lastFailureMessage = error.message;
    this.failureGeneration = configGeneration;
    return error;
  }

  /** Start llama-server if it is not already up; concurrent callers await one start. */
  async ensure() {
    if (this.running) return;
    if (this.starting) return this.starting;
    const cooldown = this.cooldown;
    if (cooldown !== null) {
      // Editing config.json is an explicit operator retry signal; honour it at once
      // instead of making the next request wait out the whole cooldown window.
      if (configGeneration !== this.failureGeneration) {
        log('INFO', 'config.json changed since the last start failure; clearing the cooldown');
        this.consecutiveFailures = 0;
        this.lastFailureMessage = null;
      } else {
        throw new Error(`local model is cooling down (${Math.ceil(cooldown.retryInMs / 1000)}s left after ${this.consecutiveFailures} failed starts: ${cooldown.message}). Not retrying so the caller can fall back.`);
      }
    }
    if (this.stopping) {
      // Wait for an in-flight unload to finish before racing a new start.
      await this.waitForExit(this.child, 15000);
    }
    this.starting = this.start().finally(() => { this.starting = null; });
    return this.starting;
  }

  async start() {
    const cfg = getConfig();
    const s = cfg.llamaServer;
    if (!fs.existsSync(s.exe)) throw new Error(`llama-server executable not found: ${s.exe}`);
    if (!fs.existsSync(s.modelPath)) throw new Error(`model file not found: ${s.modelPath}`);
    await this.reclaimPort();

    try {
      await this.spawnOnce([]);
    } catch (error) {
      const text = `${error.message} ${this.tail.slice(-10).join(' ')}`;
      const looksLikeMemory = /out of memory|oom|failed to allocate|cannot allocate|cudaMalloc|allocat/i.test(text);
      if (!looksLikeMemory) throw this.recordFailure(error);
      // Another application probably took the GPU since the last run. One retry with
      // the projector on the CPU keeps text working instead of failing the caller.
      log('WARN', `device memory exhausted on start; retrying once with --no-mmproj-offload (vision stays available, on CPU)`);
      try {
        await this.spawnOnce(['--no-mmproj-offload']);
      } catch (second) {
        throw this.recordFailure(second);
      }
    }
    this.consecutiveFailures = 0;
  }

  async spawnOnce(overrides) {
    const cfg = getConfig();
    const s = cfg.llamaServer;

    this.tail = [];
    const logPath = cfg.logging?.upstreamLog ?? null;
    let out = null;
    if (logPath) {
      try {
        fs.mkdirSync(path.dirname(logPath), { recursive: true });
        out = fs.openSync(logPath, 'a');
        fs.writeSync(out, `\n===== ${new Date().toISOString()} spawning llama-server =====\n`);
      } catch { out = null; }
    }

    const args = this.buildArgs(overrides);
    const spawnedAt = Date.now();
    log('INFO', `starting llama-server: ${path.basename(s.exe)} ${args.join(' ')}`);

    // Pipe rather than redirect: the gateway needs the server's own words to tell an
    // out-of-memory failure from a bad model file, and it writes them to the log itself.
    const child = spawn(s.exe, args, {
      cwd: path.dirname(s.exe),
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    this.child = child;
    this.starts += 1;
    this.lastError = null;

    const collect = (buf) => {
      const text = buf.toString('utf8');
      if (out !== null) { try { fs.writeSync(out, text); } catch {} }
      for (const line of text.split(/\r?\n/)) {
        if (!line.trim()) continue;
        this.tail.push(line);
        if (this.tail.length > 60) this.tail.shift();
        if (/(error|failed|out of memory|oom|cuda.*error|allocat)/i.test(line)) this.lastError = line.trim();
      }
    };
    child.stderr?.on('data', collect);
    child.stdout?.on('data', collect);

    child.on('exit', (code, signal) => {
      if (out !== null) { try { fs.closeSync(out); } catch {} out = null; }
      const wasRunning = this.child === child;
      if (!wasRunning) return;
      this.child = null;
      this.activeRequests = 0;
      if (this.stopping) {
        log('INFO', `llama-server exited (code=${code}, signal=${signal}) after unload request`);
      } else {
        this.unexpectedExits += 1;
        log('ERROR', `llama-server exited unexpectedly (code=${code}, signal=${signal}); last error: ${this.lastError ?? 'none'}`);
      }
      this.stopping = false;
    });

    try {
      await this.waitHealthy(child, s.startTimeoutMs ?? 180000);
    } catch (error) {
      this.lastError = `${error.message}${this.lastError ? ` | ${this.lastError}` : ''}`;
      log('ERROR', `llama-server failed to become healthy: ${error.message}`);
      await this.kill(child, 4000);
      throw new Error(`local model failed to start: ${error.message}. Recent server output: ${this.tail.slice(-6).join(' | ')}`);
    }

    this.startedAt = Date.now();
    this.lastActivity = Date.now();
    log('INFO', `llama-server ready on ${this.base} after ${Date.now() - spawnedAt}ms`);
    // Warm the KV cache bookkeeping with a cheap request so the first real call is fast.
    if (cfg.llamaServer.warmup !== false) {
      try {
        await fetch(`${this.base}/health`, { signal: AbortSignal.timeout(5000) });
      } catch {}
    }
  }

  async waitHealthy(child, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    let lastProblem = 'no response';
    while (Date.now() < deadline) {
      if (child.exitCode !== null) throw new Error(`process exited with code ${child.exitCode}`);
      try {
        const res = await fetch(`${this.base}/health`, { signal: AbortSignal.timeout(2500) });
        if (res.ok) return;
        lastProblem = `health returned ${res.status}`;
      } catch (error) {
        lastProblem = error.name === 'TimeoutError' ? 'health timed out' : String(error.cause?.code ?? error.message);
      }
      await sleep(250);
    }
    throw new Error(`health check did not pass within ${timeoutMs}ms (${lastProblem})`);
  }

  async waitForExit(child, timeoutMs) {
    if (child === null || child.exitCode !== null) return;
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, timeoutMs);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
  }

  async kill(child, graceMs) {
    if (child === null || child.exitCode !== null) return;
    try { child.kill(); } catch {}
    const done = await Promise.race([
      this.waitForExit(child, graceMs).then(() => true),
      sleep(graceMs).then(() => false),
    ]);
    if (!done) {
      try {
        const { execFileSync } = require('node:child_process');
        execFileSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
      } catch {}
    }
  }

  /** Terminate llama-server and release VRAM. */
  async stop(reason) {
    const child = this.child;
    if (child === null || child.exitCode !== null) {
      this.child = null;
      return false;
    }
    this.stopping = true;
    log('INFO', `stopping llama-server (${reason}); releasing VRAM`);
    const before = Date.now();
    await this.kill(child, getConfig().llamaServer.stopTimeoutMs ?? 8000);
    this.child = null;
    this.stopping = false;
    log('INFO', `llama-server stopped in ${Date.now() - before}ms`);
    return true;
  }

  touch() { this.lastActivity = Date.now(); }

  status() {
    return {
      running: this.running,
      pid: this.running ? this.child.pid : null,
      activeRequests: this.activeRequests,
      idleMs: this.lastActivity === 0 ? null : Date.now() - this.lastActivity,
      uptimeMs: this.startedAt === 0 || !this.running ? null : Date.now() - this.startedAt,
      starts: this.starts,
      unexpectedExits: this.unexpectedExits,
      lastError: this.lastError,
      base: this.base,
    };
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const upstream = new Upstream();

/** Reap llama-server once it has been idle past the configured timeout. */
function startReaper() {
  const timer = setInterval(async () => {
    const cfg = getConfig();
    if (!cfg.lifecycle?.idleTimeoutMs) return;
    if (!upstream.running || upstream.starting || upstream.stopping) return;
    if (upstream.activeRequests > 0) return;
    if (upstream.lastActivity === 0) return;
    const idle = Date.now() - upstream.lastActivity;
    if (idle < cfg.lifecycle.idleTimeoutMs) return;
    try {
      await upstream.stop(`idle ${Math.round(idle / 1000)}s >= ${Math.round(cfg.lifecycle.idleTimeoutMs / 1000)}s`);
    } catch (error) {
      log('ERROR', `idle unload failed: ${error.message}`);
    }
  }, getConfig().lifecycle?.reapIntervalMs ?? 10000);
  timer.unref?.();
}

//#endregion
//#region image auto-attach -------------------------------------------------------

const IMAGE_MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};
const IMAGE_EXT = 'png|jpe?g|webp|gif|bmp';

function extractPaths(text, cfg) {
  const found = [];
  const push = (candidate) => {
    const clean = candidate.trim();
    if (clean && !found.includes(clean)) found.push(clean);
  };
  // Quoted paths may contain spaces.
  const quoted = new RegExp(`["'\`\u201c\u201d\u2018\u2019]([A-Za-z]:[\\\\/][^"'\`\u201c\u201d\u2018\u2019\r\n]+?\\.(?:${IMAGE_EXT}))["'\`\u201c\u201d\u2018\u2019]`, 'gi');
  for (const m of text.matchAll(quoted)) push(m[1]);
  // Unquoted absolute paths stop at whitespace.
  const bare = new RegExp(`[A-Za-z]:[\\\\/][^\\s"'\`\u201c\u201d\u2018\u2019<>|*?]*?\\.(?:${IMAGE_EXT})`, 'gi');
  for (const m of text.matchAll(bare)) push(m[0]);
  // Bare filenames are resolved against the configured search directories.
  const relative = new RegExp(`(?:^|[\\s(\\[\\u300c\\u300e])([A-Za-z0-9_.\\-]+\\.(?:${IMAGE_EXT}))(?=$|[\\s)\\]\\u3001,.;:!?\\u300d\\u300f])`, 'gi');
  for (const m of text.matchAll(relative)) push(m[1]);
  return found;
}

/**
 * Bounded, short-lived index of image files under a directory. A prompt that names
 * only `chart.png` still resolves when the file sits a few folders deep in the
 * workspace, without walking the tree on every request.
 */
const INDEX_TTL_MS = 20000;
const INDEX_MAX_ENTRIES = 20000;
const INDEX_MAX_DEPTH = 5;
let basenameIndex = { at: 0, dir: '', map: new Map() };

function indexImages(dir) {
  const now = Date.now();
  if (basenameIndex.dir === dir && now - basenameIndex.at < INDEX_TTL_MS) return basenameIndex.map;
  const map = new Map();
  let seen = 0;
  const walk = (current, depth) => {
    if (depth > INDEX_MAX_DEPTH || seen >= INDEX_MAX_ENTRIES) return;
    let entries;
    try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (seen >= INDEX_MAX_ENTRIES) return;
      seen += 1;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
        walk(full, depth + 1);
      } else if (entry.isFile() && IMAGE_MIME[path.extname(entry.name).toLowerCase()]) {
        const key = entry.name.toLowerCase();
        if (!map.has(key)) map.set(key, full);
      }
    }
  };
  walk(dir, 0);
  basenameIndex = { at: Date.now(), dir, map };
  log('DEBUG', `indexed ${map.size} image(s) under ${dir}`);
  return map;
}

function resolveImage(candidate, cfg) {
  const tryPath = (p) => {
    try {
      if (!fs.statSync(p).isFile()) return null;
      const ext = path.extname(p).toLowerCase();
      if (!IMAGE_MIME[ext]) return null;
      const size = fs.statSync(p).size;
      const max = cfg.features?.maxImageBytes ?? 12 * 1024 * 1024;
      if (size > max) { log('WARN', `auto-attach skipped oversized image (${size} > ${max}): ${p}`); return null; }
      return { file: p, ext, size };
    } catch { return null; }
  };
  const direct = tryPath(candidate);
  if (direct) return direct;
  if (path.isAbsolute(candidate)) return null;
  const searchDirs = cfg.features?.imageSearchDirs ?? [];
  for (const dir of searchDirs) {
    const found = tryPath(path.join(dir, candidate));
    if (found) return found;
  }
  const target = path.basename(candidate).toLowerCase();
  for (const dir of searchDirs) {
    const hit = indexImages(dir).get(target);
    if (hit) {
      const found = tryPath(hit);
      if (found) return found;
    }
  }
  return null;
}

/**
 * Rewrite the last user message so any local image it names travels with the
 * request. A text-only front model can therefore delegate visual work by writing
 * the path it was told about, without needing tool-call support.
 */
function attachImages(body, cfg) {
  if (!cfg.features?.autoAttachImages) return 0;
  if (!Array.isArray(body.messages)) return 0;
  let index = -1;
  for (let i = body.messages.length - 1; i >= 0; i -= 1) {
    if (body.messages[i]?.role === 'user') { index = i; break; }
  }
  if (index < 0) return 0;

  const message = body.messages[index];
  const parts = typeof message.content === 'string'
    ? [{ type: 'text', text: message.content }]
    : Array.isArray(message.content) ? message.content : null;
  if (parts === null) return 0;
  if (parts.some((part) => part && (part.type === 'image_url' || part.type === 'image' || part.input_audio))) {
    return 0; // already carries media; leave the request untouched
  }

  const text = parts
    .filter((part) => part && typeof part.text === 'string')
    .map((part) => part.text)
    .join('\n');
  if (!text) return 0;

  const limit = cfg.features?.maxAutoAttachImages ?? 4;
  const images = [];
  // A prompt that names the same file twice used to attach it twice, which burned
  // a slot and made the model emit a duplicate row. Attach each file once.
  const seenFiles = new Set();
  for (const candidate of extractPaths(text, cfg)) {
    if (images.length >= limit) break;
    const resolved = resolveImage(candidate, cfg);
    if (!resolved) continue;
    const fileKey = String(resolved.file).toLowerCase();
    if (seenFiles.has(fileKey)) continue;
    seenFiles.add(fileKey);
    let data;
    try { data = fs.readFileSync(resolved.file); } catch { continue; }
    images.push({
      type: 'image_url',
      image_url: { url: `data:${IMAGE_MIME[resolved.ext]};base64,${data.toString('base64')}` },
      _source: resolved.file,
    });
  }
  if (images.length === 0) return 0;

  message.content = [
    ...parts.filter((part) => part && part.type !== 'image_url'),
    ...images.map(({ _source, ...rest }) => rest),
  ];
  log('INFO', `auto-attached ${images.length} image(s) from prompt: ${images.map((i) => i._source).join(', ')}`);
  return images.length;
}

/**
 * Zero-transfer delivery. Without this, everything the local model produces travels
 * back through the caller's context and must be re-emitted by the caller to become a
 * deliverable — so "delegate to save tokens" is arithmetically impossible for long
 * texts. A `[[save:<path>]]` marker in the last user message makes the gateway write
 * the full completion to disk itself and answer with a short receipt instead, so the
 * body never enters the caller's context at all.
 *
 * `features.saveDirective`: { enabled, roots: [allowed absolute directories] }
 */
const SAVE_MARKER = /\[\[save:\s*([^\]]+?)\s*\]\]/i;
const FILE_MARKER = /\[\[file:\s*([^\]]+?)\s*\]\]/gi;
const SAVE_EXTENSIONS = new Set(['.md', '.txt', '.json', '.csv', '.py', '.js', '.log', '.html']);

/**
 * Input side of zero-transfer: `[[file:<path>]]` is replaced with the file's text
 * before the request reaches the model. Without it, delegating a bulk task still
 * costs the caller the whole input as output tokens (it would have to retype the
 * material into the prompt), which erases the saving the save-directive creates.
 *
 * `features.inlineFiles`: { enabled, roots: [readable directories], maxBytes }
 */
function inlineFiles(body, cfg) {
  const rule = cfg.features?.inlineFiles;
  if (!rule || rule.enabled === false) return 0;
  if (!Array.isArray(body.messages)) return 0;
  const maxBytes = rule.maxBytes ?? 262144;
  const roots = (rule.roots ?? []).map((r) => path.resolve(r));

  const index = body.messages.map((m) => m?.role).lastIndexOf('user');
  if (index < 0) return 0;
  const message = body.messages[index];
  const isParts = Array.isArray(message.content);
  const text = isParts
    ? message.content.filter((p) => p?.type === 'text').map((p) => p.text).join('\n')
    : String(message.content ?? '');
  if (!text.includes('[[file:')) return 0;

  let count = 0;
  const replaced = text.replace(FILE_MARKER, (_whole, rawPath) => {
    const target = resolveUnderRoots(rawPath, roots);
    if (target === null) {
      log('WARN', `inline file rejected (outside allowed roots): ${rawPath}`);
      return `[[file 拒绝访问: ${rawPath}]]`;
    }
    try {
      const stat = fs.statSync(target);
      if (!stat.isFile()) return `[[file 不是文件: ${rawPath}]]`;
      if (stat.size > maxBytes) return `[[file 超过 ${maxBytes} 字节: ${rawPath}]]`;
      // Text only. decodeing a PNG as UTF-8 produces replacement characters that
      // explode into thousands of tokens and blow the slot context (measured: one
      // 6.6 KB PNG -> 11.3k tokens -> HTTP 502). Images belong to attachImages,
      // which sends them as image parts.
      const raw = fs.readFileSync(target);
      if (raw.includes(0)) {
        log('WARN', `inline file is binary, not inlined: ${rawPath} (write the image path into the prompt instead)`);
        return `[[file 是二进制文件（图片请直接把路径写进提示词，网关会自动附加）: ${rawPath}]]`;
      }
      const content = raw.toString('utf8');
      count += 1;
      return `\n<<<FILE ${rawPath}>>>\n${content}\n<<<END FILE>>>\n`;
    } catch (error) {
      return `[[file 读取失败: ${rawPath} (${error.code ?? error.message})]]`;
    }
  });

  if (count === 0) return 0;
  if (isParts) {
    message.content = message.content.map((p) => (p?.type === 'text' ? { ...p, text: replaced } : p));
  } else {
    message.content = replaced;
  }
  log('INFO', `inlined ${count} file(s) into the prompt (${replaced.length} chars)`);
  return count;
}

/** Resolve a path and require it to live under one of the allowed roots. */
function resolveUnderRoots(rawPath, roots) {
  let target;
  try { target = path.resolve(String(rawPath)); } catch { return null; }
  if (!path.isAbsolute(target) || roots.length === 0) return null;
  return roots.some((root) => target === root || target.startsWith(root + path.sep)) ? target : null;
}

/** Pull the marker out of the last user message and validate its target path. */
function takeSaveDirective(body, cfg) {
  const directive = cfg.features?.saveDirective;
  if (!directive || directive.enabled === false) return null;
  if (!Array.isArray(body.messages)) return null;

  for (let i = body.messages.length - 1; i >= 0; i -= 1) {
    const message = body.messages[i];
    if (message?.role !== 'user') continue;

    const isParts = Array.isArray(message.content);
    const text = isParts
      ? message.content.filter((p) => p?.type === 'text').map((p) => p.text).join('\n')
      : String(message.content ?? '');
    const hit = SAVE_MARKER.exec(text);
    if (!hit) return null;

    const target = resolveSavePath(hit[1], directive);
    if (target === null) {
      log('WARN', `save directive rejected (path outside allowed roots): ${hit[1]}`);
      return null;
    }

    // Strip the marker so the model does not echo it into the saved body.
    if (isParts) {
      message.content = message.content.map((p) =>
        p?.type === 'text' ? { ...p, text: p.text.replace(SAVE_MARKER, '').trim() } : p);
    } else {
      message.content = text.replace(SAVE_MARKER, '').trim();
    }
    return { path: target };
  }
  return null;
}

function resolveSavePath(rawPath, directive) {
  let target;
  try { target = path.resolve(String(rawPath)); } catch { return null; }
  if (!path.isAbsolute(target)) return null;
  if (!SAVE_EXTENSIONS.has(path.extname(target).toLowerCase())) return null;
  const roots = (directive.roots ?? []).map((r) => path.resolve(r));
  const allowed = roots.some((root) => target === root || target.startsWith(root + path.sep));
  return allowed ? target : null;
}

/** Write the body and describe it in a few dozen tokens. */
function saveOutput(target, content) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content, 'utf8');
  const lines = content.split(/\r?\n/).length;
  const head = content.replace(/\s+/g, ' ').slice(0, 60);
  const receipt = `已保存到 ${target}（${content.length} 字符，${lines} 行）。开头：${head}`;
  log('INFO', `saved ${content.length} chars to ${target}`);
  return receipt;
}

/**
 * DSH sends its whole coding-agent system prompt with every subagent call. A small
 * model measurably degrades under it — with the prompt attached, the 3B model
 * reported "报错/告警：无" for a screenshot that plainly contains an ERROR and a WARN
 * line, three runs out of four; with no system prompt it read both correctly.
 * `features.systemPrompt.mode` is `keep` | `strip` | `replace`.
 */
function applySystemPolicy(body, cfg) {
  const policy = cfg.features?.systemPrompt;
  if (!policy || !policy.mode || policy.mode === 'keep') return false;
  if (!Array.isArray(body.messages)) return false;

  const systemMessages = body.messages.filter((message) => message?.role === 'system');
  const removedChars = systemMessages.reduce((a, m) => a + String(m.content ?? '').length, 0);

  if (policy.mode === 'strip') {
    if (systemMessages.length === 0) return false;
    body.messages = body.messages.filter((message) => message?.role !== 'system');
    log('INFO', `system prompt stripped: ${systemMessages.length} message(s), ${removedChars} chars removed`);
    return true;
  }

  if (policy.mode === 'replace') {
    const replacement = String(policy.replacement ?? '');
    const kept = body.messages.filter((message) => message?.role !== 'system');
    body.messages = replacement.length > 0 ? [{ role: 'system', content: replacement }, ...kept] : kept;
    log('INFO', `system prompt replaced: ${removedChars} chars -> ${replacement.length} chars`);
    return true;
  }

  return false;
}

//#endregion
//#region HTTP surface ------------------------------------------------------------

function sendJson(res, status, value) {
  const payload = JSON.stringify(value);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'access-control-allow-origin': '*',
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 256 * 1024 * 1024) { reject(new Error('request body too large')); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function modelDescriptor(cfg) {
  return {
    id: cfg.model.id,
    object: 'model',
    created: Math.floor(Date.now() / 1000),
    owned_by: 'dsh-local-llm',
    name: cfg.model.displayName,
    architecture: {
      input_modalities: cfg.model.input ?? ['text'],
      output_modalities: ['text'],
    },
    meta: {
      n_ctx: cfg.model.contextWindow,
      max_tokens: cfg.model.maxTokens,
    },
  };
}

/** Forward one inference call, streaming the upstream bytes straight through. */
async function proxyInference(req, res, bodyBuffer, rewritten) {
  const cfg = getConfig();
  upstream.activeRequests += 1;
  upstream.touch();
  const started = Date.now();
  const controller = new AbortController();
  let clientGone = false;
  res.on('close', () => {
    if (!res.writableEnded) { clientGone = true; controller.abort(); }
  });

  try {
    await upstream.ensure();
    const payload = Buffer.byteLength(rewritten) === 0 ? bodyBuffer : Buffer.from(rewritten, 'utf8');
    const target = `${upstream.base}${req.url}`;
    const headers = { 'content-type': 'application/json' };
    if (req.headers.accept) headers.accept = req.headers.accept;
    const result = await fetch(target, {
      method: 'POST',
      headers,
      body: payload,
      signal: controller.signal,
    });
    upstream.touch();

    const contentType = result.headers.get('content-type') ?? 'application/json';
    res.writeHead(result.status, {
      'content-type': contentType,
      'cache-control': 'no-cache',
      'access-control-allow-origin': '*',
      'x-accel-buffering': 'no',
    });
    if (result.body) {
      for await (const chunk of result.body) {
        if (clientGone) break;
        if (!res.write(chunk)) await new Promise((resolve) => res.once('drain', resolve));
      }
    }
    res.end();
    log('INFO', `POST ${req.url} -> ${result.status} in ${Date.now() - started}ms`);
  } catch (error) {
    if (error.name === 'AbortError') {
      log('WARN', `request aborted by client after ${Date.now() - started}ms`);
      if (!res.headersSent) sendJson(res, 499, { error: { message: 'client closed the request', type: 'aborted' } });
      else res.end();
      return;
    }
    upstream.lastError = error.message;
    log('ERROR', `inference failed after ${Date.now() - started}ms: ${error.message}`);
    if (!res.headersSent) {
      sendJson(res, 502, {
        error: {
          message: `local model unavailable: ${error.message}`,
          type: 'local_model_error',
        },
      });
    } else {
      res.end();
    }
  } finally {
    upstream.activeRequests = Math.max(0, upstream.activeRequests - 1);
    upstream.touch();
  }
}

/**
 * Run the completion, write the body to disk, and answer with a receipt. The caller
 * never receives the body, which is the whole point: for a long deliverable the body
 * would otherwise be charged once as input and again as the caller's output.
 * Streaming clients get a synthetic single-chunk SSE carrying the receipt.
 */
async function proxyAndSave(req, res, payloadText, saveTarget, wantsStream) {
  upstream.activeRequests += 1;
  upstream.touch();
  const started = Date.now();
  try {
    await upstream.ensure();
    const parsed = JSON.parse(payloadText);
    parsed.stream = false; // the body is buffered here, not streamed to the caller
    const result = await fetch(`${upstream.base}${req.url}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(parsed),
    });
    const json = await result.json();
    const content = json.choices?.[0]?.message?.content ?? '';
    if (!result.ok || typeof content !== 'string' || content.length === 0) {
      sendJson(res, 502, { error: { message: `local model produced no content to save: ${json.error?.message ?? 'empty completion'}`, type: 'local_model_error' } });
      return;
    }

    const receipt = saveOutput(saveTarget, content);

    if (wantsStream) {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'x-accel-buffering': 'no' });
      const chunk = (delta, finish) => JSON.stringify({
        id: 'chatcmpl-saved', object: 'chat.completion.chunk',
        created: Math.floor(Date.now() / 1000), model: parsed.model,
        choices: [{ index: 0, delta, finish_reason: finish }],
      });
      res.write(`data: ${chunk({ role: 'assistant', content: receipt }, null)}\n\n`);
      res.write(`data: ${chunk({}, 'stop')}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    } else {
      sendJson(res, 200, {
        id: 'chatcmpl-saved',
        object: 'chat.completion',
        created: Math.floor(Date.now() / 1000),
        model: parsed.model,
        choices: [{ index: 0, message: { role: 'assistant', content: receipt }, finish_reason: 'stop' }],
        usage: json.usage,
      });
    }
    log('INFO', `POST ${req.url} -> saved, receipt ${receipt.length} chars, ${Date.now() - started}ms`);
  } catch (error) {
    log('ERROR', `save-mode inference failed after ${Date.now() - started}ms: ${error.message}`);
    if (!res.headersSent) {
      sendJson(res, 502, { error: { message: `local model unavailable: ${error.message}`, type: 'local_model_error' } });
    } else {
      res.end();
    }
  } finally {
    upstream.activeRequests = Math.max(0, upstream.activeRequests - 1);
    upstream.touch();
  }
}

async function handle(req, res) {
  const cfg = getConfig();
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'GET,POST,OPTIONS',
    });
    res.end();
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/health' || url.pathname === '/gateway/health')) {
    sendJson(res, 200, { status: 'ok', upstream: upstream.status() });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/gateway/status') {
    sendJson(res, 200, {
      model: cfg.model,
      lifecycle: cfg.lifecycle,
      idleTimeoutMs: cfg.lifecycle?.idleTimeoutMs ?? null,
      upstream: upstream.status(),
      configPath: CONFIG_PATH,
    });
    return;
  }

  if (req.method === 'POST' && (url.pathname === '/gateway/unload' || url.pathname === '/gateway/stop')) {
    const stopped = await upstream.stop('explicit request via /gateway/unload');
    sendJson(res, 200, { stopped, upstream: upstream.status() });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/gateway/reset') {
    // Manual escape hatch for the start-failure cooldown after fixing an external cause.
    upstream.consecutiveFailures = 0;
    upstream.lastFailureMessage = null;
    upstream.lastError = null;
    log('INFO', 'start-failure cooldown cleared by /gateway/reset');
    sendJson(res, 200, { reset: true, upstream: upstream.status() });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/gateway/warm') {
    try {
      await upstream.ensure();
      sendJson(res, 200, { ready: true, upstream: upstream.status() });
    } catch (error) {
      sendJson(res, 503, { ready: false, error: error.message, upstream: upstream.status() });
    }
    return;
  }

  if (req.method === 'GET' && (url.pathname === '/v1/models' || url.pathname === '/models')) {
    // Answered from config: browsing the route must never load weights.
    sendJson(res, 200, { object: 'list', data: [modelDescriptor(cfg)] });
    return;
  }

  if (req.method === 'GET' && url.pathname.startsWith('/v1/models/')) {
    sendJson(res, 200, modelDescriptor(cfg));
    return;
  }

  const isInference = req.method === 'POST' && (
    url.pathname === '/v1/chat/completions' ||
    url.pathname === '/v1/completions' ||
    url.pathname === '/chat/completions' ||
    url.pathname === '/completion'
  );

  if (isInference) {
    let bodyBuffer;
    try {
      bodyBuffer = await readBody(req);
    } catch (error) {
      sendJson(res, 413, { error: { message: error.message, type: 'invalid_request' } });
      return;
    }

    let rewritten = '';
    let saveTarget = null;
    let wantsStream = false;
    try {
      const parsed = JSON.parse(bodyBuffer.toString('utf8'));
      let changed = false;
      // llama-server validates the model id against the loaded alias, so normalise it.
      if (parsed.model !== cfg.model.id) { parsed.model = cfg.model.id; changed = true; }
      if (applySystemPolicy(parsed, cfg)) changed = true;
      if (inlineFiles(parsed, cfg) > 0) changed = true;
      if (attachImages(parsed, cfg) > 0) changed = true;
      wantsStream = parsed.stream === true;
      const directive = takeSaveDirective(parsed, cfg);
      if (directive !== null) { saveTarget = directive.path; changed = true; }
      if (changed) rewritten = JSON.stringify(parsed);
    } catch (error) {
      log('WARN', `could not prepare request body: ${error.message}`);
    }

    if (saveTarget !== null) {
      await proxyAndSave(req, res, rewritten.length > 0 ? rewritten : bodyBuffer.toString('utf8'), saveTarget, wantsStream);
      return;
    }

    await proxyInference(req, res, bodyBuffer, rewritten);
    return;
  }

  sendJson(res, 404, { error: { message: `no such endpoint: ${req.method} ${url.pathname}`, type: 'not_found' } });
}

//#endregion
//#region bootstrap ---------------------------------------------------------------

function main() {
  const cfg = loadConfig();
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      log('ERROR', `unhandled request error: ${error.stack ?? error.message}`);
      try { sendJson(res, 500, { error: { message: String(error.message), type: 'gateway_error' } }); } catch {}
    });
  });
  // Long generations must not be cut by the default request timeout.
  server.requestTimeout = 0;
  server.headersTimeout = 120000;
  server.keepAliveTimeout = 65000;
  server.timeout = 0;

  server.on('error', (error) => {
    if (error.code === 'EADDRINUSE') {
      log('ERROR', `port ${cfg.listen.port} is already in use; another gateway is probably running. Exiting.`);
      process.exit(0);
    }
    log('ERROR', `server error: ${error.message}`);
    process.exit(1);
  });

  server.listen(cfg.listen.port, cfg.listen.host, () => {
    log('INFO', `gateway listening on http://${cfg.listen.host}:${cfg.listen.port}`);
    log('INFO', `model route: ${cfg.model.id} -> ${upstream.base} (idle unload after ${Math.round((cfg.lifecycle?.idleTimeoutMs ?? 0) / 1000)}s)`);
    startReaper();
  });

  const shutdown = async (signal) => {
    log('INFO', `received ${signal}; shutting down`);
    if (cfg.lifecycle?.unloadOnGatewayExit !== false) {
      try { await upstream.stop('gateway shutdown'); } catch {}
    }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  // Last resort: never leave llama-server holding VRAM after the gateway itself dies.
  process.on('exit', () => {
    const child = upstream.child;
    if (child !== null && child.exitCode === null) {
      try { child.kill(); } catch {}
    }
  });
  process.on('uncaughtException', (error) => log('ERROR', `uncaught exception: ${error.stack ?? error.message}`));
  process.on('unhandledRejection', (reason) => log('ERROR', `unhandled rejection: ${reason}`));
}

main();

//#endregion
