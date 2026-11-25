#!/bin/sh
# R36S PORT HUB - auxiliar de download (curl com fallback para wget)
#
# Uso:
#   fetch.sh get  URL SAIDA ARQ_PID ARQ_RC [MAX_SEGUNDOS]
#       Baixa URL para SAIDA. Grava o PID do processo de download em ARQ_PID
#       (para permitir cancelar) e o codigo de saida final em ARQ_RC.
#       Tenta retomar (-C -) em quedas de conexao, ate 3 tentativas
#       (com PH_STATUS: ate 5 seguidas com espera crescente, veja abaixo).
#   fetch.sh head URL
#       Imprime o tamanho (Content-Length) final do arquivo, se o servidor informar.
#   fetch.sh part URL SAIDA BYTES
#       Baixa so o comeco do arquivo (os primeiros BYTES), para ler o manifesto
#       de um pacote .zip sem baixar tudo. Codigo de saida 0 se gravou algo.
#
# Codigos em ARQ_RC: 0 = ok; 143/137 = cancelado; outros = erro do curl/wget.

MODE="$1"
URL="$2"
UA="Mozilla/5.0 (R36S-PORT-HUB/BETA)"

have() { command -v "$1" >/dev/null 2>&1; }

# Erros de TLS/certificado: consoles com relogio/certificados antigos falham aqui.
is_tls_error() {
  case "$1" in 35|51|53|54|58|59|60|77|83|90|91) return 0 ;; esac
  return 1
}

if [ "$MODE" = "head" ]; then
  if have curl; then
    OUT=$(curl -sIL --max-time 20 -A "$UA" "$URL" 2>/dev/null)
    RC=$?
    if is_tls_error "$RC"; then OUT=$(curl -sIL -k --max-time 20 -A "$UA" "$URL" 2>/dev/null); fi
    echo "$OUT" | tr -d '\r' | grep -i '^content-length:' | tail -n 1 | awk '{print $2}'
  elif have wget; then
    wget --spider -S --no-check-certificate -T 20 -U "$UA" "$URL" 2>&1 | tr -d '\r' \
      | grep -i 'content-length:' | tail -n 1 | awk '{print $2}'
  fi
  exit 0
fi

if [ "$MODE" = "probe" ]; then
  # Checagem leve de um link (itens com download quebrado, core/broken.lua):
  # pede so os primeiros 1024 bytes (Range) e imprime chave=valor da resposta
  # final (depois dos redirecionamentos). Servidor que ignora o Range e manda
  # o arquivo inteiro: --max-filesize corta antes de baixar (rc 63) e os
  # cabecalhos continuam valendo. Uso: fetch.sh probe URL PASTA_TEMP
  TMPD="${3:-/tmp}"
  mkdir -p "$TMPD" 2>/dev/null
  HDR="$TMPD/probe.$$.h"; BODY="$TMPD/probe.$$.b"
  rm -f "$HDR" "$BODY"
  if ! have curl; then echo "RC=127"; exit 0; fi
  curl -sL --connect-timeout 15 --max-time 25 --max-filesize 1048576 -r 0-1023 -A "$UA" \
    -D "$HDR" -o "$BODY" "$URL" 2>/dev/null
  RC=$?
  if is_tls_error "$RC"; then
    rm -f "$HDR" "$BODY"
    curl -sL -k --connect-timeout 15 --max-time 25 --max-filesize 1048576 -r 0-1023 -A "$UA" \
      -D "$HDR" -o "$BODY" "$URL" 2>/dev/null
    RC=$?
  fi
  echo "RC=$RC"
  if [ -s "$HDR" ]; then
    # so o ultimo bloco de cabecalhos (resposta final)
    tr -d '\r' < "$HDR" | awk '
      /^HTTP\// { st=$2; ct=""; cl=""; cr=""; et=""; lm=""; next }
      { k=tolower($0); sub(/:.*/, "", k); v=$0; sub(/^[^:]*:[ \t]*/, "", v)
        if (k=="content-type") ct=v; else if (k=="content-length") cl=v
        else if (k=="content-range") cr=v; else if (k=="etag") et=v; else if (k=="last-modified") lm=v }
      END { print "STATUS=" st; print "CTYPE=" ct; print "LEN=" cl; print "RANGE=" cr; print "ETAG=" et; print "LASTMOD=" lm }'
  fi
  if [ -s "$BODY" ]; then
    echo "SIG=$(head -c 8 "$BODY" | od -An -tx1 | tr -d ' \n')"
    if head -c 512 "$BODY" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n' | grep -qE '^(<!doctype|<html)'; then echo "HTML=1"; fi
  fi
  rm -f "$HDR" "$BODY"
  exit 0
fi

if [ "$MODE" = "part" ]; then
  OUTFILE="$3"
  BYTES="${4:-262144}"
  LAST=$((BYTES - 1))
  rm -f "$OUTFILE"
  if have curl; then
    curl -L -s --connect-timeout 20 --max-time 40 -r "0-$LAST" -A "$UA" "$URL" 2>/dev/null | head -c "$BYTES" > "$OUTFILE"
    if [ ! -s "$OUTFILE" ]; then
      curl -L -s -k --connect-timeout 20 --max-time 40 -r "0-$LAST" -A "$UA" "$URL" 2>/dev/null | head -c "$BYTES" > "$OUTFILE"
    fi
  elif have wget; then
    wget -q -O - --no-check-certificate -T 30 -U "$UA" "$URL" 2>/dev/null | head -c "$BYTES" > "$OUTFILE"
  fi
  [ -s "$OUTFILE" ] && exit 0
  exit 1
fi

if [ "$MODE" != "get" ]; then
  echo "modo invalido" >&2
  exit 2
fi

OUTFILE="$3"
PIDFILE="$4"
RCFILE="$5"
MAXT="${6:-0}"

rm -f "$RCFILE"
mkdir -p "$(dirname "$OUTFILE")" 2>/dev/null

trap 'echo 143 > "$RCFILE"; exit 143' TERM INT

# Retomada (instalador de ports): com PH_STATUS definido, quedas de rede viram
# ate 5 novas tentativas seguidas (espera 5, 15, 30, 60 e 90 s) que CONTINUAM
# do ponto (curl -C -, Range). Tentativa que avancou mais de 1 MB zera a
# contagem. Em PH_STATUS vai uma linha para a interface:
#   retry N MAX RC ESPERA BYTES   (esperando para tentar de novo)
#   resume N BYTES                (tentativa N continuando do byte BYTES)
#   restart                       (servidor nao aceitou continuar: do zero)
# PH_IFRANGE = ETag forte ou Last-Modified do arquivo: se mudou no servidor,
# ele manda o arquivo inteiro (200), o curl para (33) e recomeca do zero.
STATUSF="${PH_STATUS:-}"
IFRANGE="${PH_IFRANGE:-}"
st() { [ -n "$STATUSF" ] && echo "$*" > "$STATUSF"; }
bytes_of() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

run_dl() {
  # $1 = extra flags (ex.: -k). Roda em segundo plano e espera, para que o PID
  # gravado seja o do curl/wget (assim o cancelamento interrompe de verdade).
  EXTRA="$1"
  if have curl; then
    set -- -L -f -s -S --connect-timeout 20 --speed-limit 1 --speed-time 60
    if [ "$MAXT" -gt 0 ] 2>/dev/null; then set -- "$@" --max-time "$MAXT"; fi
    if [ -s "$OUTFILE" ]; then
      set -- "$@" -C -
      if [ -n "$IFRANGE" ]; then set -- "$@" -H "If-Range: $IFRANGE"; fi
    fi
    # shellcheck disable=SC2086
    [ -n "$EXTRA" ] && set -- "$@" $EXTRA
    curl "$@" -A "$UA" -o "$OUTFILE" "$URL" &
  elif have wget; then
    W=""
    [ -n "$EXTRA" ] && W="--no-check-certificate"
    # shellcheck disable=SC2086
    wget -q -c -T 30 $W -U "$UA" -O "$OUTFILE" "$URL" &
  else
    echo 127 > "$RCFILE"
    exit 127
  fi
  CPID=$!
  echo "$CPID" > "$PIDFILE"
  wait "$CPID"
  return $?
}

# espera cancelavel: o PID gravado passa a ser o do sleep
pause_for() {
  sleep "$1" &
  SPID=$!
  echo "$SPID" > "$PIDFILE"
  wait "$SPID"
  if [ $? -ne 0 ]; then echo 143 > "$RCFILE"; exit 143; fi
}

ATTEMPT=0
FLAGS=""
RC=1
if [ -n "$STATUSF" ]; then
  FAILS=0; RESTARTS=0
  while [ $ATTEMPT -lt 60 ]; do
    ATTEMPT=$((ATTEMPT + 1))
    BEFORE=$(bytes_of "$OUTFILE")
    run_dl "$FLAGS"
    RC=$?
    [ $RC -eq 0 ] && break
    if [ $RC -eq 143 ] || [ $RC -eq 137 ] || [ $RC -eq 130 ]; then break; fi
    if is_tls_error "$RC" && [ -z "$FLAGS" ]; then
      echo "[fetch] erro TLS ($RC); tentando novamente sem verificar certificado" >&2
      FLAGS="-k"
      continue
    fi
    if [ $RC -eq 33 ]; then
      # servidor nao aceitou o Range (ou o arquivo mudou): recomeca do zero
      RESTARTS=$((RESTARTS + 1))
      [ $RESTARTS -gt 2 ] && break
      echo "[fetch] servidor nao aceitou continuar; recomecando do zero" >&2
      rm -f "$OUTFILE"; IFRANGE=""
      st "restart"
      continue
    fi
    case "$RC" in
      4|6|7|16|18|28|35|52|55|56|92)
        AFTER=$(bytes_of "$OUTFILE")
        if [ "$AFTER" -gt $((BEFORE + 1048576)) ] 2>/dev/null; then FAILS=0; fi
        FAILS=$((FAILS + 1))
        [ $FAILS -gt 5 ] && break
        # PH_RETRY_WAITS: esperas trocadas (so para testes), ex. "1 1 1 1 1"
        WT=$(echo "${PH_RETRY_WAITS:-5 15 30 60 90}" | awk -v n="$FAILS" '{ print (n <= NF) ? $n : $NF }')
        echo "[fetch] conexao caiu (rc=$RC, $AFTER bytes); tentativa $FAILS/5 em ${WT}s" >&2
        st "retry $FAILS 5 $RC $WT $AFTER"
        pause_for "$WT"
        st "resume $FAILS $(bytes_of "$OUTFILE")"
        continue
        ;;
    esac
    break
  done
else
  while [ $ATTEMPT -lt 4 ]; do
    ATTEMPT=$((ATTEMPT + 1))
    run_dl "$FLAGS"
    RC=$?
    [ $RC -eq 0 ] && break
    # cancelado (SIGTERM/SIGKILL)
    if [ $RC -eq 143 ] || [ $RC -eq 137 ] || [ $RC -eq 130 ]; then break; fi
    if is_tls_error "$RC" && [ -z "$FLAGS" ]; then
      echo "[fetch] erro TLS ($RC); tentando novamente sem verificar certificado" >&2
      FLAGS="-k"
      continue
    fi
    # 33 = servidor nao aceita retomar: recomeca do zero
    if [ $RC -eq 33 ]; then rm -f "$OUTFILE"; continue; fi
    # quedas de conexao/tempo esgotado: tenta retomar
    case "$RC" in 7|18|28|52|55|56|92|4) sleep 2; continue ;; esac
    break
  done
fi

echo "$RC" > "$RCFILE"
exit "$RC"
