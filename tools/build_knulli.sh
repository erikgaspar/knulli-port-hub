#!/bin/bash
# Gera o pacote do Knulli Port Hub:
#   build/Knulli-Port-Hub.zip          (instalacao completa, com update_manifest.json)
#   build/Knulli-Port-Hub-update.zip   (o mesmo pacote, nome usado pela atualizacao via rede)
# Precisa de zip e python3 (roda no proprio console Knulli ou num Linux).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/knulli"
rm -rf "$OUT"; mkdir -p "$OUT/ports"
cp -a "$ROOT/port/r36sporthub" "$OUT/ports/"
cp "$ROOT/port/R36S PORT HUB.sh" "$OUT/ports/Knulli Port Hub.sh"
# imagens do Knulli no lugar das do R36S (capa/marquee/fanart da lista de Ports)
cp "$ROOT/port/r36sporthub/knulli/"*.png "$OUT/ports/r36sporthub/"
rm -rf "$OUT/ports/r36sporthub/knulli"
(cd "$ROOT/src" && zip -q -9 -n .ogg -r "$OUT/ports/r36sporthub/game.love" . -x 'dev/*')
chmod +x "$OUT/ports/Knulli Port Hub.sh" "$OUT/ports/r36sporthub/bin/"*.sh "$OUT/ports/r36sporthub/tools/"*.sh 2>/dev/null || true
PORTHUB_FIRMWARE=knulli python3 "$ROOT/tools/make_update.py" full "$OUT/ports"
rm -f "$ROOT/build/Knulli-Port-Hub.zip" "$ROOT/build/Knulli-Port-Hub-update.zip"
(cd "$OUT/ports" && zip -q -9 -r "$ROOT/build/Knulli-Port-Hub.zip" "Knulli Port Hub.sh" r36sporthub update_manifest.json)
cp "$ROOT/build/Knulli-Port-Hub.zip" "$ROOT/build/Knulli-Port-Hub-update.zip"
echo "Pacote: $ROOT/build/Knulli-Port-Hub.zip"
