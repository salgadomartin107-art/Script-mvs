#!/usr/bin/env python3
"""Bot de Telegram que genera keys de instalación de MvS (válidas 6 horas). Solo responde a TU id de Telegram.
Corre en cualquier equipo con python3 y openssl (Termux en el celular, otra VPS, una PC). Solo biblioteca estándar.
Configuración: archivo ~/.mvs-keybot.conf (o la ruta de MVS_KEYBOT_CONF) con líneas CLAVE=valor:
    TOKEN=token del bot (@BotFather)      CHAT=tu id numérico (@userinfobot)
    PRIV=ruta de private.pem              URL=dirección del instalador (opcional)
    GATE_URL=dirección del Worker  GATE_ADMIN=su ADMIN_TOKEN  (key de un solo uso y /keys)
    REPORT_TOKEN=token de un SEGUNDO bot que solo avisa cuando se usa una key (opcional; REPORT_CHAT=chat, por defecto CHAT)"""
import base64, json, os, secrets, subprocess, sys, time, urllib.parse, urllib.request

API = os.environ.get("MVS_TG_API", "https://api.telegram.org")
CONF = os.path.expanduser(os.environ.get("MVS_KEYBOT_CONF", "~/.mvs-keybot.conf"))
DEFAULT_URL = "https://raw.githubusercontent.com/salgadomartin107-art/Script-mvs/main/mvs-install.sh"
TTL = 6 * 3600


def load_conf():
    c = {}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                c[k.strip()] = os.path.expanduser(v.strip().strip('"').strip("'"))
    for k in ("TOKEN", "CHAT"):
        if not c.get(k):
            sys.exit("Falta %s en %s" % (k, CONF))
    c.setdefault("PRIV", os.path.expanduser("~/private.pem"))
    c.setdefault("REPORT_CHAT", c["CHAT"])
    c["KEYS"] = os.path.expanduser("~/.mvs-keybot-keys.json")   # keys emitidas (para /keys); GATE_URL y GATE_ADMIN = el Worker          # opcional: REPORT_TOKEN = token de un bot aparte que solo avisa
    c.setdefault("URL", DEFAULT_URL)
    if not os.path.isfile(c["PRIV"]):
        sys.exit("No encuentro la clave privada: " + c["PRIV"])
    return c


def make_key(priv, report=None):
    """Mismo formato que el instalador: MVS.<hora>.<azar>[.<destino del aviso>].<firma ECDSA SHA-256 en base64url>
    report = (token_del_bot_avisador, chat_id): va dentro de la key (firmado) y el instalador avisa a ese chat al usarla."""
    iat = int(time.time())
    rnd = secrets.token_hex(3)
    rep = ""
    if report:
        rep = base64.urlsafe_b64encode(("%s|%s" % report).encode()).rstrip(b"=").decode()
    data = "%d.%s%s" % (iat, rnd, "." + rep if rep else "")
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", priv], input=data.encode(),
                         capture_output=True, check=True).stdout
    sig = base64.urlsafe_b64encode(sig).rstrip(b"=").decode()
    return "MVS.%d.%s.%s%s" % (iat, rnd, rep + "." if rep else "", sig), iat


def call(token, method, **params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request("%s/bot%s/%s" % (API, token, method), data=data)
    with urllib.request.urlopen(req, timeout=70) as r:
        return json.load(r)


def send(c, chat, text):
    call(c["TOKEN"], "sendMessage", chat_id=chat, text=text, parse_mode="HTML")


def card(url, key, hasta=""):
    """Mensaje del bot (HTML de Telegram). El comando y la key van en <code> para copiarlos con un toque."""
    cmd = "apt update -y; apt upgrade -y; wget -qO mvs-install.sh %s && bash mvs-install.sh" % url
    esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return (
        "═════════════════════════════\n"
        "              ♧INSTALADOR SCRIPT MvS♧\n"
        "═════════════════════════════\n"
        "\n"
        "════♤COMANDO DE INSTALACIÓN♤════\n"
        "<code>%s</code>\n"
        "═════════════════════════════\n"
        "\n"
        "═════《SISTEMAS COMPATIBLES》═════\n"
        "\n"
        "S.O Ubuntu 18.04 a 26.04 X64(x86|ARM)\n"
        "\n"
        "Debian 8 a 12 (x64)\n"
        "\n"
        "══════════════════════════════\n"
        "═════════ &lt;🔐 KEY DE ACCESO&gt; ═════\n"
        "<code>%s</code>\n"
        "══════════════════════════════\n"
        "     ⏳ Expira 6 horas \n"
        "══════════════════════════════" % (esc(cmd), key))


def remember(c, kid, iat):
    try:
        with open(c["KEYS"]) as f:
            lst = json.load(f)
    except Exception:
        lst = []
    lst = [k for k in lst if time.time() - k["iat"] < 24 * 3600] + [{"kid": kid, "iat": iat}]
    with open(c["KEYS"], "w") as f:
        json.dump(lst[-30:], f)


def keys_report(c):
    """Lista las keys recientes con su estado (necesita el Worker: GATE_URL y GATE_ADMIN en la configuración)."""
    if not (c.get("GATE_URL") and c.get("GATE_ADMIN")):
        return "Para ver si las keys se usaron hace falta la compuerta (Worker). Mirá el README: «Key de un solo uso»."
    try:
        with open(c["KEYS"]) as f:
            lst = json.load(f)
    except Exception:
        lst = []
    lst = [k for k in lst if time.time() - k["iat"] < 24 * 3600][-10:]
    if not lst:
        return "No hay keys generadas en las últimas 24 horas."
    req = urllib.request.Request(c["GATE_URL"].rstrip("/") + "/status", data=json.dumps({"kids": [k["kid"] for k in lst]}).encode(),
                                 headers={"content-type": "application/json", "authorization": "Bearer " + c["GATE_ADMIN"]})
    with urllib.request.urlopen(req, timeout=20) as r:
        st = json.load(r)
    out = ["🔑 Keys recientes"]
    for k in reversed(lst):
        u, left = st.get(k["kid"]), k["iat"] + TTL - time.time()
        if u:
            out.append("✅ %s USADA %s UTC · %s · %s" % (k["kid"], u["t"][11:16], u["ip"], u["os"]))
        elif left > 0:
            out.append("🟡 %s sin usar · vence en %dh %02dmin" % (k["kid"], left // 3600, left % 3600 // 60))
        else:
            out.append("⌛ %s venció sin usarse" % k["kid"])
    return "\n".join(out)


def handle(c, text, state):
    cmd = text.strip().split()[0].split("@")[0].lower() if text.strip() else ""
    if cmd in ("/start", "/ayuda", "/help"):
        return ["Escribí /key para generar una key de instalación de MvS (vale 6 horas).\n/keys muestra si las keys recientes fueron usadas."]
    if cmd in ("/key", "/clave"):
        if time.time() - state.get("last", 0) < 3:
            return []
        state["last"] = time.time()
        key, iat = make_key(c["PRIV"], (c["REPORT_TOKEN"], c["REPORT_CHAT"]) if c.get("REPORT_TOKEN") else None)
        remember(c, "%d.%s" % (iat, key.split(".")[2]), iat)
        return [card(c["URL"], key, time.strftime("%H:%M", time.localtime(iat + TTL)))]
    if cmd in ("/keys", "/estado"):
        return [keys_report(c)]
    return ["Comando no reconocido. Usá /key"]


def main():
    c = load_conf()
    state, offset = {}, 0
    print("Bot de keys activo. Solo responde al chat", c["CHAT"], flush=True)
    while True:
        try:
            r = call(c["TOKEN"], "getUpdates", offset=offset, timeout=50, allowed_updates='["message"]')
        except Exception as e:
            print("Sin conexión con Telegram (%s); reintento en 5 s" % e, flush=True)
            time.sleep(5)
            continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            m = u.get("message") or {}
            if str((m.get("from") or {}).get("id", "")) != c["CHAT"] or str((m.get("chat") or {}).get("id", "")) != c["CHAT"]:
                continue                     # cualquier otra persona: se ignora sin responder
            try:
                for t in handle(c, m.get("text", ""), state):
                    send(c, c["CHAT"], t)
            except Exception as e:
                print("Error:", e, flush=True)


if __name__ == "__main__":
    main()
