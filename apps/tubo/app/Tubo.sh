#!/bin/bash
# Tubo - cliente leve de YouTube (pygame + yt-dlp + mpv). Saida: A na tela inicial ou Menu+Start.
# pasta do proprio script (instalado em /userdata/system/knulli-tools/tubo)
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$DIR" || exit 1
mkdir -p "$DIR/data" "$DIR/cache/thumbs"

# Lancado pelo Tools o Knulli ja passa SDL_GAMECONTROLLERCONFIG; fora dele usa o banco do sistema.
if [ -z "$SDL_GAMECONTROLLERCONFIG" ] && [ -f /tmp/gamecontrollerdb.txt ]; then
    SDL_GAMECONTROLLERCONFIG="$(grep -v '^#' /tmp/gamecontrollerdb.txt)"
    export SDL_GAMECONTROLLERCONFIG
fi
export SDL_GAMECONTROLLER_ALLOW_BACKGROUND_EVENTS=1
export PYGAME_HIDE_SUPPORT_PROMPT=1
export HOME="${HOME:-/userdata/system}"

python3 "$DIR/tubo.py" "$@" 2>"$DIR/data/stderr.log"
rc=$?
# garante a tela ligada e nenhum mpv sobrando
knulli-brightness dispon >/dev/null 2>&1
rm -f /var/run/battery-saver/tubo.pause
for p in $(pidof mpv); do
    grep -q tubo-mpv.sock "/proc/$p/cmdline" 2>/dev/null && kill "$p"
done
exit $rc
