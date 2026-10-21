import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceDir = path.dirname(here);
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "stremio-roku-bridge-"));
const probe = net.createServer();
await new Promise((resolve, reject) => probe.once("error", reject).listen(0, "127.0.0.1", resolve));
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));

const child = spawn(process.execPath, ["server.mjs"], {
  cwd: serviceDir,
  env: {
    ...process.env,
    STREMIO_BRIDGE_HOST: "127.0.0.1",
    STREMIO_BRIDGE_PORT: String(port),
    STREMIO_BRIDGE_PIN: "123456",
    STREMIO_BRIDGE_DATA: dataDir,
    STREMIO_STREAM_SERVER: "http://127.0.0.1:9"
  },
  stdio: "ignore",
  windowsHide: true
});
const base = "http://127.0.0.1:" + port;
async function waitForServer() {
  for (let attempt = 0; attempt < 50; attempt++) {
    try {
      const r = await fetch(base + "/api/health", { signal: AbortSignal.timeout(500) });
      if (r.ok) return await r.json();
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("Companion failed to start.");
}
try {
  const health = await waitForServer();
  assert.equal(health.ok, true);
  assert.equal(health.service, "Stremio Roku Bridge");

  const setup = await fetch(base + "/api/setup/status");
  assert.equal(setup.status, 200);
  const setupStatus = await setup.json();
  assert.equal(setupStatus.ok, true);
  assert.equal(setupStatus.service, "Stremio Roku Bridge");
  assert.equal(setupStatus.companion.reachable, true);
  assert.equal(setupStatus.streamingServer.reachable, false);
  assert.equal(setupStatus.account.authenticated, false);
  assert.equal(Object.hasOwn(setupStatus, "stremioAuthKey"), false);

  const badPair = await fetch(base + "/api/pair", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ pin: "000000" })
  });
  assert.equal(badPair.status, 401);

  const pair = await fetch(base + "/api/pair", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ pin: "123456" })
  });
  assert.equal(pair.status, 200);
  const paired = await pair.json();
  assert.equal(paired.ok, true);
  assert.equal(typeof paired.token, "string");

  const configResponse = await fetch(base + "/api/config", {
    headers: { authorization: "Bearer " + paired.token }
  });
  assert.equal(configResponse.status, 200);
  const current = await configResponse.json();
  assert.equal(current.ok, true);
  assert.equal(current.config.port, port);

  const forbidden = await fetch(base + "/api/admin/config");
  assert.equal(forbidden.status, 401);

  const update = await fetch(base + "/api/admin/config", {
    method: "PUT",
    headers: { "content-type": "application/json", "x-bridge-pin": "123456" },
    body: JSON.stringify({
      streamingServerUrl: "http://127.0.0.1:9",
      publicBaseUrl: "",
      cacheSize: 1073741824,
      transcodeTorrents: false,
      addons: ["https://example.org/manifest.json"]
    })
  });
  assert.equal(update.status, 200);
  const updated = await update.json();
  assert.equal(updated.ok, true);
  assert.equal(updated.config.cacheSize, 1073741824);
  assert.equal(updated.config.transcodeTorrents, false);
  assert.deepEqual(updated.config.addons, ["https://example.org/manifest.json"]);

  const statusResponse = await fetch(base + "/api/server/status", {
    headers: { authorization: "Bearer " + paired.token }
  });
  assert.equal(statusResponse.status, 200);
  const status = await statusResponse.json();
  assert.equal(status.ok, true);
  assert.equal(status.connected, false);

  console.log("Companion smoke test passed.");
} finally {
  child.kill("SIGTERM");
  await new Promise(resolve => setTimeout(resolve, 200));
  fs.rmSync(dataDir, { recursive: true, force: true });
}
