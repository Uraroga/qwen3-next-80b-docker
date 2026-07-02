#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

assumi_si=false

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/verifica-rpc-atlas5.sh [opzioni]

Verifica che l'immagine llama-server di atlas5 rilevi il server RPC di argo3,
senza caricare un modello e senza avviare il server.

Opzioni:
  --yes       Salta la conferma interattiva.
  -h, --help  Mostra questo messaggio.

Note:
  - Lo script non modifica i gruppi dell'utente.
  - Lo script non installa pacchetti e non modifica la rete del sistema.
  - Lo script esegue solo un container temporaneo per elencare i dispositivi.
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

valida_configurazione() {
  file_config="$repo_root/.env"

  LLAMA_SERVER_IMAGE="$(richiedi_variabile_config LLAMA_SERVER_IMAGE)"
  MAIN_CPU_PROFILE="$(richiedi_variabile_config MAIN_CPU_PROFILE)"
  RPC_HOST="$(richiedi_variabile_config RPC_HOST)"
  RPC_PORT="$(richiedi_variabile_config RPC_PORT)"
  local rpc_port_num=0

  if [[ "$MAIN_CPU_PROFILE" != "avx2" ]]; then
    errore "MAIN_CPU_PROFILE deve essere esattamente 'avx2', rilevato: $MAIN_CPU_PROFILE"
    exit 1
  fi

  if ! valida_ipv4 "$RPC_HOST"; then
    errore "RPC_HOST non e' un indirizzo IPv4 valido: $RPC_HOST"
    exit 1
  fi

  if [[ ! "$RPC_PORT" =~ ^[0-9]+$ ]]; then
    errore "RPC_PORT deve essere un intero tra 1 e 65535, rilevato: $RPC_PORT"
    exit 1
  fi

  rpc_port_num=$((10#$RPC_PORT))
  if (( rpc_port_num < 1 || rpc_port_num > 65535 )); then
    errore "RPC_PORT deve essere un intero tra 1 e 65535, rilevato: $RPC_PORT"
    exit 1
  fi
}

verifica_cpu() {
  info "Verifica CPU per profilo avx2..."
  "$repo_root/scripts/verifica-cpu.sh" --profilo avx2
}

verifica_tcp_rpc() {
  info "Verifica raggiungibilita' TCP di $RPC_HOST:$RPC_PORT..."
  if ! timeout 3 bash -c "</dev/tcp/${RPC_HOST}/${RPC_PORT}" >/dev/null 2>&1; then
    errore "server RPC non raggiungibile su $RPC_HOST:$RPC_PORT."
    errore "Verificare che argo3 sia acceso, che il container RPC sia gia' attivo e che la porta sia raggiungibile dalla LAN."
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

verifica_immagine() {
  if ! "${docker_cmd[@]}" image inspect "$LLAMA_SERVER_IMAGE" >/dev/null 2>&1; then
    errore "immagine non trovata localmente: $LLAMA_SERVER_IMAGE"
    errore "Costruirla prima con: ./scripts/build-atlas5.sh"
    exit 1
  fi
}

mostra_riepilogo() {
  local hostname_corrente=""

  hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"

  info
  info "Riepilogo verifica RPC atlas5"
  info "Hostname             : $hostname_corrente"
  info "Immagine utilizzata  : $LLAMA_SERVER_IMAGE"
  info "Profilo CPU          : $MAIN_CPU_PROFILE"
  info "Indirizzo RPC        : $RPC_HOST:$RPC_PORT"
  info "Comando Docker       : ${docker_cmd[*]}"
  info
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta=""
  printf 'Verificare il collegamento RPC tra atlas5 e argo3? [s/N] '
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

verifica_output_rpc() {
  local output_test="$1"

  if grep -Fq 'Illegal instruction' "$output_test"; then
    errore "il test del container ha prodotto 'Illegal instruction'."
    exit 1
  fi

  if grep -Eiq 'connection|connect|connessione|refused|timed out|timeout|unreachable|no route|failed to|could not' "$output_test"; then
    errore "il test del container ha segnalato un errore di connessione."
    exit 1
  fi

  if ! grep -Eiq 'rpc' "$output_test"; then
    errore "l'output non contiene un dispositivo RPC."
    exit 1
  fi

  if ! grep -Fq "$RPC_HOST" "$output_test"; then
    errore "l'output non contiene RPC_HOST ($RPC_HOST)."
    exit 1
  fi

  if ! grep -Fq "$RPC_PORT" "$output_test"; then
    errore "l'output non contiene RPC_PORT ($RPC_PORT)."
    exit 1
  fi
}

esegui_test_rpc() {
  local output_test=""
  output_test="$(mktemp)"
  trap 'rm -f "$output_test"' RETURN

  info "Esecuzione test temporaneo --list-devices..."
  if ! "${docker_cmd[@]}" run --rm "$LLAMA_SERVER_IMAGE" --rpc "$RPC_HOST:$RPC_PORT" --list-devices >"$output_test" 2>&1; then
    cat "$output_test"
    verifica_output_rpc "$output_test"
    errore "il test RPC nel container e' terminato con errore."
    exit 1
  fi

  cat "$output_test"
  verifica_output_rpc "$output_test"
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
valida_configurazione
verifica_cpu
verifica_tcp_rpc
rileva_docker
verifica_immagine
mostra_riepilogo
chiedi_conferma
esegui_test_rpc

info
info "Collegamento RPC verificato: atlas5 rileva il dispositivo remoto di argo3."
