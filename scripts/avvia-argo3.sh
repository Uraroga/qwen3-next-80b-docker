#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

readonly CONTAINER_NAME="qwen3-next-rpc"

assumi_si=false

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/avvia-argo3.sh [opzioni]

Avvia in modo controllato il container ggml-rpc-server sul nodo argo3,
usando l'immagine gia' costruita e la configurazione locale .env.

Opzioni:
  --yes       Salta la conferma interattiva.
  -h, --help  Mostra questo messaggio.

Note:
  - Lo script usa solo .env come configurazione operativa.
  - Lo script non modifica i gruppi dell'utente.
  - Lo script non installa pacchetti e non modifica il firewall.
  - Lo script non cancella immagini, container, volumi o cache Docker.
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
    if [[ -n "$valore" ]]; then
      printf '%s' "$valore"
      return 0
    fi
  fi

  errore "variabile $nome mancante o vuota in $file_config."
  exit 1
}

leggi_variabile_opzionale() {
  local nome="$1"
  local valore=""

  if valore="$(leggi_variabile_config "$file_config" "$nome")"; then
    printf '%s' "$valore"
  fi
}

verifica_file_richiesti() {
  local file=""
  local file_richiesti=(
    AGENTS.md
    .env
    scripts/verifica-cpu.sh
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

  LLAMA_RPC_IMAGE="$(richiedi_variabile_config LLAMA_RPC_IMAGE)"
  RPC_CPU_PROFILE="$(richiedi_variabile_config RPC_CPU_PROFILE)"
  RPC_HOST="$(richiedi_variabile_config RPC_HOST)"
  RPC_BIND_HOST="$(richiedi_variabile_config RPC_BIND_HOST)"
  RPC_PORT="$(richiedi_variabile_config RPC_PORT)"
  RPC_THREADS="$(richiedi_variabile_config RPC_THREADS)"
  RPC_CACHE_ENABLED="$(richiedi_variabile_config RPC_CACHE_ENABLED)"
  RPC_CACHE_HOST_DIR="$(richiedi_variabile_config RPC_CACHE_HOST_DIR)"
  RPC_CACHE_CONTAINER_DIR="$(richiedi_variabile_config RPC_CACHE_CONTAINER_DIR)"
  LLAMA_RPC_EXTRA_ARGS="$(leggi_variabile_opzionale LLAMA_RPC_EXTRA_ARGS)"
}

valida_ipv4() {
  local indirizzo="$1"
  local parte=""
  local parti=()

  [[ "$indirizzo" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1

  IFS=. read -r -a parti <<<"$indirizzo"
  for parte in "${parti[@]}"; do
    [[ "$parte" =~ ^[0-9]+$ ]] || return 1
    (( parte >= 0 && parte <= 255 )) || return 1
  done
}

valida_intero_positivo() {
  local valore="$1"

  [[ "$valore" =~ ^[0-9]+$ ]] || return 1
  (( valore > 0 ))
}

valida_configurazione() {
  if [[ "$RPC_CPU_PROFILE" != "avx" ]]; then
    errore "RPC_CPU_PROFILE deve essere esattamente 'avx', rilevato: $RPC_CPU_PROFILE"
    exit 1
  fi

  if ! valida_ipv4 "$RPC_HOST"; then
    errore "RPC_HOST non e' un indirizzo IPv4 valido: $RPC_HOST"
    exit 1
  fi

  if [[ "$RPC_HOST" == "0.0.0.0" ]]; then
    errore "RPC_HOST non puo' essere 0.0.0.0: la porta deve essere pubblicata su un indirizzo locale specifico."
    exit 1
  fi

  if ! valida_ipv4 "$RPC_BIND_HOST"; then
    errore "RPC_BIND_HOST non e' un indirizzo IPv4 valido per il processo nel container: $RPC_BIND_HOST"
    exit 1
  fi

  if ! valida_intero_positivo "$RPC_PORT" || (( RPC_PORT > 65535 )); then
    errore "RPC_PORT deve essere un numero compreso tra 1 e 65535."
    exit 1
  fi

  if ! valida_intero_positivo "$RPC_THREADS"; then
    errore "RPC_THREADS deve essere un intero maggiore di zero."
    exit 1
  fi

  case "$RPC_CACHE_ENABLED" in
    true|false)
      ;;
    *)
      errore "RPC_CACHE_ENABLED deve essere 'true' oppure 'false'."
      exit 1
      ;;
  esac
}

verifica_cpu() {
  info "Verifica CPU per profilo avx..."
  "$repo_root/scripts/verifica-cpu.sh" --profilo avx
}

ip_locale_presente() {
  local indirizzo="$1"

  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$indirizzo"
    return $?
  fi

  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -Fxq "$indirizzo"
    return $?
  fi

  errore "impossibile verificare gli indirizzi IPv4 locali: comando ip non disponibile."
  exit 1
}

verifica_ip_locale() {
  if ! ip_locale_presente "$RPC_HOST"; then
    errore "RPC_HOST non risulta assegnato alla macchina locale: $RPC_HOST"
    exit 1
  fi
}

porta_occupata_con_ss() {
  ss -H -ltn | awk -v host="$RPC_HOST" -v port="$RPC_PORT" '
    {
      locale = $(NF - 1)
      gsub(/^\[/, "", locale)
      gsub(/\]$/, "", locale)
      if (locale == host ":" port || locale == "0.0.0.0:" port || locale == "*:" port || locale == ":::" port) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

porta_occupata_con_lsof() {
  lsof -nP -iTCP:"$RPC_PORT" -sTCP:LISTEN 2>/dev/null | awk -v host="$RPC_HOST" '
    NR > 1 && ($0 ~ host || $0 ~ "\\*" || $0 ~ "0.0.0.0") {
      found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

porta_in_ascolto() {
  if command -v ss >/dev/null 2>&1; then
    porta_occupata_con_ss
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    porta_occupata_con_lsof
    return $?
  fi

  errore "impossibile verificare la porta: installare ss o lsof."
  exit 1
}

verifica_porta_libera() {
  if porta_in_ascolto; then
    errore "la porta $RPC_HOST:$RPC_PORT risulta gia' in ascolto."
    exit 1
  fi
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

verifica_immagine_locale() {
  if ! "${docker_cmd[@]}" image inspect "$LLAMA_RPC_IMAGE" >/dev/null 2>&1; then
    errore "immagine Docker non trovata localmente: $LLAMA_RPC_IMAGE"
    info "Costruirla prima con:"
    info "  ./scripts/build-argo3.sh"
    exit 1
  fi
}

verifica_llama_cache_immagine() {
  local llama_cache_immagine=""

  if ! llama_cache_immagine="$(
    "${docker_cmd[@]}" image inspect \
      --format '{{range .Config.Env}}{{println .}}{{end}}' \
      "$LLAMA_RPC_IMAGE" |
      awk -F= '$1 == "LLAMA_CACHE" {
        print substr($0, index($0, "=") + 1)
        found = 1
        exit
      } END { if (!found) exit 1 }'
  )"; then
    errore "l'immagine non dichiara LLAMA_CACHE. Ricostruire l'immagine con ./scripts/build-argo3.sh."
    exit 1
  fi

  if [[ "$llama_cache_immagine" != "$RPC_CACHE_CONTAINER_DIR" ]]; then
    errore "L'immagine usa LLAMA_CACHE=$llama_cache_immagine, ma .env configura RPC_CACHE_CONTAINER_DIR=$RPC_CACHE_CONTAINER_DIR. Ricostruire l'immagine con ./scripts/build-argo3.sh."
    exit 1
  fi
}

stato_container_esistente() {
  "${docker_cmd[@]}" ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Status}}'
}

verifica_nome_container() {
  local stato=""

  stato="$(stato_container_esistente)"
  if [[ -z "$stato" ]]; then
    return 0
  fi

  if [[ "$stato" == Up* ]]; then
    info "Il server RPC risulta gia' attivo nel container $CONTAINER_NAME."
    "${docker_cmd[@]}" ps --filter "name=^/${CONTAINER_NAME}$"
    exit 0
  fi

  errore "esiste gia' un container arrestato con nome $CONTAINER_NAME."
  errore "Lo script non elimina e non sostituisce automaticamente container esistenti."
  exit 1
}

prepara_cache() {
  cache_args=()
  rpc_args_cache=()

  if [[ "$RPC_CACHE_ENABLED" != "true" ]]; then
    return 0
  fi

  mkdir -p "$RPC_CACHE_HOST_DIR"

  if [[ ! -d "$RPC_CACHE_HOST_DIR" || ! -w "$RPC_CACHE_HOST_DIR" ]]; then
    errore "directory cache non scrivibile dall'utente corrente: $RPC_CACHE_HOST_DIR"
    exit 1
  fi

  cache_args=(-v "${RPC_CACHE_HOST_DIR}:${RPC_CACHE_CONTAINER_DIR}")
  rpc_args_cache=(--cache)
}

prepara_argomenti_extra() {
  extra_args=()

  if [[ -z "$LLAMA_RPC_EXTRA_ARGS" ]]; then
    return 0
  fi

  if [[ "$LLAMA_RPC_EXTRA_ARGS" =~ [\;\|\&\`\<\>\$\(\)] ]]; then
    errore "LLAMA_RPC_EXTRA_ARGS contiene caratteri non accettati per un parsing prudente."
    exit 1
  fi

  read -r -a extra_args <<<"$LLAMA_RPC_EXTRA_ARGS"
}

mostra_riepilogo() {
  local hostname_corrente=""

  hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"

  info
  info "Riepilogo avvio RPC argo3"
  info "Hostname              : $hostname_corrente"
  info "Immagine              : $LLAMA_RPC_IMAGE"
  info "Nome container        : $CONTAINER_NAME"
  info "Profilo CPU           : $RPC_CPU_PROFILE"
  info "Indirizzo pubblicato  : $RPC_HOST"
  info "Porta                 : $RPC_PORT"
  info "Indirizzo interno     : $RPC_BIND_HOST"
  info "Thread                : $RPC_THREADS"
  info "Cache RPC             : $RPC_CACHE_ENABLED"
  if [[ "$RPC_CACHE_ENABLED" == "true" ]]; then
    info "Percorso cache host   : $RPC_CACHE_HOST_DIR"
  fi
  info "Comando Docker        : ${docker_cmd[*]}"
  info
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta=""
  printf 'Avviare il server RPC su argo3? [s/N] '
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
  local uid_gid=""
  uid_gid="$(id -u):$(id -g)"

  docker_run_cmd=(
    "${docker_cmd[@]}"
    run
    --detach
    --name
    "$CONTAINER_NAME"
    --user
    "$uid_gid"
    --cap-drop
    ALL
    --security-opt
    no-new-privileges:true
    -p
    "${RPC_HOST}:${RPC_PORT}:${RPC_PORT}"
    "${cache_args[@]}"
    "$LLAMA_RPC_IMAGE"
    --host
    "$RPC_BIND_HOST"
    --port
    "$RPC_PORT"
    --threads
    "$RPC_THREADS"
    "${rpc_args_cache[@]}"
    "${extra_args[@]}"
  )

  info "Avvio del container RPC..."
  "${docker_run_cmd[@]}"
}

mostra_log_container() {
  "${docker_cmd[@]}" logs --tail 40 "$CONTAINER_NAME" || true
}

verifica_container_avviato() {
  local stato=""

  sleep 2

  stato="$("${docker_cmd[@]}" inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [[ "$stato" != "true" ]]; then
    errore "il container non risulta in esecuzione dopo l'avvio."
    mostra_log_container
    exit 1
  fi

  info "Container in esecuzione:"
  "${docker_cmd[@]}" ps --filter "name=^/${CONTAINER_NAME}$"

  info
  info "Ultime righe dei log:"
  mostra_log_container
}

verifica_porta_in_ascolto() {
  if ! porta_in_ascolto; then
    errore "dopo l'avvio la porta $RPC_HOST:$RPC_PORT non risulta in ascolto."
    mostra_log_container
    exit 1
  fi
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
verifica_cpu
verifica_ip_locale
rileva_docker
verifica_nome_container
verifica_porta_libera
verifica_immagine_locale
verifica_llama_cache_immagine
prepara_argomenti_extra
mostra_riepilogo
chiedi_conferma
prepara_cache
avvia_container
verifica_container_avviato
verifica_porta_in_ascolto

info
info "Server RPC di argo3 avviato correttamente."
info
info "Comandi informativi utili:"
info "  sudo docker logs $CONTAINER_NAME"
info "  sudo docker ps"
info "Nota: quando Docker e' accessibile senza sudo, gli stessi comandi possono essere eseguiti senza sudo."
