#!/bin/bash
# =============================================================================
#  Knulli Port Hub - modo desempenho por port (RG35XXH / Allwinner H700)
#
#  Uso:  perf_run.sh <script.sh> <id>   roda o port (script na raiz da pasta
#                                       de ports) com o perfil de desempenho
#        perf_run.sh --restore          so desfaz um perfil que ficou preso
#                                       (sessao morta com SIGKILL)
#
#  Perfil (sem overclock): CPU em "performance" (todas as policies), GPU com
#  piso na maior frequencia (696 MHz no H700) e o EmulationStation pausado
#  (SIGSTOP) enquanto o jogo roda e, se estiver desligada, a memoria extra
#  (zram do Knulli; conf/perf_zram_off desliga isso). Mede temperatura maxima/media (zonas
#  termicas do SoC, sem a bateria) e a duracao, e grava o resumo em
#  <pasta do app>/conf/perf/<id>.json.
#
#  Tudo volta ao original na saida, mesmo se o jogo travar ou for morto:
#   - trap EXIT (saida normal, TERM/INT/HUP);
#   - um vigia em outra sessao (setsid) que restaura se este script morrer
#     sem conseguir limpar (SIGKILL);
#   - o estado fica em /tmp: a proxima execucao (ou --restore) desfaz o resto.
# =============================================================================

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
APP_DIR=$(dirname "$SELF_DIR")              # .../ports/r36sporthub
PORTS_ROOT=$(dirname "$APP_DIR")            # .../ports
OUT_DIR="$APP_DIR/conf/perf"
STATE=/tmp/porthub-perf.state                # o que restaurar
TEMPF=/tmp/porthub-perf.temp                 # "max soma amostras" (mili-graus)
GPU=/sys/class/devfreq/gpu
SAMPLE=2                                     # segundos entre leituras
ZRAM_SVC=/usr/share/knulli/services/zramswap   # memoria extra do Knulli
ZRAM_OFF="$APP_DIR/conf/perf_zram_off"        # existe = nao ligar o zram junto

log() { echo "[perf_run] $(date +%T) $*"; }

# zonas termicas do SoC (cpu/gpu/ve/ddr); a bateria fica de fora
zones() {
  for z in /sys/class/thermal/thermal_zone*; do
    case "$(cat "$z/type" 2>/dev/null)" in *battery*|*BAT*|*bat*) continue ;; esac
    [ -r "$z/temp" ] && echo "$z/temp"
  done
}

# maior temperatura agora (mili-graus) entre as zonas do SoC
temp_now() {
  local m=0 t f
  for f in $ZONES; do
    t=$(cat "$f" 2>/dev/null) || continue
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$t" -gt "$m" ] && m=$t
  done
  echo "$m"
}

restore() {
  [ -f "$STATE" ] || { kill -CONT $(pidof emulationstation) 2>/dev/null; return 0; }
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      gov_*) echo "$v" > "/sys/devices/system/cpu/cpufreq/${k#gov_}/scaling_governor" 2>/dev/null ;;
      gpumin) echo "$v" > "$GPU/min_freq" 2>/dev/null ;;
      es) [ -n "$v" ] && kill -CONT $v 2>/dev/null ;;
      zram) [ "$v" = 1 ] && [ -f "$ZRAM_SVC" ] && LC_ALL=C LANG=C bash "$ZRAM_SVC" stop >/dev/null 2>&1 ;;
    esac
  done < "$STATE"
  # o menu NUNCA pode ficar parado (tela congela): retoma qualquer ES
  kill -CONT $(pidof emulationstation) 2>/dev/null
  rm -f "$STATE"
  log "restaurado: cpu=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null) gpu_min=$(cat $GPU/min_freq 2>/dev/null)"
}

# vigia (em outra sessao): mede a temperatura e, se o perf_run morrer sem
# limpar, restaura sozinho
watch_loop() {
  local parent=$1 max=0 sum=0 n=0 t
  trap '' HUP INT
  while kill -0 "$parent" 2>/dev/null; do
    t=$(temp_now)
    if [ "$t" -gt 0 ]; then
      [ "$t" -gt "$max" ] && max=$t
      sum=$((sum + t)); n=$((n + 1))
      echo "$max $sum $n" > "$TEMPF.tmp" && mv -f "$TEMPF.tmp" "$TEMPF"
    fi
    sleep "$SAMPLE"
  done
  # o pai sumiu: se o estado ainda existe, ninguem restaurou
  if [ -f "$STATE" ]; then log "perf_run sumiu sem restaurar; restaurando pelo vigia"; restore; rm -f "$TEMPF" "$TEMPF.tmp"; fi
}

ZONES=$(zones)

case "${1:-}" in
  --restore) restore; exit 0 ;;
  --watch) watch_loop "$2"; exit 0 ;;
  ""|-h|--help) echo "uso: $0 <script.sh> <id> | --restore"; exit 2 ;;
esac

PORT_SH=$1
PORT_ID=$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9_-')
[ -n "$PORT_ID" ] || PORT_ID=$(printf '%s' "${PORT_SH%.*}" | tr -cd 'A-Za-z0-9_-')
shift 2 2>/dev/null || shift $#
case "$PORT_SH" in
  */*|*..*) log "script invalido: $PORT_SH"; exit 2 ;;
  *.sh|*.SH) ;;
  *) log "script invalido: $PORT_SH"; exit 2 ;;
esac
if [ ! -f "$PORTS_ROOT/$PORT_SH" ]; then log "script nao encontrado: $PORTS_ROOT/$PORT_SH"; exit 2; fi

# sessao anterior morta: desfaz antes de comecar (para gravar o original certo)
[ -f "$STATE" ] && { log "estado antigo encontrado"; restore; }

GAME_PID=""
WATCH_PID=""
T0=$(date +%s)
RC=""

finish() {
  local t1 mins max sum n tmax tavg
  trap - EXIT TERM INT HUP
  [ -n "$GAME_PID" ] && kill -0 "$GAME_PID" 2>/dev/null && kill -TERM "$GAME_PID" 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  restore
  t1=$(date +%s)
  read -r max sum n < "$TEMPF" 2>/dev/null
  rm -f "$TEMPF" "$TEMPF.tmp"
  max=${max:-0}; sum=${sum:-0}; n=${n:-0}
  mins=$(awk -v s=$((t1 - T0)) 'BEGIN{printf "%.1f", s/60}')
  tmax=$(awk -v m="$max" 'BEGIN{printf "%.1f", m/1000}')
  tavg=$(awk -v s="$sum" -v n="$n" 'BEGIN{ if (n>0) printf "%.1f", s/n/1000; else printf "0" }')
  mkdir -p "$OUT_DIR" 2>/dev/null
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$PORT_ID"
    printf '  "script": "%s",\n' "$(printf '%s' "$PORT_SH" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '  "start": %s,\n  "end": %s,\n' "$T0" "$t1"
    printf '  "start_iso": "%s",\n' "$(date -d "@$T0" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf '  "end_iso": "%s",\n' "$(date -d "@$t1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf '  "seconds": %s,\n  "minutes": %s,\n' "$((t1 - T0))" "$mins"
    printf '  "temp_max_c": %s,\n  "temp_avg_c": %s,\n  "samples": %s,\n' "$tmax" "$tavg" "$n"
    printf '  "exit_code": %s\n}\n' "${RC:-null}"
  } > "$OUT_DIR/$PORT_ID.json.tmp" && mv -f "$OUT_DIR/$PORT_ID.json.tmp" "$OUT_DIR/$PORT_ID.json"
  sync
  log "fim: ${mins} min, temp max ${tmax} C, media ${tavg} C, codigo ${RC:-?}"
}
trap finish EXIT
# TERM/INT/HUP: repassa para o jogo e sai (o EXIT restaura)
trap 'RC=${RC:-143}; exit 143' TERM INT HUP

# --- aplica o perfil -----------------------------------------------------
: > "$STATE"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -w "$p/scaling_governor" ] || continue
  echo "gov_$(basename "$p")=$(cat "$p/scaling_governor")" >> "$STATE"
  echo performance > "$p/scaling_governor" 2>/dev/null
done
if [ -w "$GPU/min_freq" ]; then
  echo "gpumin=$(cat "$GPU/min_freq")" >> "$STATE"
  top=$(tr ' ' '\n' < "$GPU/available_frequencies" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n 1)
  [ -n "$top" ] && echo "$top" > "$GPU/min_freq" 2>/dev/null
fi
# memoria extra (zram): liga so durante a sessao se estiver desligada (o Knulli
# le "free" em ingles: LC_ALL=C; o resultado e conferido em /proc/swaps)
if [ ! -f "$ZRAM_OFF" ] && [ -f "$ZRAM_SVC" ] && ! grep -q zram /proc/swaps 2>/dev/null; then
  LC_ALL=C LANG=C bash "$ZRAM_SVC" start >/dev/null 2>&1
  if grep -q zram /proc/swaps 2>/dev/null; then echo "zram=1" >> "$STATE"; log "zram ligado para esta sessao"; else log "zram: nao consegui ligar"; fi
fi
ES_PIDS=$(pidof emulationstation)
echo "es=$ES_PIDS" >> "$STATE"
sync

rm -f "$TEMPF" "$TEMPF.tmp"
setsid bash "$0" --watch $$ < /dev/null > /dev/null 2>&1 &
WATCH_PID=$!

[ -n "$ES_PIDS" ] && kill -STOP $ES_PIDS 2>/dev/null
log "perfil ligado: cpu=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null) gpu_min=$(cat $GPU/min_freq 2>/dev/null) es_pausado=${ES_PIDS:-nenhum} temp=$(temp_now)"

# --- roda o port ----------------------------------------------------------
# em segundo plano + wait: o trap dispara na hora se este script receber TERM
# (0<&0 mantem a entrada padrao, que o bash trocaria por /dev/null)
cd "$PORTS_ROOT" || exit 1
log "iniciando: $PORT_SH"
bash "./$PORT_SH" "$@" 0<&0 &
GAME_PID=$!
wait "$GAME_PID"
RC=$?
# wait interrompido por sinal tratado: espera o jogo de verdade
while kill -0 "$GAME_PID" 2>/dev/null; do wait "$GAME_PID"; RC=$?; done
GAME_PID=""
exit "$RC"
