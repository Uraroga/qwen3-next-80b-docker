#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

assumi_si=false
usa_no_cache=false

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/build-argo3.sh [opzioni]

Costruisce e verifica l'immagine Docker RPC destinata al nodo argo3.

Opzioni:
  --no-cache  Aggiunge --no-cache al comando docker build.
  --yes       Salta la conferma interattiva.
  -h, --help  Mostra questo messaggio.

Note:
  - Lo script non modifica i gruppi dell'utente.
  - Lo script non cancella immagini, container, volumi o cache Docker.
  - Lo script non avvia il server RPC e non pubblica porte di rete.
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
    argo3/Dockerfile.rpc
    scripts/verifica-cpu.sh
  )

  for file in "${file_richiesti[@]}"; do
    if [[ ! -e "$repo_root/$file" ]]; then
      errore "file richiesto mancante: $repo_root/$file"
      exit 1
    fi
  done
}

scegli_file_config() {
  if [[ -f "$repo_root/.env" ]]; then
    file_config="$repo_root/.env"
  elif [[ -f "$repo_root/.env.example" ]]; then
    file_config="$repo_root/.env.example"
  else
    errore "manca sia .env sia .env.example nella radice del repository."
    exit 1
  fi
}

carica_configurazione() {
  scegli_file_config

  LLAMA_CPP_REF="$(richiedi_variabile_config LLAMA_CPP_REF)"
  LLAMA_RPC_IMAGE="$(richiedi_variabile_config LLAMA_RPC_IMAGE)"
  RPC_CPU_PROFILE="$(richiedi_variabile_config RPC_CPU_PROFILE)"

  if [[ "$RPC_CPU_PROFILE" != "avx" ]]; then
    errore "RPC_CPU_PROFILE deve essere obbligatoriamente 'avx', rilevato: $RPC_CPU_PROFILE"
    exit 1
  fi
}

verifica_cpu() {
  info "Verifica CPU per profilo avx..."
  "$repo_root/scripts/verifica-cpu.sh" --profilo avx
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

mostra_riepilogo() {
  local hostname_corrente=""

  hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"

  info
  info "Riepilogo build RPC argo3"
  info "Hostname                  : $hostname_corrente"
  info "Dockerfile utilizzato     : $repo_root/argo3/Dockerfile.rpc"
  info "LLAMA_CPP_REF             : $LLAMA_CPP_REF"
  info "LLAMA_RPC_IMAGE           : $LLAMA_RPC_IMAGE"
  info "Profilo CPU richiesto     : $RPC_CPU_PROFILE"
  info "Contesto Docker           : $repo_root"
  info "File configurazione       : $file_config"
  info "Comando Docker            : ${docker_cmd[*]}"
  if "$usa_no_cache"; then
    info "Cache build Docker        : disabilitata su richiesta"
  else
    info "Cache build Docker        : impostazione predefinita"
  fi
  info
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta=""
  printf 'Continuare con la build dell'\''immagine RPC per argo3? [s/N] '
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

esegui_build() {
  local comando_build=(
    "${docker_cmd[@]}"
    build
    --file
    argo3/Dockerfile.rpc
    --build-arg
    "LLAMA_CPP_REF=$LLAMA_CPP_REF"
    --tag
    "$LLAMA_RPC_IMAGE"
  )

  if "$usa_no_cache"; then
    comando_build+=(--no-cache)
  fi

  comando_build+=(.)

  info "Avvio docker build..."
  (
    cd "$repo_root"
    "${comando_build[@]}"
  )
}

verifica_immagine() {
  info "Verifica presenza immagine..."
  "${docker_cmd[@]}" image inspect "$LLAMA_RPC_IMAGE" >/dev/null

  info "Immagine costruita:"
  "${docker_cmd[@]}" image ls "$LLAMA_RPC_IMAGE"
}

verifica_container_help() {
  local output_test=""
  output_test="$(mktemp)"
  trap 'rm -f "$output_test"' RETURN

  info "Verifica esecuzione temporanea del comando --help..."
  if ! "${docker_cmd[@]}" run --rm "$LLAMA_RPC_IMAGE" --help >"$output_test" 2>&1; then
    cat "$output_test"
    if grep -Fq 'Illegal instruction' "$output_test"; then
      errore "il test del container ha prodotto 'Illegal instruction'."
    else
      errore "il test del container e' terminato con errore."
    fi
    exit 1
  fi

  cat "$output_test"

  if grep -Fq 'Illegal instruction' "$output_test"; then
    errore "il test del container ha prodotto 'Illegal instruction'."
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assumi_si=true
      shift
      ;;
    --no-cache)
      usa_no_cache=true
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
verifica_cpu
rileva_docker
mostra_riepilogo
chiedi_conferma
esegui_build
verifica_immagine
verifica_container_help

info
info "Build e verifica dell'immagine RPC completate correttamente."
