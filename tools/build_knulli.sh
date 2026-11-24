#!/bin/bash
# Gera o pacote do Knulli Port Hub: build/knulli/ports/ + build/Knulli-Port-Hub.zip
# Usa zip ou, no Windows (Git Bash), o 7-Zip.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/knulli"
rm -rf "$OUT"; mkdir -p "$OUT/ports"
cp -a "$ROOT/port/r36sporthub" "$OUT/ports/"
cp "$ROOT/port/R36S PORT HUB.sh" "$OUT/ports/Knulli Port Hub.sh"
# imagens do Knulli no lugar das do R36S (capa/marquee/fanart da lista de Ports)
cp "$ROOT/port/r36sporthub/knulli/"*.png "$OUT/ports/r36sporthub/"
rm -rf "$OUT/ports/r36sporthub/knulli"
SEVENZ="/c/Program Files/7-Zip/7z.exe"
mkzip() { # mkzip ARQUIVO DIR [excluir]
  if command -v zip >/dev/null 2>&1; then (cd "$2" && zip -q -9 -r "$1" . ${3:+-x "$3"})
  else (cd "$2" && "$SEVENZ" a -tzip -mx=9 "$1" . ${3:+-xr!"$3"} >/dev/null); fi
}
mkzip "$OUT/ports/r36sporthub/game.love" "$ROOT/src" "dev"
chmod +x "$OUT/ports/Knulli Port Hub.sh" "$OUT/ports/r36sporthub/bin/"*.sh "$OUT/ports/r36sporthub/tools/"*.sh 2>/dev/null || true
rm -f "$ROOT/build/Knulli-Port-Hub.zip"
mkzip "$ROOT/build/Knulli-Port-Hub.zip" "$OUT/ports"
echo "Pacote: $ROOT/build/Knulli-Port-Hub.zip"
