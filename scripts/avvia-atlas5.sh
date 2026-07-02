#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

assumi_si=false
nome_container="qwen3-next-server"

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/avvia-atlas5.sh [opzioni]

Avvia llama-server sul nodo atlas5 collegandolo al server RPC di argo3.

Opzioni:
  --yes       Salta la conferma interattiva.
  -h, --help  Mostra questo messaggio.

Note:
  - Lo script usa solo il file locale .env.
  - Lo script non installa pacchetti e non modifica il sistema.
  - Lo script non cancella immagini, modelli, cache, volumi o container.
EOF
}

errore() {
  printf 'Errore: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

trim() {
  local valore="$1"

  valore="${valore#"${valore%%[![:space:]]*}"}"
  valore="${valore%"${valore##*[![:space:]]}"}"
  printf '%s' "$valore"
}

spoglia_virgolette() {
  local valore="$1"

  if [[ "$valore" == \"*\" && "$valore" == *\" && "${#valore}" -ge 2 ]]; then
    valore="${valore:1:${#valore}-2}"
  elif [[ "$valore" == \'*\' && "$valore" == *\' && "${#valore}" -ge 2 ]]; then
    valore="${valore:1:${#valore}-2}"
  fi

  printf '%s' "$valore"
}

leggi_variabile_config() {
  local file_config="$1"
  local nome="$2"
  local riga=""
  local chiave=""
  local valore=""

  while IFS= read -r riga || [[ -n "$riga" ]]; do
    riga="${riga%$'\r'}"
    riga="$(trim "$riga")"

    [[ -z "$riga" ]] && continue
    [[ "$riga" == \#* ]] && continue
    [[ "$riga" != *=* ]] && continue

    chiave="$(trim "${riga%%=*}")"
    [[ "$chiave" == "$nome" ]] || continue

    valore="$(trim "${riga#*=}")"
    valore="$(spoglia_virgolette "$valore")"
    printf '%s' "$valore"
    return 0
  done <"$file_config"

  return 1
}

richiedi_variabile_config() {
  local nome="$1"
  local valore=""

  if valore="$(leggi_variabile_config "$file_config" "$nome")"; then
    if [[ -n "$valore" || "$nome" == "TENSOR_SPLIT" || "$nome" == "LLAMA_SERVER_EXTRA_ARGS" ]]; then
      printf '%s' "$valore"
      return 0
    fi
  fi

  errore "variabile $nome mancante o vuota in $file_config."
  exit 1
}

formatta_byte() {
  local byte="$1"

  awk -v byte="$byte" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", unita, " ")
      valore = byte + 0
      indice = 1
      while (valore >= 1024 && indice < 6) {
        valore = valore / 1024
        indice++
      }
      if (indice == 1) {
        printf "%.0f %s", valore, unita[indice]
      } else {
        printf "%.2f %s", valore, unita[indice]
      }
    }
  '
}

valida_ipv4() {
  local ip="$1"
  local ottetto=""
  local numero=0
  local parti=()

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS=. read -r -a parti <<<"$ip"
  [[ "${#parti[@]}" -eq 4 ]] || return 1

  for ottetto in "${parti[@]}"; do
    [[ "$ottetto" =~ ^[0-9]+$ ]] || return 1
    numero=$((10#$ottetto))
    (( numero >= 0 && numero <= 255 )) || return 1
  done
}

valida_ipv4_locale() {
  local ip="$1"
  local parti=()

  valida_ipv4 "$ip" || return 1
  IFS=. read -r -a parti <<<"$ip"

  [[ "$ip" == "127.0.0.1" ]] && return 0
  [[ "${parti[0]}" == "127" ]] && return 0
  [[ "${parti[0]}" == "10" ]] && return 0
  [[ "${parti[0]}" == "192" && "${parti[1]}" == "168" ]] && return 0
  if [[ "${parti[0]}" == "172" ]] && (( 10#${parti[1]} >= 16 && 10#${parti[1]} <= 31 )); then
    return 0
  fi

  return 1
}

valida_intero_positivo() {
  local nome="$1"
  local valore="$2"

  if [[ ! "$valore" =~ ^[0-9]+$ ]] || (( 10#$valore <= 0 )); then
    errore "$nome deve essere un intero maggiore di zero, rilevato: $valore"
    exit 1
  fi
}

valida_porta() {
  local nome="$1"
  local valore="$2"

  if [[ ! "$valore" =~ ^[0-9]+$ ]] || (( 10#$valore < 1 || 10#$valore > 65535 )); then
    errore "$nome deve essere un intero tra 1 e 65535, rilevato: $valore"
    exit 1
  fi
}

verifica_file_richiesti() {
  local file=""
  local file_richiesti=(
    AGENTS.md
    .env
    scripts/verifica-cpu.sh
    scripts/verifica-rpc-atlas5.sh
  )

  for file in "${file_richiesti[@]}"; do
    if [[ ! -e "$repo_root/$file" ]]; then
      errore "file richiesto mancante: $repo_root/$file"
      exit 1
    fi
  done
}

carica_configurazione() {
  file_config="$repo_root/.env"

  LLAMA_SERVER_IMAGE="$(richiedi_variabile_config LLAMA_SERVER_IMAGE)"
  MAIN_CPU_PROFILE="$(richiedi_variabile_config MAIN_CPU_PROFILE)"
  RPC_HOST="$(richiedi_variabile_config RPC_HOST)"
  RPC_PORT="$(richiedi_variabile_config RPC_PORT)"
  SERVER_BIND_HOST="$(richiedi_variabile_config SERVER_BIND_HOST)"
  SERVER_PUBLISH_HOST="$(richiedi_variabile_config SERVER_PUBLISH_HOST)"
  SERVER_PORT="$(richiedi_variabile_config SERVER_PORT)"
  MAIN_THREADS="$(richiedi_variabile_config MAIN_THREADS)"
  MODEL_HOST_DIR="$(richiedi_variabile_config MODEL_HOST_DIR)"
  MODEL_CONTAINER_DIR="$(richiedi_variabile_config MODEL_CONTAINER_DIR)"
  MODEL_FILENAME="$(richiedi_variabile_config MODEL_FILENAME)"
  CONTEXT_SIZE="$(richiedi_variabile_config CONTEXT_SIZE)"
  DEFAULT_MAX_TOKENS="$(richiedi_variabile_config DEFAULT_MAX_TOKENS)"
  N_GPU_LAYERS="$(richiedi_variabile_config N_GPU_LAYERS)"
  TENSOR_SPLIT="$(richiedi_variabile_config TENSOR_SPLIT)"
  SPLIT_MODE="$(richiedi_variabile_config SPLIT_MODE)"
  FIT_MODE="$(richiedi_variabile_config FIT_MODE)"
  FIT_TARGET_MIB="$(richiedi_variabile_config FIT_TARGET_MIB)"
  FIT_CONTEXT="$(richiedi_variabile_config FIT_CONTEXT)"
  SERVER_PARALLEL="$(richiedi_variabile_config SERVER_PARALLEL)"
  SERVER_CACHE_RAM_MIB="$(richiedi_variabile_config SERVER_CACHE_RAM_MIB)"
  SERVER_CACHE_PROMPT="$(richiedi_variabile_config SERVER_CACHE_PROMPT)"
  SERVER_UI_ENABLED="$(richiedi_variabile_config SERVER_UI_ENABLED)"
  SERVER_STARTUP_TIMEOUT_SECONDS="$(richiedi_variabile_config SERVER_STARTUP_TIMEOUT_SECONDS)"
  SERVER_HEALTH_INTERVAL_SECONDS="$(richiedi_variabile_config SERVER_HEALTH_INTERVAL_SECONDS)"
  LLAMA_SERVER_EXTRA_ARGS="$(richiedi_variabile_config LLAMA_SERVER_EXTRA_ARGS)"
}

valida_configurazione() {
  if [[ "$MAIN_CPU_PROFILE" != "avx2" ]]; then
    errore "MAIN_CPU_PROFILE deve essere avx2, rilevato: $MAIN_CPU_PROFILE"
    exit 1
  fi

  valida_ipv4 "$RPC_HOST" || { errore "RPC_HOST non e' un IPv4 valido: $RPC_HOST"; exit 1; }
  valida_porta RPC_PORT "$RPC_PORT"
  valida_ipv4 "$SERVER_BIND_HOST" || { errore "SERVER_BIND_HOST non e' un IPv4 valido: $SERVER_BIND_HOST"; exit 1; }
  valida_ipv4_locale "$SERVER_PUBLISH_HOST" || { errore "SERVER_PUBLISH_HOST deve essere un IPv4 locale oppure 127.0.0.1, rilevato: $SERVER_PUBLISH_HOST"; exit 1; }
  valida_porta SERVER_PORT "$SERVER_PORT"
  valida_intero_positivo MAIN_THREADS "$MAIN_THREADS"
  valida_intero_positivo CONTEXT_SIZE "$CONTEXT_SIZE"
  valida_intero_positivo DEFAULT_MAX_TOKENS "$DEFAULT_MAX_TOKENS"
  valida_intero_positivo FIT_TARGET_MIB "$FIT_TARGET_MIB"
  valida_intero_positivo FIT_CONTEXT "$FIT_CONTEXT"
  valida_intero_positivo SERVER_PARALLEL "$SERVER_PARALLEL"
  valida_intero_positivo SERVER_STARTUP_TIMEOUT_SECONDS "$SERVER_STARTUP_TIMEOUT_SECONDS"
  valida_intero_positivo SERVER_HEALTH_INTERVAL_SECONDS "$SERVER_HEALTH_INTERVAL_SECONDS"

  if [[ ! "$SERVER_CACHE_RAM_MIB" =~ ^[0-9]+$ ]]; then
    errore "SERVER_CACHE_RAM_MIB deve essere un intero non negativo, rilevato: $SERVER_CACHE_RAM_MIB"
    exit 1
  fi

  case "$N_GPU_LAYERS" in
    auto|all)
      ;;
    *)
      if [[ ! "$N_GPU_LAYERS" =~ ^[0-9]+$ ]]; then
        errore "N_GPU_LAYERS deve essere auto, all oppure un intero non negativo, rilevato: $N_GPU_LAYERS"
        exit 1
      fi
      ;;
  esac

  if [[ "$FIT_MODE" != "on" && "$FIT_MODE" != "off" ]]; then
    errore "FIT_MODE deve essere on oppure off, rilevato: $FIT_MODE"
    exit 1
  fi

  case "$SPLIT_MODE" in
    layer|row|tensor|none)
      ;;
    *)
      errore "SPLIT_MODE deve essere layer, row, tensor oppure none, rilevato: $SPLIT_MODE"
      exit 1
      ;;
  esac

  if [[ "$SPLIT_MODE" != "layer" ]]; then
    errore "per questo primo test SPLIT_MODE deve essere obbligatoriamente layer, rilevato: $SPLIT_MODE"
    exit 1
  fi

  if [[ "$SERVER_CACHE_PROMPT" != "true" && "$SERVER_CACHE_PROMPT" != "false" ]]; then
    errore "SERVER_CACHE_PROMPT deve essere true oppure false, rilevato: $SERVER_CACHE_PROMPT"
    exit 1
  fi

  if [[ "$SERVER_UI_ENABLED" != "true" && "$SERVER_UI_ENABLED" != "false" ]]; then
    errore "SERVER_UI_ENABLED deve essere true oppure false, rilevato: $SERVER_UI_ENABLED"
    exit 1
  fi
}

verifica_modello() {
  modello_host="$MODEL_HOST_DIR/$MODEL_FILENAME"
  modello_container="$MODEL_CONTAINER_DIR/$MODEL_FILENAME"

  if [[ ! -r "$modello_host" || ! -f "$modello_host" ]]; then
    errore "modello non trovato o non leggibile: $modello_host"
    exit 1
  fi

  modello_byte="$(stat -c '%s' "$modello_host")"
  modello_leggibile="$(formatta_byte "$modello_byte")"
}

rileva_docker() {
  if docker version >/dev/null 2>&1; then
    docker_cmd=(docker)
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo docker version >/dev/null 2>&1; then
    docker_cmd=(sudo docker)
    return 0
  fi

  errore "Docker non e' utilizzabile ne' come utente corrente ne' tramite sudo docker."
  errore "Lo script non modifica i gruppi dell'utente: configurare l'accesso a Docker separatamente."
  exit 1
}

verifica_cpu_e_rpc() {
  info "Verifica CPU locale..."
  "$repo_root/scripts/verifica-cpu.sh" --profilo avx2

  info "Verifica collegamento RPC..."
  "$repo_root/scripts/verifica-rpc-atlas5.sh" --yes
}

verifica_immagine() {
  if ! "${docker_cmd[@]}" image inspect "$LLAMA_SERVER_IMAGE" >/dev/null 2>&1; then
    errore "immagine non trovata localmente: $LLAMA_SERVER_IMAGE"
    errore "Costruirla prima con: ./scripts/build-atlas5.sh"
    exit 1
  fi
}

verifica_porta_libera() {
  if timeout 1 bash -c "</dev/tcp/${SERVER_PUBLISH_HOST}/${SERVER_PORT}" >/dev/null 2>&1; then
    errore "porta gia' occupata: $SERVER_PUBLISH_HOST:$SERVER_PORT"
    exit 1
  fi
}

verifica_container_esistente() {
  local stato=""

  stato="$("${docker_cmd[@]}" ps -a --filter "name=^/${nome_container}$" --format '{{.Status}}' | head -n 1)"
  if [[ -z "$stato" ]]; then
    return 0
  fi

  if [[ "$stato" == Up* ]]; then
    info "Il container $nome_container e' gia' attivo: $stato"
    exit 0
  fi

  errore "esiste gia' un container arrestato chiamato $nome_container: $stato"
  errore "Gestirlo manualmente prima di riprovare."
  exit 1
}

prepara_extra_args() {
  extra_args=()

  [[ -z "$LLAMA_SERVER_EXTRA_ARGS" ]] && return 0

  if [[ "$LLAMA_SERVER_EXTRA_ARGS" =~ [\;\&\|\<\>\`\$\\\'\"\(\)\{\}] ]]; then
    errore "LLAMA_SERVER_EXTRA_ARGS contiene caratteri di shell non consentiti."
    exit 1
  fi

  read -r -a extra_args <<<"$LLAMA_SERVER_EXTRA_ARGS"
}

prepara_comando_server() {
  server_args=(
    --model "$modello_container"
    --rpc "$RPC_HOST:$RPC_PORT"
    --host "$SERVER_BIND_HOST"
    --port "$SERVER_PORT"
    --threads "$MAIN_THREADS"
    --threads-batch "$MAIN_THREADS"
    --ctx-size "$CONTEXT_SIZE"
    --n-predict "$DEFAULT_MAX_TOKENS"
    --n-gpu-layers "$N_GPU_LAYERS"
    --split-mode "$SPLIT_MODE"
    --fit "$FIT_MODE"
    --fit-target "$FIT_TARGET_MIB"
    --fit-ctx "$FIT_CONTEXT"
    --parallel "$SERVER_PARALLEL"
    --cache-ram "$SERVER_CACHE_RAM_MIB"
    --offline
  )

  if [[ -n "$TENSOR_SPLIT" ]]; then
    server_args+=(--tensor-split "$TENSOR_SPLIT")
  fi

  if [[ "$SERVER_CACHE_PROMPT" == "true" ]]; then
    server_args+=(--cache-prompt)
  else
    server_args+=(--no-cache-prompt)
  fi

  if [[ "$SERVER_UI_ENABLED" == "true" ]]; then
    server_args+=(--ui)
  else
    server_args+=(--no-ui)
  fi

  if ((${#extra_args[@]} > 0)); then
    server_args+=("${extra_args[@]}")
  fi
}

mostra_riepilogo() {
  local hostname_corrente=""
  local tensor_split_mostrato="$TENSOR_SPLIT"

  hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"
  [[ -n "$tensor_split_mostrato" ]] || tensor_split_mostrato="automatico"

  info
  info "Riepilogo avvio atlas5"
  info "Hostname                       : $hostname_corrente"
  info "Immagine                       : $LLAMA_SERVER_IMAGE"
  info "Nome container                 : $nome_container"
  info "Percorso modello               : $modello_host"
  info "Dimensione modello             : $modello_leggibile"
  info "RPC                            : $RPC_HOST:$RPC_PORT"
  info "HTTP pubblicato                : $SERVER_PUBLISH_HOST:$SERVER_PORT"
  info "Thread                         : $MAIN_THREADS"
  info "Contesto                       : $CONTEXT_SIZE"
  info "N GPU layers                   : $N_GPU_LAYERS"
  info "Split mode                     : $SPLIT_MODE"
  info "Tensor split                   : $tensor_split_mostrato"
  info "Fit mode e margine             : $FIT_MODE, $FIT_TARGET_MIB MiB"
  info "Parallel                       : $SERVER_PARALLEL"
  info "Cache RAM                      : $SERVER_CACHE_RAM_MIB MiB"
  info "Prompt cache                   : $SERVER_CACHE_PROMPT"
  info "UI                             : $SERVER_UI_ENABLED"
  info "Comando Docker                 : ${docker_cmd[*]}"
  info
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta=""
  printf 'Avviare Qwen3-Next-80B sul cluster atlas5/argo3? [s/N] '
  if ! read -r risposta; then
    info
    errore "conferma non ricevuta. Usare --yes solo per esecuzioni automatizzate consapevoli."
    exit 1
  fi

  case "$risposta" in
    s|S)
      ;;
    *)
      info "Operazione annullata."
      exit 0
      ;;
  esac
}

avvia_container() {
  local uid_corrente=""
  local gid_corrente=""

  uid_corrente="$(id -u)"
  gid_corrente="$(id -g)"

  "${docker_cmd[@]}" run -d \
    --name "$nome_container" \
    --user "$uid_corrente:$gid_corrente" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --publish "$SERVER_PUBLISH_HOST:$SERVER_PORT:$SERVER_PORT" \
    --mount "type=bind,src=$MODEL_HOST_DIR,dst=$MODEL_CONTAINER_DIR,readonly" \
    "$LLAMA_SERVER_IMAGE" \
    "${server_args[@]}"
}

codice_http_health() {
  local url="$1"
  local codice=""
  local output_wget=""

  if command -v curl >/dev/null 2>&1; then
    if codice="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)"; then
      printf '%s' "$codice"
    else
      printf '000'
    fi
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    output_wget="$(wget -q --server-response --spider -T 3 "$url" 2>&1 || true)"
    codice="$(awk '/HTTP\// { codice=$2 } END { if (codice != "") print codice }' <<<"$output_wget")"
    if [[ -n "$codice" ]]; then
      printf '%s' "$codice"
    else
      printf '000'
    fi
    return 0
  fi

  errore "manca curl o wget per interrogare l'endpoint health."
  exit 1
}

mostra_log_recenti() {
  info "Log recenti del container:"
  "${docker_cmd[@]}" logs --tail 30 "$nome_container" 2>&1 | sed '/^[[:space:]]*$/d' || true
}

attendi_health() {
  local codice=""
  local fine=0
  local health_url="http://${SERVER_PUBLISH_HOST}:${SERVER_PORT}/health"
  local ora=0

  fine=$(($(date +%s) + SERVER_STARTUP_TIMEOUT_SECONDS))

  while true; do
    if [[ "$("${docker_cmd[@]}" inspect -f '{{.State.Running}}' "$nome_container" 2>/dev/null || printf 'false')" != "true" ]]; then
      errore "il container e' terminato prima che il server fosse pronto."
      mostra_log_recenti
      exit 1
    fi

    codice="$(codice_http_health "$health_url")"
    if [[ "$codice" == "200" ]]; then
      info
      info "Qwen3-Next-80B e' stato caricato sul cluster atlas5/argo3."
      info "Health       : $health_url"
      info "API locale   : http://${SERVER_PUBLISH_HOST}:${SERVER_PORT}"
      info "Log          : ${docker_cmd[*]} logs -f $nome_container"
      info "Docker ps    : ${docker_cmd[*]} ps --filter name=$nome_container"
      return 0
    fi

    if [[ "$codice" == "503" ]]; then
      info "Server in caricamento: health HTTP 503."
    else
      info "Health non pronta: HTTP $codice."
    fi

    mostra_log_recenti

    ora="$(date +%s)"
    if (( ora >= fine )); then
      errore "timeout di avvio scaduto dopo ${SERVER_STARTUP_TIMEOUT_SECONDS} secondi."
      mostra_log_recenti
      exit 1
    fi

    sleep "$SERVER_HEALTH_INTERVAL_SECONDS"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assumi_si=true
      shift
      ;;
    -h|--help)
      mostra_uso
      exit 0
      ;;
    *)
      errore "opzione non riconosciuta: $1"
      mostra_uso >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"

verifica_file_richiesti
carica_configurazione
valida_configurazione
verifica_modello
rileva_docker
verifica_cpu_e_rpc
verifica_immagine
verifica_porta_libera
verifica_container_esistente
prepara_extra_args
prepara_comando_server
mostra_riepilogo
chiedi_conferma
avvia_container
attendi_health
