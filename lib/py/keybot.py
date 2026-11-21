#!/usr/bin/env python3
"""Bot de Telegram que genera keys de instalación de MvS (válidas 6 horas). Solo responde a TU id de Telegram.
Corre en cualquier equipo con python3 y openssl (Termux en el celular, otra VPS, una PC). Solo biblioteca estándar.
Configuración: archivo ~/.mvs-keybot.conf (o la ruta de MVS_KEYBOT_CONF) con líneas CLAVE=valor:
    TOKEN=token del bot (@BotFather)      CHAT=tu id numérico (@userinfobot)
    PRIV=ruta de private.pem              URL=dirección del instalador (opcional)"""
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
    c.setdefault("URL", DEFAULT_URL)
    if not os.path.isfile(c["PRIV"]):
        sys.exit("No encuentro la clave privada: " + c["PRIV"])
    return c


def make_key(priv):
    """Mismo formato que el instalador: MVS.<hora>.<azar>.<firma ECDSA SHA-256 en base64url>"""
    iat = int(time.time())
    rnd = secrets.token_hex(3)
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", priv], input=("%d.%s" % (iat, rnd)).encode(),
                         capture_output=True, check=True).stdout
    return "MVS.%d.%s.%s" % (iat, rnd, base64.urlsafe_b64encode(sig).rstrip(b"=").decode()), iat


def call(token, method, **params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request("%s/bot%s/%s" % (API, token, method), data=data)
    with urllib.request.urlopen(req, timeout=70) as r:
        return json.load(r)


def send(c, chat, text):
    call(c["TOKEN"], "sendMessage", chat_id=chat, text=text, parse_mode="HTML")


def handle(c, text, state):
    cmd = text.strip().split()[0].split("@")[0].lower() if text.strip() else ""
    if cmd in ("/start", "/ayuda", "/help"):
        return ["Escribí /key para generar una key de instalación de MvS (vale 6 horas)."]
    if cmd in ("/key", "/clave"):
        if time.time() - state.get("last", 0) < 3:
            return []
        state["last"] = time.time()
        key, iat = make_key(c["PRIV"])
        hasta = time.strftime("%H:%M", time.localtime(iat + TTL))
        return ["Key (vale 6 horas, hasta las %s hora de este equipo):\n<code>%s</code>" % (hasta, key),
                "Comando para la VPS nueva (como root):\n<code>wget -qO mvs.sh %s &amp;&amp; MVS_KEY=%s bash mvs.sh</code>" % (c["URL"], key)]
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
