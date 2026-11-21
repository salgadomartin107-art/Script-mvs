// MvS - compuerta de keys de instalación (Cloudflare Worker, plan gratis).
// Hace que cada key se pueda usar UNA sola vez: el instalador consulta acá antes de instalar.
// Necesita:  un KV namespace enlazado con el nombre KEYS   y estos secretos/variables (opcionales los de Telegram):
//   ADMIN_TOKEN  clave para que tu bot consulte el estado de las keys
//   TG_TOKEN     token del bot que te avisa      TG_CHAT   tu id de Telegram
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

export default {
  async fetch(req, env, ctx) {
    const p = new URL(req.url).pathname;
    if (!env.KEYS) return json({ ok: false, reason: "config", error: "falta el enlace KV con el nombre KEYS (Settings > Bindings)" }, 500);
    if (req.method === "POST" && p === "/claim") return claim(req, env, ctx);
    if (req.method === "POST" && p === "/status") return status(req, env);
    return new Response("MvS key gate", { status: 200 });
  },
};
