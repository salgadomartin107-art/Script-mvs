#!/usr/bin/env bash
# Genera un único archivo (instalador autocontenido) con todo el panel adentro.
# Uso: tools/build-single.sh [salida]   (por defecto ./mvs-install.sh)
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$PWD/mvs-install.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mvs"
(cd "$ROOT" && tar --exclude=./tools --exclude=./.git -cf - .) | tar -xf - -C "$TMP/mvs"
(cd "$TMP" && tar --owner=0 --group=0 --numeric-owner -czf payload.tgz mvs)
SUM="$(sha256sum "$TMP/payload.tgz" | awk '{print $1}')"
{
cat <<EOF
#!/usr/bin/env bash
# MvS - instalador único (todo el panel va dentro de este archivo; no descarga nada salvo paquetes de apt).
# Uso:  bash mvs-install.sh      Sistemas: Ubuntu 18.04-24.04 (x64/ARM64), Debian 8-12 (x64)
set -Eeuo pipefail
[[ \${EUID:-\$(id -u)} -eq 0 ]] || { echo "Ejecutá como root (sudo -i)."; exit 1; }
SELF="\$(readlink -f "\${BASH_SOURCE[0]}")"
TMP="\$(mktemp -d)"; trap 'rm -rf "\$TMP"' EXIT
sed '1,/^__MVS_PAYLOAD__\$/d' "\$SELF" | base64 -d > "\$TMP/payload.tgz" 2>/dev/null || { echo "El archivo está incompleto o dañado (¿faltó pegar alguna parte?)."; exit 1; }
echo "${SUM}  \$TMP/payload.tgz" | sha256sum -c - >/dev/null 2>&1 || { echo "Verificación SHA-256 fallida: archivo incompleto o alterado."; exit 1; }
tar -xzf "\$TMP/payload.tgz" -C "\$TMP"
bash "\$TMP/mvs/install.sh" "\$@"
exit 0
__MVS_PAYLOAD__
EOF
base64 -w 76 "$TMP/payload.tgz"
} > "$OUT"
chmod 755 "$OUT"
echo "Generado: $OUT ($(wc -c < "$OUT") bytes)"
