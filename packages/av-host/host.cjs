"use strict";
// AV Host：由 QQ 自带的 Electron 以第二个进程启动（loadNapCat.js 在 QQBRIDGE_AV_HOST=1 时分流到这里），
// 通过 --register-pepper-plugins 在窗口里加载 QQ 安装目录内的 libAVSDKPlugin.so（NTRTC），
// 再把 AVSDK 插件的输出转发给 NapCat 插件，把插件发来的指令 postMessage 给 AVSDK。
//
// 改写自 ClaudiaGardner/maibot-qq-voice-call（GPL-3.0）bridge/av-host/host.cjs。
// 本项目仅自用、不分发；如需公开发布，衍生部分须遵守 GPL-3.0。

const { timingSafeEqual } = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { app, BrowserWindow, ipcMain } = require("electron");

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost"]);
/** 默认只允许：登录、接听、转发内核数据。研究模式（QQBRIDGE_LAB=1）放开，用于重放录制的指令。 */
const DEFAULT_ALLOWED_COMMANDS = new Set([1, 5, 55]);
const MAX_RECENT = 50;

function port(value, fallback, name) {
  if (value === undefined || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) throw new Error(`${name} must be a TCP port`);
  return parsed;
}

function loopback(value, name) {
  const host = value || "127.0.0.1";
  if (!LOOPBACK_HOSTS.has(host)) throw new Error(`${name} must be a loopback address`);
  return host;
}

function loadSettings(env = process.env) {
  const tokenFile = env.QQBRIDGE_CONTROL_TOKEN_FILE || "/run/qqbridge/control.token";
  const token = (env.QQBRIDGE_CONTROL_TOKEN || readIfExists(tokenFile) || "").trim();
  if (Buffer.byteLength(token, "utf8") < 32) throw new Error(`control token missing or too short (${tokenFile})`);
  return {
    host: loopback(env.QQBRIDGE_AV_HOST_HOST, "QQBRIDGE_AV_HOST_HOST"),
    listenPort: port(env.QQBRIDGE_AV_HOST_PORT, 6111, "QQBRIDGE_AV_HOST_PORT"),
    bridgeHost: loopback(env.QQBRIDGE_CONTROL_HOST, "QQBRIDGE_CONTROL_HOST"),
    bridgePort: port(env.QQBRIDGE_CONTROL_PORT, 6110, "QQBRIDGE_CONTROL_PORT"),
    token,
    lab: env.QQBRIDGE_LAB === "1",
    avsdkPath: path.resolve(env.QQBRIDGE_AVSDK_PATH || "/opt/QQ/resources/app/avsdk/libAVSDKPlugin.so"),
    profileDir: path.resolve(env.QQBRIDGE_AVHOST_PROFILE || "/app/.config/qqbridge-avhost"),
    // 视频研究：让窗口显示在 Xvfb 上并放大 embed，以便截取远端画面（见 docs/design.md 5.5）。
    show: env.QQBRIDGE_AVHOST_SHOW === "1",
    width: port(env.QQBRIDGE_AVHOST_WIDTH, 1280, "QQBRIDGE_AVHOST_WIDTH"),
    height: port(env.QQBRIDGE_AVHOST_HEIGHT, 720, "QQBRIDGE_AVHOST_HEIGHT"),
  };
}

function readIfExists(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

const settings = loadSettings();
let avWindow = null;
let nextInvocationId = 1;
let rendererState = {
  ready: false,
  pluginFound: false,
  methods: [],
  messageCount: 0,
  forwardedCount: 0,
  forwardError: null,
  invocationCount: 0,
  lastInvocationCommand: null,
  lastInvocationAt: null,
  error: null,
};
/** 最近的 AVSDK 输出（只记指令号与时间），便于排查。 */
const recentOutputs = [];

function hasValidToken(req) {
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Bearer ")) return false;
  const supplied = Buffer.from(header.slice(7), "utf8");
  const expected = Buffer.from(settings.token, "utf8");
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function sendJson(res, status, body) {
  const encoded = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": encoded.byteLength,
    "Cache-Control": "no-store",
  });
  res.end(encoded);
}

async function readJsonBody(req, limit = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new Error("request body is too large");
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : {};
}

function startControlServer() {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", `http://${settings.host}:${settings.listenPort}`);
    if (req.method === "GET" && url.pathname === "/healthz") return sendJson(res, 200, { ok: true });
    if (!hasValidToken(req)) return sendJson(res, 401, { code: -1, message: "Unauthorized" });

    if (req.method === "GET" && url.pathname === "/v1/status") {
      return sendJson(res, 200, {
        code: 0,
        data: {
          electron: process.versions.electron ?? null,
          chrome: process.versions.chrome ?? null,
          avsdkPath: settings.avsdkPath,
          lab: settings.lab,
          show: settings.show,
          bounds: avWindow?.getBounds?.() ?? null,
          recentOutputs,
          ...rendererState,
        },
      });
    }

    if (req.method === "POST" && url.pathname === "/v1/invoke") {
      try {
        const body = await readJsonBody(req);
        const command = Number(body?.command);
        const params = body?.params;
        if (!Number.isInteger(command)) return sendJson(res, 400, { code: -1, message: "invalid command" });
        if (!settings.lab && !DEFAULT_ALLOWED_COMMANDS.has(command)) {
          return sendJson(res, 400, { code: -1, message: "command is not allowed" });
        }
        if (!Array.isArray(params) || params.length > 16) return sendJson(res, 400, { code: -1, message: "invalid params" });
        if (!avWindow) return sendJson(res, 503, { code: -1, message: "AVSDK window is not ready" });
        const invocationId = nextInvocationId++;
        const result = await avWindow.webContents.executeJavaScript(
          `window.qqbridgeAVSDKInvoke(${JSON.stringify(command)},${JSON.stringify(invocationId)},${JSON.stringify(params)})`,
          true,
        );
        rendererState = {
          ...rendererState,
          invocationCount: rendererState.invocationCount + 1,
          lastInvocationCommand: command,
          lastInvocationAt: new Date().toISOString(),
        };
        return sendJson(res, 200, { code: 0, data: result ?? null });
      } catch (error) {
        return sendJson(res, 500, { code: -1, message: `AVSDK invocation failed: ${error?.message ?? error}` });
      }
    }
    return sendJson(res, 404, { code: -1, message: "Not Found" });
  });
  server.on("clientError", (_error, socket) => socket.destroy());
  server.listen(settings.listenPort, settings.host, () => {
    console.log(`[qqbridge-avhost] listening on ${settings.host}:${settings.listenPort}`);
  });
}

ipcMain.on("qqbridge-avsdk-state", (_event, incoming) => {
  rendererState = {
    ...rendererState,
    ready: Boolean(incoming?.ready),
    pluginFound: Boolean(incoming?.pluginFound),
    methods: Array.isArray(incoming?.methods) ? incoming.methods.filter((m) => typeof m === "string").slice(0, 100) : [],
    error: typeof incoming?.error === "string" ? incoming.error.slice(0, 500) : null,
  };
});

async function forwardPluginMessage(message) {
  if (!message || typeof message !== "object" || !Number.isInteger(message.cmd) || !Object.hasOwn(message, "value")) return;
  rendererState = { ...rendererState, messageCount: rendererState.messageCount + 1 };
  recentOutputs.push({ cmd: message.cmd, at: new Date().toISOString() });
  if (recentOutputs.length > MAX_RECENT) recentOutputs.shift();
  try {
    const response = await fetch(`http://${settings.bridgeHost}:${settings.bridgePort}/v1/avsdk/output`, {
      method: "POST",
      headers: { Authorization: `Bearer ${settings.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ command: message.cmd, id: Number.isInteger(message.id) ? message.id : 0, value: message.value }),
    });
    if (!response.ok) throw new Error(`bridge returned HTTP ${response.status}`);
    rendererState = { ...rendererState, forwardedCount: rendererState.forwardedCount + 1, forwardError: null };
  } catch (error) {
    rendererState = { ...rendererState, forwardError: error?.message ?? String(error) };
  }
}

ipcMain.on("qqbridge-avsdk-message", (_event, message) => {
  void forwardPluginMessage(message);
});

if (!fs.existsSync(settings.avsdkPath)) {
  throw new Error(`QQ AVSDK library was not found: ${settings.avsdkPath}`);
}
app.commandLine.appendSwitch("register-pepper-plugins", `${settings.avsdkPath};application/x-ppapi-avSDK`);
app.commandLine.appendSwitch("disable-gpu");
app.commandLine.appendSwitch("no-sandbox");
app.setPath("userData", settings.profileDir);

app
  .whenReady()
  .then(async () => {
    avWindow = new BrowserWindow({
      width: settings.show ? settings.width : 320,
      height: settings.show ? settings.height : 240,
      x: 0,
      y: 0,
      show: settings.show,
      frame: !settings.show,
      webPreferences: { contextIsolation: false, nodeIntegration: true, plugins: true, sandbox: false },
    });
    avWindow.webContents.on("render-process-gone", (_event, details) => {
      rendererState = { ...rendererState, ready: false, error: `renderer process gone: ${details.reason}` };
    });
    const size = settings.show ? { w: String(settings.width), h: String(settings.height) } : { w: "1", h: "1" };
    await avWindow.loadFile(path.join(__dirname, "host.html"), { query: size });
    startControlServer();
  })
  .catch((error) => {
    console.error(`[qqbridge-avhost] startup failed: ${error?.message ?? String(error)}`);
    process.exitCode = 1;
  });

app.on("window-all-closed", () => app.quit());
