#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = process.env.STREMIO_BRIDGE_DATA || path.join(HERE, "data");
const CONFIG_FILE = path.join(DATA_DIR, "config.json");
const HOST = process.env.STREMIO_BRIDGE_HOST || "0.0.0.0";
const PORT = Number(process.env.STREMIO_BRIDGE_PORT || 17890);
const VERSION = "0.3.0";
fs.mkdirSync(DATA_DIR, { recursive: true });

function cleanBase(value) {
  const u = new URL(String(value));
  if (!["http:", "https:"].includes(u.protocol) || u.username || u.password) throw new Error("Use uma URL HTTP/HTTPS sem credenciais embutidas.");
  u.hash = "";
  return u.href.replace(/\/+$/, "");
}
function randomPin() { return String(crypto.randomInt(100000, 1000000)); }
function loadConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
    return {
      pin: String(raw.pin || randomPin()),
      secret: String(raw.secret || crypto.randomBytes(32).toString("hex")),
      streamingServerUrl: cleanBase(raw.streamingServerUrl || process.env.STREMIO_STREAM_SERVER || "http://127.0.0.1:11470"),
      publicBaseUrl: String(raw.publicBaseUrl || "").replace(/\/+$/, ""),
      addons: Array.isArray(raw.addons) ? raw.addons.filter(x => typeof x === "string") : [],
      accountAddons: Array.isArray(raw.accountAddons) ? raw.accountAddons.filter(x => typeof x === "string") : [],
      stremioAuthKey: typeof raw.stremioAuthKey === "string" ? raw.stremioAuthKey : "",
      stremioUser: raw.stremioUser && typeof raw.stremioUser === "object" ? raw.stremioUser : null,
      cacheSize: Number.isFinite(Number(raw.cacheSize)) ? Number(raw.cacheSize) : 2147483648,
      transcodeTorrents: raw.transcodeTorrents !== false
    };
  } catch {
    return {
      pin: process.env.STREMIO_BRIDGE_PIN || randomPin(),
      secret: crypto.randomBytes(32).toString("hex"),
      streamingServerUrl: cleanBase(process.env.STREMIO_STREAM_SERVER || "http://127.0.0.1:11470"),
      publicBaseUrl: "",
      addons: [],
      accountAddons: [],
      stremioAuthKey: "",
      stremioUser: null,
      cacheSize: 2147483648,
      transcodeTorrents: true
    };
  }
}
let config = loadConfig();
function saveConfig() { fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 }); }
saveConfig();

const sessions = new Map();
const pinAttempts = new Map();
const mediaEntries = new Map();
const MAX_MEDIA_ENTRIES = 1500;
const MEDIA_TTL = 45 * 60 * 1000;
const TRANSCODE_DIR = path.join(DATA_DIR, "transcodes");
fs.mkdirSync(TRANSCODE_DIR, { recursive: true });
const playbackEntries = new Map();
const transcodeSessions = new Map();
let ffmpegAvailablePromise = null;

function json(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS,HEAD",
    "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Bridge-Pin,Range"
  });
  res.end(body);
}
function html(res, code, body) {
  res.writeHead(code, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
  res.end(body);
}
function noContent(res) {
  res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS,HEAD", "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Bridge-Pin,Range" });
  res.end();
}
function parseBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", chunk => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error("Request body too large"), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
      catch { reject(Object.assign(new Error("JSON inválido."), { statusCode: 400 })); }
    });
    req.on("error", reject);
  });
}
function safeEqual(a, b) {
  const aa = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return aa.length === bb.length && crypto.timingSafeEqual(aa, bb);
}
function verifyPin(req, candidate) {
  const key = String(req.socket.remoteAddress || "unknown");
  const now = Date.now();
  let bucket = pinAttempts.get(key);
  if (bucket && bucket.resetAt <= now) { pinAttempts.delete(key); bucket = null; }
  if (bucket && bucket.count >= 10) return { ok: false, limited: true };
  if (safeEqual(candidate || "", config.pin)) {
    pinAttempts.delete(key);
    return { ok: true, limited: false };
  }
  if (!bucket) bucket = { count: 0, resetAt: now + 5 * 60 * 1000 };
  bucket.count += 1;
  pinAttempts.set(key, bucket);
  return { ok: false, limited: bucket.count >= 10 };
}
function requirePin(req, res) {
  const verdict = verifyPin(req, req.headers["x-bridge-pin"] || "");
  if (verdict.ok) return true;
  json(res, verdict.limited ? 429 : 401, {
    ok: false,
    error: verdict.limited ? "Muitas tentativas de PIN. Aguarde cinco minutos." : "PIN incorreto. Confira o PIN no terminal do PC."
  });
  return false;
}
function requireSession(req, res) {
  const auth = String(req.headers.authorization || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const session = sessions.get(token);
  if (!session || session.expires < Date.now()) {
    sessions.delete(token);
    json(res, 401, { ok: false, error: "Pareamento expirado. No Roku, abra Opções > Conectar ao PC e informe o PIN novamente." });
    return false;
  }
  return true;
}
function publicConfig() {
  return {
    streamingServerUrl: config.streamingServerUrl,
    publicBaseUrl: config.publicBaseUrl,
    addons: config.addons,
    accountAddons: config.accountAddons || [],
    account: {
      authenticated: Boolean(config.stremioAuthKey),
      email: config.stremioUser?.email || "",
      userId: config.stremioUser?._id || config.stremioUser?.id || ""
    },
    cacheSize: config.cacheSize,
    transcodeTorrents: config.transcodeTorrents,
    port: PORT,
    version: VERSION
  };
}
function baseFromRequest(req) {
  if (config.publicBaseUrl) return config.publicBaseUrl;
  return "http://" + String(req.headers.host || ("127.0.0.1:" + PORT));
}
function safeHttpUrl(raw) {
  const u = new URL(raw);
  if (!["http:", "https:"].includes(u.protocol) || u.username || u.password) throw new Error("URL HTTP/HTTPS inválida.");
  return u;
}
function normalizeManifestUrl(raw) {
  const u = safeHttpUrl(String(raw).trim());
  if (!/\/manifest\.json$/i.test(u.pathname)) u.pathname = u.pathname.replace(/\/+$/, "") + "/manifest.json";
  u.hash = "";
  return u;
}
function addonResourceUrl(manifestRaw, resourcePath) {
  const manifest = normalizeManifestUrl(manifestRaw);
  const prefix = manifest.pathname.replace(/\/manifest\.json$/i, "").replace(/\/+$/, "");
  const u = new URL(manifest.origin + prefix + "/" + resourcePath);
  u.search = manifest.search;
  return u;
}
async function getJson(rawUrl, options = {}) {
  const u = safeHttpUrl(rawUrl);
  const response = await fetch(u, {
    method: options.method || "GET",
    headers: { "user-agent": "Stremio-Roku-Bridge/" + VERSION, ...(options.headers || {}) },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    signal: AbortSignal.timeout(options.timeout || 12000),
    redirect: "follow"
  });
  const txt = await response.text();
  if (!response.ok) throw new Error(String(response.status) + " " + response.statusText + " em " + u.host + u.pathname);
  try { return txt ? JSON.parse(txt) : {}; } catch { throw new Error("O endpoint não retornou JSON válido."); }
}
function errText(error) { return String(error?.message || error || "Erro desconhecido").slice(0, 400); }
function listAddons() {
  const urls = [...(config.addons || []), ...(config.accountAddons || [])];
  return [...new Set(urls.map(raw => {
    try { return normalizeManifestUrl(raw).href; } catch { return null; }
  }).filter(Boolean))];
}
function addMediaEntry(url, headers = {}, publicBase = baseGlobalForMedia, streamFormat = "mp4") {
  const id = crypto.randomBytes(18).toString("base64url");
  mediaEntries.set(id, { url: String(url), headers, publicBase, streamFormat, expires: Date.now() + MEDIA_TTL });
  playbackEntries.set(id, { kind: "url", url: String(url), headers, streamFormat, expires: Date.now() + MEDIA_TTL });
  if (mediaEntries.size > MAX_MEDIA_ENTRIES) {
    for (const [key, item] of mediaEntries) if (item.expires < Date.now()) mediaEntries.delete(key);
    while (mediaEntries.size > MAX_MEDIA_ENTRIES) mediaEntries.delete(mediaEntries.keys().next().value);
  }
  return id;
}
function guessFormat(rawUrl, filename = "") {
  const candidate = String(filename || rawUrl || "").toLowerCase().split("?")[0].split("#")[0];
  if (candidate.endsWith(".m3u8")) return "hls";
  if (candidate.endsWith(".mpd")) return "dash";
  return "mp4";
}
function checkFfmpeg() {
  if (!ffmpegAvailablePromise) {
    ffmpegAvailablePromise = new Promise(resolve => {
      const child = spawn(process.env.FFMPEG_PATH || "ffmpeg", ["-version"], { stdio: "ignore", windowsHide: true });
      child.once("error", () => resolve(false));
      child.once("exit", code => resolve(code === 0));
    });
  }
  return ffmpegAvailablePromise;
}
function addTorrentPlayback(stream, streamUrl, idx) {
  const id = crypto.randomBytes(18).toString("base64url");
  playbackEntries.set(id, {
    kind: "torrent", url: streamUrl, infoHash: String(stream.infoHash || "").toLowerCase(),
    fileIdx: idx, title: stream.name || stream.title || "Torrent",
    streamFormat: guessFormat(streamUrl, stream.behaviorHints?.filename),
    expires: Date.now() + MEDIA_TTL
  });
  return id;
}
async function startTranscode(id, entry, req) {
  const old = transcodeSessions.get(id);
  if (old && old.expires > Date.now()) return old;
  const dir = path.join(TRANSCODE_DIR, id);
  fs.mkdirSync(dir, { recursive: true });
  const playlist = path.join(dir, "index.m3u8");
  const segment = path.join(dir, "segment%06d.ts");
  const args = [
    "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-i", entry.url, "-map", "0:v:0?", "-map", "0:a:0?",
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "24",
    "-vf", "scale=w='min(1280,iw)':h=-2",
    "-c:a", "aac", "-b:a", "160k", "-ac", "2",
    "-f", "hls", "-hls_time", "6", "-hls_list_size", "0",
    "-hls_flags", "independent_segments+temp_file",
    "-hls_segment_filename", segment, playlist
  ];
  const child = spawn(process.env.FFMPEG_PATH || "ffmpeg", args, {
    stdio: ["ignore", "ignore", "pipe"], windowsHide: true
  });
  let stderr = "";
  let spawnError = "";
  child.stderr.on("data", chunk => { stderr = (stderr + chunk.toString()).slice(-3000); });
  child.on("error", e => { spawnError = errText(e); });
  const session = { child, dir, expires: Date.now() + MEDIA_TTL, stderr: () => stderr };
  transcodeSessions.set(id, session);
  child.once("exit", () => { session.expires = Date.now() + 4 * 60 * 60 * 1000; });
  const started = Date.now();
  while (Date.now() - started < 25000) {
    if (fs.existsSync(playlist) && fs.readdirSync(dir).some(name => name.endsWith(".ts"))) return session;
    if (spawnError) throw new Error("Não foi possível iniciar o FFmpeg: " + spawnError);
    if (child.exitCode !== null) throw new Error("FFmpeg terminou sem gerar HLS: " + (stderr || "verifique os codecs e a fonte."));
    await new Promise(resolve => setTimeout(resolve, 400));
  }
  child.kill("SIGTERM");
  transcodeSessions.delete(id);
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  throw new Error("FFmpeg não conseguiu iniciar a transcodificação em 25 s: " + (stderr || "a fonte ainda pode estar carregando."));
}
function signedMediaPath(id, rawUrl) {
  const target = safeHttpUrl(rawUrl).href;
  const signature = crypto.createHmac("sha256", config.secret).update(id + "\n" + target).digest("hex");
  return "/media/" + id + "/" + signature + "/" + Buffer.from(target).toString("base64url");
}
function mediaUrl(req, id, rawUrl) { return baseFromRequest(req) + signedMediaPath(id, rawUrl); }
function normalType(value) { return ["movie", "series"].includes(String(value).toLowerCase()) ? String(value).toLowerCase() : "movie"; }

async function getCatalog(type, search) {
  type = normalType(type);
  const searchPart = search ? "/search=" + encodeURIComponent(search) : "";
  const main = await getJson("https://v3-cinemeta.strem.io/catalog/" + type + "/top" + searchPart + ".json");
  const metas = Array.isArray(main.metas) ? main.metas : [];
  const extraResults = [];
  for (const addonUrl of listAddons()) {
    try {
      const manifest = await getJson(normalizeManifestUrl(addonUrl).href, { timeout: 7000 });
      for (const catalog of (manifest.catalogs || [])) {
        if (!catalog || catalog.type !== type || !catalog.id) continue;
        const extras = Array.isArray(catalog.extra) ? catalog.extra : [];
        if (search && !extras.some(x => x.name === "search")) continue;
        const resource = "catalog/" + type + "/" + encodeURIComponent(catalog.id) + searchPart + ".json";
        const result = await getJson(addonResourceUrl(addonUrl, resource).href, { timeout: 7000 });
        for (const meta of (result.metas || [])) extraResults.push(meta);
        if (extraResults.length >= 100) break;
      }
    } catch { /* An optional add-on must not break the full catalog. */ }
    if (extraResults.length >= 100) break;
  }
  const seen = new Set();
  return [...metas, ...extraResults].filter(meta => {
    const key = String(meta.type || type) + ":" + String(meta.id || meta.name || "");
    if (!meta.id && !meta.name || seen.has(key)) return false;
    seen.add(key);
    return true;
  }).slice(0, 100);
}
async function getMeta(type, id) {
  const response = await getJson("https://v3-cinemeta.strem.io/meta/" + normalType(type) + "/" + encodeURIComponent(id) + ".json");
  if (response.meta) return response.meta;
  if (response.id) return response;
  throw new Error("Não foi possível carregar os detalhes deste título.");
}
function streamHeaders(stream) {
  const request = stream.behaviorHints?.proxyHeaders?.request || stream.behaviorHints?.headers || {};
  const headers = {};
  for (const [name, value] of Object.entries(request)) {
    if (typeof value === "string" && !["host", "content-length", "connection"].includes(name.toLowerCase())) headers[name] = value;
  }
  return headers;
}
async function serverFetch(pathname, init = {}) {
  const endpoint = config.streamingServerUrl + "/" + pathname.replace(/^\/+/, "");
  return await fetch(endpoint, {
    method: init.method || "GET",
    headers: { "user-agent": "Stremio-Roku-Bridge/" + VERSION, ...(init.headers || {}) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(init.timeout || 10000),
    redirect: "manual"
  });
}
async function serverJson(pathname, init = {}) {
  const response = await serverFetch(pathname, init);
  if (response.status < 200 || response.status >= 300) {
    const body = await response.text().catch(() => "");
    throw new Error("Stremio Streaming Server retornou " + response.status + (body ? ": " + body.slice(0, 150) : ""));
  }
  return await response.json().catch(() => ({}));
}
async function createTorrentStream(stream, req) {
  const hash = String(stream.infoHash || "").toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(hash)) throw new Error("infoHash do torrent inválido.");
  const sources = Array.isArray(stream.sources) ? stream.sources : [];
  const announce = sources.map(s => String(s).replace(/^tracker:/i, "")).filter(s => /^https?:\/\/|^udp:\/\//i.test(s));
  const body = { announce };
  if (Array.isArray(stream.fileMustInclude) && stream.fileMustInclude.length) body.fileMustInclude = stream.fileMustInclude;
  if (stream.fileIdx !== undefined && Number.isInteger(Number(stream.fileIdx))) body.guessFileIdx = String(stream.fileIdx);
  else if (stream.behaviorHints?.filename) body.guessFileIdx = String(stream.behaviorHints.filename);
  await serverJson(hash + "/create", { method: "POST", body, timeout: 20000 });
  const idx = Number.isInteger(Number(stream.fileIdx)) && Number(stream.fileIdx) >= 0 ? Number(stream.fileIdx) : -1;
  return {
    url: baseFromRequest(req) + "/media/torrent/" + hash + "/" + idx,
    playbackId: addTorrentPlayback(stream, config.streamingServerUrl + "/" + hash + "/" + idx, idx),
    streamFormat: guessFormat("", stream.behaviorHints?.filename),
    name: stream.name || stream.title || "Torrent",
    description: stream.description || "",
    sourceType: "torrent",
    infoHash: hash,
    fileIdx: idx
  };
}
async function getStreams(type, videoId, req) {
  type = normalType(type);
  const candidates = [];
  for (const addonUrl of listAddons()) {
    try {
      const manifest = await getJson(normalizeManifestUrl(addonUrl).href, { timeout: 7000 });
      if (manifest.resources && !manifest.resources.some(r => (typeof r === "string" ? r : r.name) === "stream")) continue;
      if (manifest.types && !manifest.types.includes(type)) continue;
      const resource = "stream/" + type + "/" + encodeURIComponent(videoId) + ".json";
      const payload = await getJson(addonResourceUrl(addonUrl, resource).href, { timeout: 16000 });
      for (const stream of payload.streams || []) candidates.push({ ...stream, _addonName: manifest.name || "Add-on" });
    } catch (e) {
      candidates.push({ _error: errText(e), _addonName: "Add-on" });
    }
  }
  // Read Stremio's local-file add-on when the local Streaming Server exposes it.
  try {
    const payload = await getJson(config.streamingServerUrl + "/local-addon/stream/" + type + "/" + encodeURIComponent(videoId) + ".json", { timeout: 5000 });
    for (const stream of payload.streams || []) candidates.push({ ...stream, _addonName: "Stremio Local Files" });
  } catch {}

  const result = [];
  const seen = new Set();
  for (const stream of candidates) {
    if (stream._error) {
      result.push({ name: "Falha no add-on", description: stream._error, unavailable: true });
      continue;
    }
    try {
      let item;
      if (stream.infoHash) {
        item = await createTorrentStream(stream, req);
      } else if (typeof stream.url === "string" && /^https?:\/\//i.test(stream.url)) {
        const headers = streamHeaders(stream);
        const format = guessFormat(stream.url, stream.behaviorHints?.filename);
        const id = addMediaEntry(stream.url, headers, baseFromRequest(req), format);
        item = {
          url: mediaUrl(req, id, stream.url),
          playbackId: id,
          streamFormat: format,
          name: stream.name || stream.title || stream.behaviorHints?.filename || "Stream direto",
          description: stream.description || "",
          sourceType: "url"
        };
      } else if (stream.ytId) {
        item = { name: stream.name || "YouTube", description: "Este add-on entrega ytId; a resolução de YouTube ainda depende de um resolvedor compatível.", unavailable: true };
      } else {
        continue;
      }
      item.addon = stream._addonName || "Add-on";
      const key = item.url || item.addon + ":" + item.name;
      if (!seen.has(key)) { seen.add(key); result.push(item); }
    } catch (e) {
      result.push({ name: stream.name || stream.title || "Fonte indisponível", description: errText(e), unavailable: true });
    }
  }
  return result.slice(0, 80);
}
async function stremioApiRequest(method, params = {}) {
  const response = await fetch("https://api.strem.io/api/" + encodeURIComponent(method), {
    method: "POST",
    headers: { "content-type": "application/json", "accept": "application/json", "user-agent": "Stremio-Roku-Bridge/" + VERSION },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(12000)
  });
  const bodyText = await response.text();
  let body;
  try { body = bodyText ? JSON.parse(bodyText) : {}; } catch { throw new Error("A API da conta Stremio retornou uma resposta inválida."); }
  if (!response.ok) throw new Error("A API da conta Stremio respondeu HTTP " + response.status + ".");
  if (body.error) {
    const message = typeof body.error === "string" ? body.error : (body.error.message || "Erro na API Stremio.");
    throw new Error(String(message).slice(0, 240));
  }
  if (Object.prototype.hasOwnProperty.call(body, "result")) return body.result;
  return body;
}
async function linkApiRequest(kind, code = "") {
  const endpoint = new URL("https://link.stremio.com/v2/" + (kind === "create" ? "create" : "read"));
  endpoint.searchParams.set("type", kind === "create" ? "Create" : "Read");
  if (kind !== "create") endpoint.searchParams.set("code", code);
  const response = await fetch(endpoint, {
    headers: { accept: "application/json", "user-agent": "Stremio-Roku-Bridge/" + VERSION },
    signal: AbortSignal.timeout(12000)
  });
  const text = await response.text();
  let payload;
  try { payload = text ? JSON.parse(text) : {}; } catch { throw new Error("O serviço de vinculação Stremio retornou uma resposta inválida."); }
  if (!response.ok) throw new Error("O serviço de vinculação Stremio respondeu HTTP " + response.status + ".");
  if (payload.error) throw new Error(typeof payload.error === "string" ? payload.error : payload.error.message || "Falha de vinculação.");
  return payload.result || payload;
}
function safeUser(user) {
  if (!user || typeof user !== "object") return null;
  return {
    _id: user._id || user.id || "",
    email: user.email || "",
    username: user.username || "",
    avatar: user.avatar || ""
  };
}
function addonDescriptorUrl(descriptor) {
  if (!descriptor || typeof descriptor !== "object") return "";
  return descriptor.transportUrl || descriptor.transport_url || descriptor.url || descriptor.endpoint || "";
}
function normalizeLibraryItem(item) {
  if (!item || typeof item !== "object" || item.removed === true) return null;
  const meta = item.meta || item.content || item.item || item;
  const id = item.id || meta.id || item._id;
  const type = item.type || meta.type;
  const name = item.name || meta.name || item.title || meta.title;
  if (!id || !name || !["movie", "series"].includes(String(type).toLowerCase())) return null;
  const state = item.state && typeof item.state === "object" ? item.state : {};
  const watched = Number(state.timeWatched || state.timeOffset || state.time_watched || 0);
  const duration = Number(state.duration || 0);
  const progress = duration > 0 ? Math.max(0, Math.min(1, watched / duration)) : 0;
  return {
    id: String(id),
    type: String(type).toLowerCase(),
    name: String(name),
    title: String(name),
    poster: item.poster || meta.poster || "",
    background: item.background || meta.background || "",
    year: item.year || meta.year || "",
    genres: item.genres || meta.genres || [],
    state,
    progress,
    removed: false
  };
}
async function loadAccountSnapshot(authKey) {
  const results = { user: null, addonUrls: [], library: [], warnings: [] };
  try {
    const user = await stremioApiRequest("getUser", { authKey });
    if (user && typeof user === "object") results.user = safeUser(user);
  } catch (error) { results.warnings.push("Não foi possível atualizar o perfil: " + errText(error)); }
  try {
    const collection = await stremioApiRequest("addonCollectionGet", { authKey, update: true });
    const descriptors = Array.isArray(collection.addons) ? collection.addons : [];
    results.addonUrls = [...new Set(descriptors.map(addonDescriptorUrl).filter(Boolean).map(raw => {
      try { return normalizeManifestUrl(raw).href; } catch { return ""; }
    }).filter(Boolean))];
    if (!descriptors.length && config.accountAddons.length) results.addonUrls = [];
  } catch (error) { results.warnings.push("A lista de add-ons da conta não foi sincronizada: " + errText(error)); }
  try {
    const libraryResponse = await stremioApiRequest("datastoreGet", { authKey, collection: "libraryItem", ids: [], all: true });
    const source = Array.isArray(libraryResponse) ? libraryResponse : (Array.isArray(libraryResponse.items) ? libraryResponse.items : []);
    results.library = source.map(normalizeLibraryItem).filter(Boolean);
  } catch (error) { results.warnings.push("A biblioteca da conta não foi sincronizada: " + errText(error)); }
  return results;
}
async function attachStremioAuthKey(candidateKey) {
  if (!candidateKey || typeof candidateKey !== "string") throw new Error("A vinculação não retornou uma chave de sessão válida.");
  const authResult = await stremioApiRequest("loginWithToken", { token: candidateKey });
  const authKey = authResult.authKey || authResult.auth_key || candidateKey;
  const user = safeUser(authResult.user);
  if (!user || (!user._id && !user.email)) throw new Error("O Stremio não confirmou a conta vinculada. Tente novamente.");
  config.stremioAuthKey = authKey;
  config.stremioUser = user;
  const snapshot = await loadAccountSnapshot(authKey);
  if (snapshot.user) config.stremioUser = snapshot.user;
  config.accountAddons = snapshot.addonUrls;
  saveConfig();
  return { account: publicConfig().account, addonCount: snapshot.addonUrls.length, libraryCount: snapshot.library.length, warnings: snapshot.warnings };
}
async function requireStremioAuth() {
  if (!config.stremioAuthKey) throw new Error("Entre na conta Stremio pela opção Conta Stremio no Roku.");
  return config.stremioAuthKey;
}

function pickResponseHeaders(input) {
  const output = {};
  for (const key of ["content-type", "content-length", "content-range", "accept-ranges", "cache-control", "last-modified", "etag", "expires", "transfermode.dlna.org", "contentfeatures.dlna.org"]) {
    if (input[key] !== undefined) output[key] = input[key];
  }
  output["Access-Control-Allow-Origin"] = "*";
  return output;
}
function proxyRequest(req, res, rawTarget, extraHeaders = {}, redirects = 0, mediaId = null) {
  let target;
  try { target = safeHttpUrl(rawTarget); }
  catch { return json(res, 400, { ok: false, error: "URL de mídia não suportada." }); }
  if (redirects > 6) return json(res, 502, { ok: false, error: "Redirecionamentos demais na origem." });
  const headers = { "User-Agent": "Stremio-Roku-Bridge/" + VERSION, "Accept": req.headers.accept || "*/*", ...extraHeaders };
  for (const key of ["range", "if-range", "accept-language"]) if (req.headers[key]) headers[key] = req.headers[key];
  delete headers.host; delete headers.Host;
  const transport = target.protocol === "https:" ? https : http;
  const upstream = transport.request(target, { method: req.method, headers, timeout: 30000 }, up => {
    if ([301, 302, 303, 307, 308].includes(up.statusCode || 0) && up.headers.location) {
      up.resume();
      return proxyRequest(req, res, new URL(up.headers.location, target).href, extraHeaders, redirects + 1, mediaId);
    }
    const contentType = String(up.headers["content-type"] || "");
    const isPlaylist = /mpegurl/i.test(contentType) || /\.m3u8(?:$|[?#])/i.test(target.href);
    if (isPlaylist && req.method !== "HEAD" && (up.statusCode || 500) < 400 && mediaId) {
      const chunks = [];
      let total = 0;
      up.on("data", chunk => {
        total += chunk.length;
        if (total > 6 * 1024 * 1024) up.destroy(new Error("Playlist muito grande."));
        else chunks.push(chunk);
      });
      up.on("end", () => {
        const original = Buffer.concat(chunks).toString("utf8");
        const rewrite = value => {
          try { return mediaUrlFromEntry(mediaId, new URL(value, target).href); }
          catch { return value; }
        };
        let bodyText = original.replace(/URI="([^"]+)"/g, (_m, uri) => 'URI="' + rewrite(uri) + '"');
        bodyText = bodyText.split(/\r?\n/).map(line => {
          const trimmed = line.trim();
          return (!trimmed || trimmed.startsWith("#")) ? line : rewrite(trimmed);
        }).join("\n");
        const body = Buffer.from(bodyText);
        const outHeaders = pickResponseHeaders(up.headers);
        outHeaders["Content-Type"] = contentType || "application/vnd.apple.mpegurl";
        outHeaders["Content-Length"] = String(body.length);
        res.writeHead(up.statusCode || 200, outHeaders);
        res.end(body);
      });
      up.on("error", e => { if (!res.headersSent) json(res, 502, { ok:false, error: errText(e) }); else res.destroy(e); });
      return;
    }
    res.writeHead(up.statusCode || 502, pickResponseHeaders(up.headers));
    if (req.method === "HEAD") { up.resume(); res.end(); return; }
    up.pipe(res);
    up.on("error", e => { if (!res.headersSent) json(res, 502, { ok: false, error: errText(e) }); else res.destroy(e); });
  });
  upstream.on("timeout", () => upstream.destroy(new Error("Tempo limite da origem excedido.")));
  upstream.on("error", e => { if (!res.headersSent) json(res, 502, { ok: false, error: "Servidor de mídia indisponível: " + errText(e) }); else res.destroy(e); });
  upstream.end();
}
function mediaUrlFromEntry(id, target) {
  const entry = mediaEntries.get(id);
  if (!entry || entry.expires < Date.now()) throw new Error("Sessão de mídia expirada.");
  return entry.publicBase + signedMediaPath(id, target);
}
let baseGlobalForMedia = "http://127.0.0.1:" + PORT;
function setBaseGlobal(req) { baseGlobalForMedia = baseFromRequest(req); }

async function route(req, res) {
  if (req.method === "OPTIONS") return noContent(res);
  let url;
  try { url = new URL(req.url, "http://" + (req.headers.host || ("127.0.0.1:" + PORT))); }
  catch { return json(res, 400, { ok: false, error: "URL inválida." }); }
  setBaseGlobal(req);
  if (url.pathname === "/" && req.method === "GET") {
    try { return html(res, 200, fs.readFileSync(path.join(HERE, "public", "index.html"), "utf8")); }
    catch { return html(res, 500, "Dashboard ausente. Baixe o repositório completo."); }
  }
  if (url.pathname === "/api/health" && req.method === "GET") return json(res, 200, { ok: true, version: VERSION, service: "Stremio Roku Bridge" });
  if (url.pathname === "/api/setup/status" && req.method === "GET") {
    let streamingServer = { reachable: false, url: config.streamingServerUrl, error: "" };
    try {
      const heartbeat = await serverJson("heartbeat", { timeout: 3000 });
      streamingServer = { reachable: true, url: config.streamingServerUrl, heartbeat };
    } catch (error) {
      streamingServer.error = errText(error);
    }
    return json(res, 200, {
      ok: true,
      service: "Stremio Roku Bridge",
      version: VERSION,
      companion: { reachable: true, host: req.headers.host || "", port: PORT },
      streamingServer,
      account: publicConfig().account,
      addOnCount: listAddons().length
    });
  }

  if (url.pathname === "/api/pair" && req.method === "POST") {
    try {
      const body = await parseBody(req);
      const verdict = verifyPin(req, body.pin || "");
      if (!verdict.ok) return json(res, verdict.limited ? 429 : 401, { ok: false, error: verdict.limited ? "Muitas tentativas de PIN. Aguarde cinco minutos." : "PIN incorreto." });
      const token = crypto.randomBytes(32).toString("hex");
      sessions.set(token, { expires: Date.now() + 30 * 24 * 60 * 60 * 1000 });
      return json(res, 200, { ok: true, token, expiresIn: 2592000, ...publicConfig() });
    } catch (e) { return json(res, e.statusCode || 400, { ok: false, error: errText(e) }); }
  }
  if (url.pathname.startsWith("/api/admin/")) {
    if (!requirePin(req, res)) return;
    if (url.pathname === "/api/admin/config" && req.method === "GET") return json(res, 200, { ok: true, config: publicConfig() });
    if (url.pathname === "/api/admin/config" && req.method === "PUT") {
      try {
        const body = await parseBody(req);
        if (body.streamingServerUrl !== undefined) config.streamingServerUrl = cleanBase(body.streamingServerUrl);
        if (body.publicBaseUrl !== undefined) config.publicBaseUrl = body.publicBaseUrl ? cleanBase(body.publicBaseUrl) : "";
        if (body.transcodeTorrents !== undefined) config.transcodeTorrents = Boolean(body.transcodeTorrents);
        if (body.cacheSize !== undefined) {
          const n = Number(body.cacheSize);
          if (!Number.isInteger(n) || n < 0 || n > 17179869184) throw new Error("Cache deve estar entre 0 e 16 GiB.");
          config.cacheSize = n;
        }
        if (Array.isArray(body.addons)) {
          if (body.addons.length > 100) throw new Error("Máximo de 100 add-ons.");
          config.addons = [...new Set(body.addons.map(item => normalizeManifestUrl(String(item)).href))];
        }
        saveConfig();
        let streamingSettingsUpdated = false;
        try {
          const current = await serverJson("settings", { timeout: 2500 });
          const existing = current.settings && typeof current.settings === "object" ? current.settings : current;
          await serverJson("settings", { method: "POST", body: { ...existing, cacheSize: config.cacheSize }, timeout: 3000 });
          streamingSettingsUpdated = true;
        } catch {}
        return json(res, 200, { ok: true, config: publicConfig(), streamingSettingsUpdated });
      } catch (e) { return json(res, e.statusCode || 400, { ok: false, error: errText(e) }); }
    }
    if (url.pathname === "/api/admin/server/status" && req.method === "GET") {
      try {
        const heartbeat = await serverJson("heartbeat", { timeout: 3500 });
        let settings = {};
        try { settings = await serverJson("settings", { timeout: 3500 }); } catch {}
        return json(res, 200, { ok: true, connected: true, streamingServerUrl: config.streamingServerUrl, heartbeat, settings, cacheSize: config.cacheSize, addonCount: config.addons.length });
      } catch (e) {
        return json(res, 200, { ok: true, connected: false, streamingServerUrl: config.streamingServerUrl, error: errText(e), addonCount: config.addons.length });
      }
    }
    if (url.pathname === "/api/admin/server/settings" && req.method === "GET") {
      try {
        const response = await serverJson("settings", { timeout: 5000 });
        const settings = response.settings && typeof response.settings === "object" ? response.settings : response;
        return json(res, 200, { ok: true, settings });
      } catch (e) {
        return json(res, 502, { ok: false, error: "Não foi possível ler as configurações do Streaming Server: " + errText(e) });
      }
    }
    if (url.pathname === "/api/admin/server/settings" && req.method === "PUT") {
      try {
        const body = await parseBody(req);
        if (!body.settings || typeof body.settings !== "object" || Array.isArray(body.settings)) throw new Error("Envie um objeto JSON de configurações.");
        const settings = body.settings;
        const response = await serverFetch("settings", { method: "POST", body: settings, timeout: 8000 });
        if (!response.ok) throw new Error("O servidor recusou as configurações (HTTP " + response.status + ").");
        if (Number.isInteger(Number(settings.cacheSize)) && Number(settings.cacheSize) >= 0) {
          config.cacheSize = Number(settings.cacheSize);
          saveConfig();
        }
        return json(res, 200, { ok: true, settings });
      } catch (e) { return json(res, 400, { ok: false, error: errText(e) }); }
    }
    if (url.pathname === "/api/admin/test-addon" && req.method === "POST") {
      try {
        const body = await parseBody(req);
        const manifestUrl = normalizeManifestUrl(body.url).href;
        const manifest = await getJson(manifestUrl);
        if (!manifest.id || !manifest.name || !manifest.version) throw new Error("O manifesto precisa conter id, name e version.");
        return json(res, 200, { ok: true, manifest: { id: manifest.id, name: manifest.name, version: manifest.version, description: manifest.description || "", resources: manifest.resources || [], types: manifest.types || [], catalogs: manifest.catalogs || [] }, manifestUrl });
      } catch (e) { return json(res, 400, { ok: false, error: errText(e) }); }
    }
    return json(res, 404, { ok: false, error: "Endpoint administrativo não encontrado." });
  }
  if (url.pathname.startsWith("/api/")) {
    if (!requireSession(req, res)) return;
    try {
      if (url.pathname === "/api/config" && req.method === "GET") return json(res, 200, { ok: true, config: publicConfig() });
      if (url.pathname === "/api/account/status" && req.method === "GET") {
        const authKey = config.stremioAuthKey;
        if (!authKey) return json(res, 200, { ok: true, authenticated: false, account: publicConfig().account });
        return json(res, 200, { ok: true, authenticated: true, account: publicConfig().account, addonCount: (config.accountAddons || []).length });
      }
      if (url.pathname === "/api/account/link/start" && req.method === "POST") {
        const link = await linkApiRequest("create");
        const code = String(link.code || link.linkCode || "");
        if (!code) throw new Error("O Stremio não retornou um código de vinculação. Verifique a disponibilidade do serviço de login.");
        return json(res, 200, {
          ok: true,
          code,
          link: String(link.link || link.url || ""),
          qrcode: String(link.qrcode || link.qrCode || ""),
          instructions: "Abra o link em um celular ou PC, entre na conta Stremio e conclua a vinculação com o código mostrado na TV."
        });
      }
      if (url.pathname === "/api/account/link/check" && req.method === "POST") {
        const body = await parseBody(req);
        const code = String(body.code || "").trim();
        if (!/^[A-Za-z0-9-]{3,80}$/.test(code)) throw new Error("Código de vinculação inválido.");
        let linked;
        try { linked = await linkApiRequest("read", code); }
        catch (error) {
          return json(res, 200, { ok: true, linked: false, message: "Ainda não há uma sessão vinculada. Autorize o código no link Stremio e tente novamente." });
        }
        const candidate = linked.authKey || linked.auth_key || linked.token || linked.data?.authKey || linked.data?.auth_key;
        if (!candidate) return json(res, 200, { ok: true, linked: false, message: "Ainda não há uma sessão vinculada. Autorize o código no link Stremio e tente novamente." });
        const result = await attachStremioAuthKey(String(candidate));
        return json(res, 200, { ok: true, linked: true, ...result });
      }
      if (url.pathname === "/api/account/sync" && req.method === "POST") {
        const authKey = await requireStremioAuth();
        const snapshot = await loadAccountSnapshot(authKey);
        if (snapshot.user) config.stremioUser = snapshot.user;
        config.accountAddons = snapshot.addonUrls;
        saveConfig();
        return json(res, 200, { ok: true, account: publicConfig().account, addonCount: snapshot.addonUrls.length, libraryCount: snapshot.library.length, warnings: snapshot.warnings });
      }
      if (url.pathname === "/api/account/library" && req.method === "GET") {
        const authKey = await requireStremioAuth();
        const libraryResponse = await stremioApiRequest("datastoreGet", { authKey, collection: "libraryItem", ids: [], all: true });
        const source = Array.isArray(libraryResponse) ? libraryResponse : (Array.isArray(libraryResponse.items) ? libraryResponse.items : []);
        let items = source.map(normalizeLibraryItem).filter(Boolean);
        if (url.searchParams.get("mode") === "continue") {
          items = items.filter(item => item.progress > 0.01 && item.progress < 0.7);
          items.sort((a, b) => b.progress - a.progress);
        } else {
          items.sort((a, b) => String(b.name).localeCompare(String(a.name)));
        }
        return json(res, 200, { ok: true, items, account: publicConfig().account });
      }
      if (url.pathname === "/api/account/logout" && req.method === "POST") {
        if (config.stremioAuthKey) {
          try { await stremioApiRequest("logout", { authKey: config.stremioAuthKey }); } catch {}
        }
        config.stremioAuthKey = "";
        config.stremioUser = null;
        config.accountAddons = [];
        saveConfig();
        return json(res, 200, { ok: true, account: publicConfig().account });
      }

      if (url.pathname === "/api/server/status" && req.method === "GET") {
        try {
          const heartbeat = await serverJson("heartbeat", { timeout: 3500 });
          let settings = {};
          try { settings = await serverJson("settings", { timeout: 3500 }); } catch {}
          return json(res, 200, { ok: true, connected: true, streamingServerUrl: config.streamingServerUrl, heartbeat, settings, cacheSize: config.cacheSize, addonCount: config.addons.length });
        } catch (e) {
          return json(res, 200, { ok: true, connected: false, streamingServerUrl: config.streamingServerUrl, error: errText(e), addonCount: config.addons.length });
        }
      }
      if (url.pathname === "/api/catalog" && req.method === "GET") {
        const metas = await getCatalog(url.searchParams.get("type") || "movie", (url.searchParams.get("search") || "").slice(0, 120));
        return json(res, 200, { ok: true, metas });
      }
      if (url.pathname === "/api/meta" && req.method === "GET") {
        const meta = await getMeta(url.searchParams.get("type") || "movie", url.searchParams.get("id") || "");
        return json(res, 200, { ok: true, meta });
      }
      if (url.pathname === "/api/episodes" && req.method === "GET") {
        const meta = await getMeta("series", url.searchParams.get("id") || "");
        return json(res, 200, { ok: true, episodes: meta.videos || [], meta });
      }
      if (url.pathname === "/api/playback" && req.method === "GET") {
        const id = url.searchParams.get("id") || "";
        const entry = playbackEntries.get(id);
        if (!entry || entry.expires < Date.now()) return json(res, 410, { ok: false, error: "Sessão de reprodução expirada. Selecione a fonte novamente." });
        if (entry.kind === "torrent" && config.transcodeTorrents && await checkFfmpeg()) {
          try {
            await startTranscode(id, entry, req);
            return json(res, 200, { ok: true, url: baseFromRequest(req) + "/transcodes/" + id + "/index.m3u8", streamFormat: "hls", transcoded: true, title: entry.title });
          } catch (e) {
            return json(res, 200, { ok: true, url: baseFromRequest(req) + "/media/torrent/" + entry.infoHash + "/" + entry.fileIdx, streamFormat: entry.streamFormat || "mp4", transcoded: false, warning: errText(e), title: entry.title });
          }
        }
        const playUrl = entry.kind === "torrent"
          ? baseFromRequest(req) + "/media/torrent/" + entry.infoHash + "/" + entry.fileIdx
          : mediaUrl(req, id, entry.url);
        return json(res, 200, { ok: true, url: playUrl, streamFormat: entry.streamFormat || "mp4", transcoded: false, title: entry.title || "" });
      }
      if (url.pathname === "/api/streams" && req.method === "GET") {
        const type = url.searchParams.get("type") || "movie";
        const videoId = url.searchParams.get("videoId") || "";
        if (!videoId) return json(res, 400, { ok: false, error: "videoId obrigatório." });
        const streams = await getStreams(type, videoId, req);
        return json(res, 200, { ok: true, streams });
      }
      if (url.pathname === "/api/server/settings" && req.method === "GET") {
        try {
          const settings = await serverJson("settings", { timeout: 3500 });
          return json(res, 200, { ok: true, available: true, settings, cacheSize: config.cacheSize, streamingServerUrl: config.streamingServerUrl });
        } catch (e) {
          return json(res, 200, { ok: true, available: false, settings: {}, cacheSize: config.cacheSize, streamingServerUrl: config.streamingServerUrl, error: errText(e) });
        }
      }
      if (url.pathname === "/api/server/settings" && req.method === "PUT") {
        const body = await parseBody(req);
        const size = Number(body.cacheSize);
        if (!Number.isInteger(size) || size < 0 || size > 17179869184) return json(res, 400, { ok:false, error:"Cache deve estar entre 0 e 16 GiB." });
        config.cacheSize = size;
        saveConfig();
        try {
          const current = await serverJson("settings", { timeout: 3500 });
          const existing = current.settings && typeof current.settings === "object" ? current.settings : current;
          await serverJson("settings", { method: "POST", body: { ...existing, cacheSize: size }, timeout: 5000 });
          return json(res, 200, { ok: true, cacheSize: size, serverUpdated: true });
        } catch (e) {
          return json(res, 200, { ok: true, cacheSize: size, serverUpdated: false, note: "Cache salvo no bridge. A API de configurações do servidor não aceitou a alteração: " + errText(e) });
        }
      }
      return json(res, 404, { ok: false, error: "API não encontrada." });
    } catch (e) { return json(res, e.statusCode || 502, { ok: false, error: errText(e) }); }
  }

  const transcodeMatch = url.pathname.match(/^\/transcodes\/([A-Za-z0-9_-]{10,})\/(index\.m3u8|segment\d{6}\.ts)$/);
  if (transcodeMatch && ["GET", "HEAD"].includes(req.method)) {
    const id = transcodeMatch[1], filename = transcodeMatch[2];
    const session = transcodeSessions.get(id);
    if (!session || session.expires < Date.now()) return json(res, 410, { ok: false, error: "Transcodificação expirada." });
    session.expires = Date.now() + 4 * 60 * 60 * 1000;
    const filePath = path.join(session.dir, filename);
    if (!fs.existsSync(filePath)) return json(res, 404, { ok: false, error: "Segmento ainda não foi gerado." });
    const stat = fs.statSync(filePath);
    res.writeHead(200, {
      "Content-Type": filename.endsWith(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t",
      "Content-Length": stat.size,
      "Cache-Control": filename.endsWith(".m3u8") ? "no-cache" : "public, max-age=60",
      "Access-Control-Allow-Origin": "*",
      "Accept-Ranges": "none"
    });
    if (req.method === "HEAD") return res.end();
    return fs.createReadStream(filePath).pipe(res);
  }
  const torrent = url.pathname.match(/^\/media\/torrent\/([a-f0-9]{40})\/(-?\d+)$/i);
  if (torrent && ["GET", "HEAD"].includes(req.method)) return proxyRequest(req, res, config.streamingServerUrl + "/" + torrent[1] + "/" + torrent[2]);
  const media = url.pathname.match(/^\/media\/([A-Za-z0-9_-]{10,})\/([a-f0-9]{64})\/([A-Za-z0-9_-]+)$/);
  if (media && ["GET", "HEAD"].includes(req.method)) {
    const id = media[1], signature = media[2], encoded = media[3];
    const entry = mediaEntries.get(id);
    if (!entry || entry.expires < Date.now()) {
      mediaEntries.delete(id);
      return json(res, 410, { ok: false, error: "Sessão expirada. Selecione a fonte novamente." });
    }
    let target;
    try { target = safeHttpUrl(Buffer.from(encoded, "base64url").toString("utf8")).href; }
    catch { return json(res, 400, { ok: false, error: "URL de mídia inválida." }); }
    const expected = crypto.createHmac("sha256", config.secret).update(id + "\n" + target).digest("hex");
    if (!safeEqual(signature, expected)) return json(res, 403, { ok: false, error: "Assinatura de mídia inválida." });
    return proxyRequest(req, res, target, entry.headers, 0, id);
  }
  return json(res, 404, { ok: false, error: "Não encontrado." });
}

const cleanupTimer = setInterval(() => {
  const now = Date.now();
  for (const [id, entry] of mediaEntries) if (entry.expires < now) mediaEntries.delete(id);
  for (const [id, entry] of playbackEntries) if (entry.expires < now) playbackEntries.delete(id);
  for (const [id, session] of transcodeSessions) {
    if (session.expires >= now) continue;
    if (session.child && session.child.exitCode === null) session.child.kill("SIGTERM");
    transcodeSessions.delete(id);
    try { fs.rmSync(session.dir, { recursive: true, force: true }); } catch {}
  }
}, 10 * 60 * 1000);
cleanupTimer.unref();

const server = http.createServer((req, res) => {
  route(req, res).catch(e => {
    if (!res.headersSent) json(res, e.statusCode || 500, { ok: false, error: errText(e) });
    else res.destroy(e);
  });
});
server.listen(PORT, HOST, () => {
  const interfaces = Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === "IPv4" && !i.internal);
  console.log("\nStremio Roku Bridge v" + VERSION);
  console.log("Dashboard: http://127.0.0.1:" + PORT + "/");
  for (const i of interfaces) console.log("LAN:       http://" + i.address + ":" + PORT + "/");
  console.log("PIN:       " + config.pin);
  console.log("Stremio Streaming Server: " + config.streamingServerUrl);
  console.log("Mantenha este PC ligado enquanto assiste. Não exponha a porta do bridge à Internet.\n");
});
