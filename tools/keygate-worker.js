// MvS - compuerta de keys de instalación (Cloudflare Worker, plan gratis).
// Hace que cada key se pueda usar UNA sola vez: el instalador consulta acá antes de instalar.
// Necesita:  un KV namespace enlazado con el nombre KEYS   y estos secretos/variables (opcionales los de Telegram):
//   ADMIN_TOKEN  clave para consultar el estado de las keys (/status)
//   TG_TOKEN     token del bot que te AVISA      TG_CHAT   tu id de Telegram
// Bot de keys dentro del Worker (opcional, así no hace falta Termux ni otra máquina):
//   BOT_TOKEN    token del bot que GENERA keys   SIGN_KEY  clave privada (PKCS8, ver README)
//   INSTALL_URL  (opcional) dirección del instalador     BOT_CHAT  (opcional) tu id; si falta se usa TG_CHAT
const PUBKEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9rSARM2xtz80JDjzI+nBe6IjvZQ0
0YUm17scKhBhHH+5KwgQTM+Y5j1EvJocTpmhrdRJkuKMuiC0PYwria2xmg==
-----END PUBLIC KEY-----`;
const TTL = 21600;          // 6 horas
const KEEP = 8 * 3600;      // cuánto se recuerda una key usada (más que su vida útil)

const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
const b64uToBytes = (s) => { s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "="; return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); };

function derToRaw(der) {            // firma ECDSA en DER (openssl) -> r||s de 64 bytes (WebCrypto)
  let i = 2; if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const readInt = () => { if (der[i] !== 0x02) throw new Error("der"); const l = der[i + 1]; let v = der.slice(i + 2, i + 2 + l); i += 2 + l;
    while (v.length > 32 && v[0] === 0) v = v.slice(1); const out = new Uint8Array(32); out.set(v, 32 - v.length); return out; };
  const r = readInt(), s = readInt(); const raw = new Uint8Array(64); raw.set(r, 0); raw.set(s, 32); return raw;
}

let pubKey;
async function getPub() {
  if (!pubKey) {
    const der = b64uToBytes(PUBKEY_PEM.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
    pubKey = await crypto.subtle.importKey("spki", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  }
  return pubKey;
}

// -> { ok, reason?, kid?, iat? }
async function checkKey(key) {
  const f = String(key || "").split(".");
  if ((f.length !== 4 && f.length !== 5) || f[0] !== "MVS") return { ok: false, reason: "invalid" };
  const iat = Number(f[1]), rnd = f[2], sig = f[f.length - 1], data = f.slice(1, -1).join(".");
  if (!/^\d{9,12}$/.test(f[1]) || !/^[a-f0-9]{6}$/.test(rnd)) return { ok: false, reason: "invalid" };
  let good = false;
  try { good = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, await getPub(), derToRaw(b64uToBytes(sig)), new TextEncoder().encode(data)); } catch (e) { good = false; }
  if (!good) return { ok: false, reason: "invalid" };
  const now = Math.floor(Date.now() / 1000);
  const kid = `${f[1]}.${rnd}`;
  if (now < iat - 300) return { ok: false, reason: "early", kid, iat };
  if (now > iat + TTL) return { ok: false, reason: "expired", kid, iat };
  return { ok: true, kid, iat };
}

async function tg(env, text) {
  if (!env.TG_TOKEN || !env.TG_CHAT) return;
  try { await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: env.TG_CHAT, text }) }); } catch (e) {}
}

async function claim(req, env, ctx) {
  let b; try { b = await req.json(); } catch (e) { return json({ ok: false, reason: "invalid" }, 400); }
  const r = await checkKey(b.key);
  const ip = req.headers.get("CF-Connecting-IP") || "?";
  const osn = String(b.os || "?").slice(0, 80);
  const info = `Key: MVS.${r.kid}\nIP: ${ip}\nSistema: ${osn}\nHora: ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC`;
  if (!r.ok) {
    if (r.reason === "expired") ctx.waitUntil(tg(env, `⚠️ MvS: intento con una key VENCIDA\n${info}`));
    return json({ ok: false, reason: r.reason }, r.reason === "invalid" ? 400 : 200);
  }
  const k = "used:" + r.kid;
  const prev = await env.KEYS.get(k);
  if (prev) {
    ctx.waitUntil(tg(env, `🚫 MvS: key YA USADA (intento de reutilizarla)\n${info}`));
    return json({ ok: false, reason: "used" });
  }
  await env.KEYS.put(k, JSON.stringify({ t: new Date().toISOString(), ip, os: osn }), { expirationTtl: KEEP });
  ctx.waitUntil(tg(env, `🔔 MvS: KEY USADA\n${info}`));
  return json({ ok: true });
}

async function status(req, env) {          // el bot de keys pregunta cuáles se usaron
  if (!env.ADMIN_TOKEN || req.headers.get("authorization") !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "no autorizado" }, 401);
  let b; try { b = await req.json(); } catch (e) { return json({ error: "json" }, 400); }
  const out = {};
  for (const kid of (b.kids || []).slice(0, 100)) {
    if (!/^\d{9,12}\.[a-f0-9]{6}$/.test(kid)) continue;
    const v = await env.KEYS.get("used:" + kid);
    out[kid] = v ? JSON.parse(v) : null;
  }
  return json(out);
}

// ---------- Bot de keys (webhook de Telegram) ----------
const DEFAULT_URL = "https://raw.githubusercontent.com/salgadomartin107-art/Script-mvs/main/mvs-install.sh";
const b64u = (u8) => btoa(String.fromCharCode(...u8)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function rawToDer(raw) {            // r||s de WebCrypto -> DER, el formato que verifica openssl en el instalador
  const num = (b) => { let i = 0; while (i < b.length - 1 && b[i] === 0) i++; b = b.slice(i); if (b[0] & 0x80) b = Uint8Array.from([0, ...b]); return Uint8Array.from([0x02, b.length, ...b]); };
  const r = num(raw.slice(0, 32)), s = num(raw.slice(32, 64));
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s]);
}

let signKey, signSrc;
async function getSign(env) {
  if (!env.SIGN_KEY) throw new Error("falta el secreto SIGN_KEY");
  if (!signKey || signSrc !== env.SIGN_KEY) {
    const body = env.SIGN_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    signKey = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(body), (c) => c.charCodeAt(0)), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    signSrc = env.SIGN_KEY;
  }
  return signKey;
}

async function makeKey(env) {
  const iat = Math.floor(Date.now() / 1000);
  const rnd = Array.from(crypto.getRandomValues(new Uint8Array(3)), (x) => x.toString(16).padStart(2, "0")).join("");
  const data = `${iat}.${rnd}`;
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await getSign(env), new TextEncoder().encode(data)));
  return { key: `MVS.${data}.${b64u(rawToDer(raw))}`, kid: data, iat };
}

function card(url, key) {
  const cmd = `apt update -y; apt upgrade -y; wget -qO mvs-install.sh ${url} && bash mvs-install.sh`;
  return (
    "═════════════════════════════\n" +
    "              ♧INSTALADOR SCRIPT MvS♧\n" +
    "═════════════════════════════\n\n" +
    "════♤COMANDO DE INSTALACIÓN♤════\n" +
    `<code>${esc(cmd)}</code>\n` +
    "═════════════════════════════\n\n" +
    "═════《SISTEMAS COMPATIBLES》═════\n\n" +
    "S.O Ubuntu 18.04 a 26.04 X64(x86|ARM)\n\n" +
    "Debian 8 a 12 (x64)\n\n" +
    "══════════════════════════════\n" +
    "═════════ &lt;🔐 KEY DE ACCESO&gt; ═════\n" +
    `<code>${key}</code>\n` +
    "══════════════════════════════\n" +
    "     ⏳ Expira 6 horas \n" +
    "══════════════════════════════"
  );
}

async function keysReport(env) {
  const list = await env.KEYS.list({ prefix: "issued:" });
  const rows = [];
  for (const k of list.keys) { const kid = k.name.slice(7); rows.push({ kid, iat: Number(kid.split(".")[0]) }); }
  rows.sort((a, b) => b.iat - a.iat);
  if (!rows.length) return "No hay keys generadas en las últimas 24 horas.";
  const now = Date.now() / 1000, out = ["🔑 Keys recientes"];
  for (const r of rows.slice(0, 10)) {
    const v = await env.KEYS.get("used:" + r.kid), left = r.iat + TTL - now;
    if (v) { const u = JSON.parse(v); out.push(`✅ ${r.kid} USADA ${u.t.slice(11, 16)} UTC · ${u.ip} · ${u.os}`); }
    else if (left > 0) out.push(`🟡 ${r.kid} sin usar · vence en ${Math.floor(left / 3600)}h ${String(Math.floor((left % 3600) / 60)).padStart(2, "0")}min`);
    else out.push(`⌛ ${r.kid} venció sin usarse`);
  }
  return out.join("\n");
}

async function botSend(env, chat, text) {
  await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chat, text, parse_mode: "HTML", disable_web_page_preview: true }) });
}

async function webhook(req, env) {
  if (!env.BOT_TOKEN) return json({ error: "falta BOT_TOKEN" }, 500);
  if (env.WEBHOOK_SECRET && req.headers.get("x-telegram-bot-api-secret-token") !== env.WEBHOOK_SECRET) return json({ error: "no autorizado" }, 401);
  let u; try { u = await req.json(); } catch (e) { return json({ ok: true }); }
  const m = u.message || {};
  const owner = String(env.BOT_CHAT || env.TG_CHAT || "");
  if (!owner || String((m.from || {}).id || "") !== owner || String((m.chat || {}).id || "") !== owner) return json({ ok: true });   // otras personas: se ignora
  const text = String(m.text || "").trim();
  const cmd = text ? text.split(/\s+/)[0].split("@")[0].toLowerCase() : "";
  try {
    if (cmd === "/start" || cmd === "/ayuda" || cmd === "/help") await botSend(env, owner, "Escribí /key para generar una key de instalación de MvS (vale 6 horas).\n/keys muestra si las keys recientes fueron usadas.");
    else if (cmd === "/key" || cmd === "/clave") {
      const k = await makeKey(env);
      await env.KEYS.put("issued:" + k.kid, "1", { expirationTtl: 24 * 3600 });
      await botSend(env, owner, card(env.INSTALL_URL || DEFAULT_URL, k.key));
    } else if (cmd === "/keys" || cmd === "/estado") await botSend(env, owner, await keysReport(env));
    else await botSend(env, owner, "Comando no reconocido. Usá /key");
  } catch (e) { await botSend(env, owner, "⚠️ Error: " + esc(String(e.message || e))); }
  return json({ ok: true });
}

async function diag(req, env) {            // revisa la configuración del bot sin mostrar secretos
  if (!env.ADMIN_TOKEN || req.headers.get("authorization") !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "no autorizado" }, 401);
  const out = { BOT_TOKEN: !!env.BOT_TOKEN, SIGN_KEY: !!env.SIGN_KEY, dueño_id: String(env.BOT_CHAT || env.TG_CHAT || "") || "FALTA (TG_CHAT o BOT_CHAT)" };
  if (env.BOT_TOKEN) { try { const r = await (await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/getMe`)).json(); out.bot = r.ok ? "@" + r.result.username : "TOKEN RECHAZADO: " + r.description; } catch (e) { out.bot = "sin conexión"; } }
  if (env.SIGN_KEY) { try { await makeKey(env); out.firma = "ok"; } catch (e) { out.firma = "ERROR: " + String(e.message || e); } }
  if (env.BOT_TOKEN && out.dueño_id[0] !== "F") { try { const r = await (await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: out.dueño_id, text: "✅ Prueba del Worker: el bot puede escribirte." }) })).json(); out.envio = r.ok ? "ok (mirá Telegram)" : "ERROR: " + r.description; } catch (e) { out.envio = "sin conexión"; } }
  return json(out);
}

export default {
  async fetch(req, env, ctx) {
    const p = new URL(req.url).pathname;
    if (!env.KEYS) return json({ ok: false, reason: "config", error: "falta el enlace KV con el nombre KEYS (Settings > Bindings)" }, 500);
    if (req.method === "POST" && p === "/claim") return claim(req, env, ctx);
    if (req.method === "POST" && p === "/tg") return webhook(req, env);
    if (req.method === "POST" && p === "/diag") return diag(req, env);
    if (req.method === "POST" && p === "/status") return status(req, env);
    return new Response("MvS key gate", { status: 200 });
  },
};
