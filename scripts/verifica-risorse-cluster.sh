#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

assumi_si=false

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/verifica-risorse-cluster.sh [opzioni]

Verifica le risorse locali e il dispositivo RPC remoto prima del primo
caricamento distribuito del modello.

Opzioni:
  --yes       Salta la conferma interattiva prima del container temporaneo.
  -h, --help  Mostra questo messaggio.

Note:
  - Lo script non avvia llama-server e non carica il modello.
  - Lo script non monta directory e non pubblica porte.
  - Lo script esegue solo un container temporaneo con --list-devices.
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
    if [[ -n "$valore" || "$nome" == "TENSOR_SPLIT" ]]; then
      printf '%s' "$valore"
      return 0
    fi
  fi

  errore "variabile $nome mancante o vuota in $file_config."
  exit 1
}

leggi_lscpu_campo() {
  local nome_campo="$1"

  if command -v lscpu >/dev/null 2>&1; then
    lscpu | awk -F: -v campo="$nome_campo" '
      $1 == campo {
        sub(/^[[:space:]]+/, "", $2)
        print $2
        exit
      }
    '
  fi
}

leggi_cpuinfo_campo() {
  local nome_campo="$1"

  if [[ -r /proc/cpuinfo ]]; then
    awk -F: -v campo="$nome_campo" '
      $1 ~ "^[[:space:]]*" campo "[[:space:]]*$" {
        sub(/^[[:space:]]+/, "", $2)
        print $2
        exit
      }
    ' /proc/cpuinfo
  fi
}

leggi_meminfo_kib() {
  local nome_campo="$1"

  awk -v campo="$nome_campo" '
    $1 == campo ":" {
      print $2
      exit
    }
  ' /proc/meminfo
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

verifica_file_richiesti() {
  local file=""
  local file_richiesti=(
    AGENTS.md
    .env
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

carica_configurazione() {
  file_config="$repo_root/.env"

  LLAMA_SERVER_IMAGE="$(richiedi_variabile_config LLAMA_SERVER_IMAGE)"
  MODEL_HOST_DIR="$(richiedi_variabile_config MODEL_HOST_DIR)"
  MODEL_CONTAINER_DIR="$(richiedi_variabile_config MODEL_CONTAINER_DIR)"
  MODEL_FILENAME="$(richiedi_variabile_config MODEL_FILENAME)"
  RPC_HOST="$(richiedi_variabile_config RPC_HOST)"
  RPC_PORT="$(richiedi_variabile_config RPC_PORT)"
  CONTEXT_SIZE="$(richiedi_variabile_config CONTEXT_SIZE)"
  N_GPU_LAYERS="$(richiedi_variabile_config N_GPU_LAYERS)"
  TENSOR_SPLIT="$(richiedi_variabile_config TENSOR_SPLIT)"

  if ! valida_ipv4 "$RPC_HOST"; then
    errore "RPC_HOST non e' un indirizzo IPv4 valido: $RPC_HOST"
    exit 1
  fi

  if [[ ! "$RPC_PORT" =~ ^[0-9]+$ ]] || (( 10#$RPC_PORT < 1 || 10#$RPC_PORT > 65535 )); then
    errore "RPC_PORT deve essere un intero tra 1 e 65535, rilevato: $RPC_PORT"
    exit 1
  fi
}

verifica_modello() {
  modello_percorso="$MODEL_HOST_DIR/$MODEL_FILENAME"

  if [[ ! -f "$modello_percorso" ]]; then
    errore "modello GGUF non trovato: $modello_percorso"
    exit 1
  fi

  modello_byte="$(stat -c '%s' "$modello_percorso")"
  modello_leggibile="$(formatta_byte "$modello_byte")"
}

raccogli_risorse_locali() {
  local ram_totale_kib=""
  local ram_disponibile_kib=""
  local swap_totale_kib=""
  local swap_libero_kib=""
  local swap_usato_kib=0

  hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"
  modello_cpu="$(leggi_lscpu_campo 'Model name')"
  if [[ -z "$modello_cpu" ]]; then
    modello_cpu="$(leggi_cpuinfo_campo 'model name')"
  fi
  if [[ -z "$modello_cpu" ]]; then
    modello_cpu="non rilevabile"
  fi

  ram_totale_kib="$(leggi_meminfo_kib MemTotal)"
  ram_disponibile_kib="$(leggi_meminfo_kib MemAvailable)"
  swap_totale_kib="$(leggi_meminfo_kib SwapTotal)"
  swap_libero_kib="$(leggi_meminfo_kib SwapFree)"

  if [[ -z "$ram_totale_kib" || -z "$ram_disponibile_kib" ]]; then
    errore "impossibile leggere MemTotal o MemAvailable da /proc/meminfo."
    exit 1
  fi

  [[ -n "$swap_totale_kib" ]] || swap_totale_kib=0
  [[ -n "$swap_libero_kib" ]] || swap_libero_kib=0
  swap_usato_kib=$((swap_totale_kib - swap_libero_kib))

  ram_totale_byte=$((ram_totale_kib * 1024))
  ram_disponibile_byte=$((ram_disponibile_kib * 1024))
  swap_totale_byte=$((swap_totale_kib * 1024))
  swap_usato_byte=$((swap_usato_kib * 1024))

  ram_totale_leggibile="$(formatta_byte "$ram_totale_byte")"
  ram_disponibile_leggibile="$(formatta_byte "$ram_disponibile_byte")"
  swap_totale_leggibile="$(formatta_byte "$swap_totale_byte")"
  swap_usato_leggibile="$(formatta_byte "$swap_usato_byte")"
}

verifica_tcp_rpc() {
  info "Verifica raggiungibilita' TCP di $RPC_HOST:$RPC_PORT..."
  if ! timeout 3 bash -c "</dev/tcp/${RPC_HOST}/${RPC_PORT}" >/dev/null 2>&1; then
    errore "server RPC non raggiungibile su $RPC_HOST:$RPC_PORT."
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

mostra_risorse_locali() {
  local tensor_split_mostrato="$TENSOR_SPLIT"

  if [[ -z "$tensor_split_mostrato" ]]; then
    tensor_split_mostrato="automatico"
  fi

  info
  info "Risorse locali atlas5"
  info "Hostname                       : $hostname_corrente"
  info "Modello CPU locale             : $modello_cpu"
  info "RAM totale locale              : $ram_totale_byte byte ($ram_totale_leggibile)"
  info "RAM disponibile locale         : $ram_disponibile_byte byte ($ram_disponibile_leggibile)"
  info "Swap totale                    : $swap_totale_byte byte ($swap_totale_leggibile)"
  info "Swap in uso                    : $swap_usato_byte byte ($swap_usato_leggibile)"
  info "Percorso completo modello      : $modello_percorso"
  info "Dimensione modello             : $modello_byte byte"
  info "Dimensione modello leggibile   : $modello_leggibile"
  info "CONTEXT_SIZE                   : $CONTEXT_SIZE"
  info "N_GPU_LAYERS                   : $N_GPU_LAYERS"
  info "TENSOR_SPLIT                   : $tensor_split_mostrato"
  info "Immagine llama-server          : $LLAMA_SERVER_IMAGE"
  info "Indirizzo RPC                  : $RPC_HOST:$RPC_PORT"
  info "Comando Docker                 : ${docker_cmd[*]}"
  info
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta=""
  printf 'Verificare le risorse del cluster atlas5/argo3? [s/N] '
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

esegui_list_devices() {
  local codice_uscita=0

  info "Esecuzione container temporaneo con --list-devices..."
  set +e
  output_rpc="$("${docker_cmd[@]}" run --rm "$LLAMA_SERVER_IMAGE" --rpc "$RPC_HOST:$RPC_PORT" --list-devices 2>&1)"
  codice_uscita=$?
  set -e

  printf '%s\n' "$output_rpc"

  if (( codice_uscita != 0 )); then
    errore "il comando --list-devices nel container e' terminato con errore."
    exit 1
  fi

  if grep -Fq 'Illegal instruction' <<<"$output_rpc"; then
    errore "il test del container ha prodotto 'Illegal instruction'."
    exit 1
  fi

  if grep -Eiq 'connection|connect|connessione|refused|timed out|timeout|unreachable|no route|failed to|could not' <<<"$output_rpc"; then
    errore "il test del container ha segnalato un errore di connessione."
    exit 1
  fi

  if ! grep -Eiq 'rpc' <<<"$output_rpc"; then
    errore "l'output non contiene un dispositivo RPC."
    exit 1
  fi
}

estrai_dispositivo_rpc() {
  local indirizzo_atteso="$RPC_HOST:$RPC_PORT"
  local riga_rpc=""
  local riga=""

  while IFS= read -r riga; do
    if [[ "$riga" =~ ^[[:space:]]*(RPC[0-9]+):[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+)[[:space:]]*\(([0-9]+)[[:space:]]+MiB,[[:space:]]*([0-9]+)[[:space:]]+MiB[[:space:]]+free\)[[:space:]]*$ ]]; then
      riga_rpc="$riga"
      rpc_nome="${BASH_REMATCH[1]}"
      rpc_indirizzo="${BASH_REMATCH[2]}"
      rpc_mem_totale_mib="${BASH_REMATCH[3]}"
      rpc_mem_libera_mib="${BASH_REMATCH[4]}"
      break
    fi
  done <<<"$output_rpc"

  if [[ -z "$riga_rpc" ]]; then
    info "Output completo ricevuto dal container:"
    printf '%s\n' "$output_rpc"
    errore "impossibile interpretare la riga del dispositivo RPC. Atteso formato simile a: RPC0: $indirizzo_atteso (31969 MiB, 31969 MiB free)"
    exit 1
  fi

  if [[ "$rpc_indirizzo" != "$indirizzo_atteso" ]]; then
    errore "indirizzo RPC estratto non corrispondente: rilevato $rpc_indirizzo, atteso $indirizzo_atteso"
    exit 1
  fi

  rpc_mem_totale="${rpc_mem_totale_mib} MiB"
  rpc_mem_libera="${rpc_mem_libera_mib} MiB"
  rpc_mem_libera_byte=$((rpc_mem_libera_mib * 1024 * 1024))
  rpc_mem_libera_leggibile="$(formatta_byte "$rpc_mem_libera_byte")"
}

mostra_riepilogo_rpc() {
  local differenza_teorica_byte=0
  local differenza_teorica_leggibile=""
  local segno_differenza=""
  local somma_teorica_byte=0
  local somma_teorica_leggibile=""

  somma_teorica_byte=$((ram_disponibile_byte + rpc_mem_libera_byte))
  differenza_teorica_byte=$((somma_teorica_byte - modello_byte))
  somma_teorica_leggibile="$(formatta_byte "$somma_teorica_byte")"
  if (( differenza_teorica_byte < 0 )); then
    segno_differenza="-"
    differenza_teorica_leggibile="$(formatta_byte "$((-differenza_teorica_byte))")"
  else
    segno_differenza="+"
    differenza_teorica_leggibile="$(formatta_byte "$differenza_teorica_byte")"
  fi

  info
  info "Dispositivo RPC rilevato"
  info "Nome dispositivo RPC           : $rpc_nome"
  info "Indirizzo RPC                  : $rpc_indirizzo"
  info "Memoria totale dichiarata      : $rpc_mem_totale"
  info "Memoria libera dichiarata      : $rpc_mem_libera ($rpc_mem_libera_byte byte, $rpc_mem_libera_leggibile)"
  info
  info "Riepilogo prudente teorico"
  info "Dimensione modello             : $modello_byte byte ($modello_leggibile)"
  info "RAM locale disponibile         : $ram_disponibile_byte byte ($ram_disponibile_leggibile)"
  info "Memoria RPC libera             : $rpc_mem_libera_byte byte ($rpc_mem_libera_leggibile)"
  info "Somma teorica memorie libere   : $somma_teorica_byte byte ($somma_teorica_leggibile)"
  info "Differenza teorica sul modello : ${segno_differenza}${differenza_teorica_byte#-} byte (${segno_differenza}$differenza_teorica_leggibile)"
  info "Avviso: questa e' una stima teorica preliminare."
  info "Avviso: sistema operativo, container, buffer di calcolo e cache KV richiedono margine aggiuntivo."
  info "Avviso: la somma teorica non coincide con la memoria interamente utilizzabile dal modello."
  info "Avviso: una differenza positiva non garantisce automaticamente il caricamento."
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
verifica_modello
raccogli_risorse_locali
verifica_tcp_rpc
rileva_docker
verifica_immagine
mostra_risorse_locali
chiedi_conferma
esegui_list_devices
estrai_dispositivo_rpc
mostra_riepilogo_rpc
