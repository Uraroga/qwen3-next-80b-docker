#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

rimuovi_conflitti=false
esegui_test=false
assumi_si=false

pacchetti_conflitto=(
  docker.io
  docker-compose
  docker-compose-v2
  docker-doc
  podman-docker
  containerd
  runc
)

pacchetti_docker=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/installa-docker-ubuntu.sh [opzioni]

Installa Docker Engine su Ubuntu 24.04 amd64 usando il repository APT
ufficiale di Docker.

Opzioni:
  --rimuovi-conflitti  Rimuove solo i pacchetti incompatibili realmente installati.
  --test               Dopo l'installazione esegue sudo docker run --rm hello-world.
  --yes                Salta la conferma interattiva.
  -h, --help           Mostra questo messaggio.

Note:
  - Lo script non aggiunge l'utente corrente al gruppo docker.
  - Lo script non installa Docker Desktop.
  - Lo script non modifica il firewall.
  - Lo script non elimina immagini, container, volumi o dati Docker esistenti.
EOF
}

errore() {
  printf 'Errore: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

comando_disponibile() {
  command -v "$1" >/dev/null 2>&1
}

pacchetto_installato() {
  local pacchetto="$1"

  dpkg-query -W -f='${db:Status-Abbrev}\n' "$pacchetto" 2>/dev/null | grep -q '^ii '
}

mostra_versioni_docker() {
  info "Versioni Docker rilevate:"
  docker --version
  docker buildx version
  docker compose version
}

verifica_servizio_docker() {
  info
  info "Stato del servizio Docker:"
  if sudo systemctl is-active docker; then
    info "Il servizio Docker risulta attivo."
  else
    errore "il servizio Docker non risulta attivo."
    return 1
  fi
}

verifica_comandi_docker() {
  local docker_ok=false
  local buildx_ok=false
  local compose_ok=false

  if comando_disponibile docker; then
    docker_ok=true
  fi

  if "$docker_ok" && docker buildx version >/dev/null 2>&1; then
    buildx_ok=true
  fi

  if "$docker_ok" && docker compose version >/dev/null 2>&1; then
    compose_ok=true
  fi

  if "$docker_ok" && "$buildx_ok" && "$compose_ok"; then
    mostra_versioni_docker
    verifica_servizio_docker
    info
    info "Docker Engine, Buildx e Compose sono gia' disponibili. Nessuna reinstallazione necessaria."
    exit 0
  fi

  if "$docker_ok" || "$buildx_ok" || "$compose_ok"; then
    info "Installazione Docker parziale rilevata:"
    info "  docker               : $("$docker_ok" && printf 'presente' || printf 'mancante')"
    info "  docker buildx version: $("$buildx_ok" && printf 'presente' || printf 'mancante')"
    info "  docker compose version: $("$compose_ok" && printf 'presente' || printf 'mancante')"
    info
    info "Lo script continuera' installando i componenti ufficiali mancanti, salvo conflitti APT."
  fi
}

leggi_os_release() {
  if [[ ! -r /etc/os-release ]]; then
    errore "impossibile leggere /etc/os-release."
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
}

verifica_sistema() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    errore "questo script supporta solo Linux."
    exit 1
  fi

  leggi_os_release

  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    errore "sistema non supportato: richiesto Ubuntu 24.04, rilevato ${PRETTY_NAME:-sconosciuto}."
    exit 1
  fi

  arch_uname="$(uname -m)"
  if [[ "$arch_uname" != "x86_64" ]]; then
    errore "architettura non supportata: $arch_uname. Richiesta x86_64/amd64."
    exit 1
  fi

  if ! comando_disponibile dpkg; then
    errore "dpkg non e' disponibile."
    exit 1
  fi

  arch_dpkg="$(dpkg --print-architecture)"
  if [[ "$arch_dpkg" != "amd64" ]]; then
    errore "architettura APT non supportata: $arch_dpkg. Richiesta amd64."
    exit 1
  fi

  if ! comando_disponibile sudo; then
    errore "sudo non e' disponibile. Installarlo o eseguire la procedura manualmente."
    exit 1
  fi

  if [[ -z "${VERSION_CODENAME:-}" ]]; then
    errore "codename Ubuntu non rilevabile da /etc/os-release."
    exit 1
  fi
}

rileva_conflitti_installati() {
  conflitti_installati=()

  local pacchetto
  for pacchetto in "${pacchetti_conflitto[@]}"; do
    if pacchetto_installato "$pacchetto"; then
      conflitti_installati+=("$pacchetto")
    fi
  done
}

gestisci_conflitti() {
  rileva_conflitti_installati

  if [[ "${#conflitti_installati[@]}" -eq 0 ]]; then
    return 0
  fi

  info "Pacchetti incompatibili installati:"
  printf '  - %s\n' "${conflitti_installati[@]}"
  info

  if ! "$rimuovi_conflitti"; then
    errore "installazione interrotta per evitare modifiche automatiche a pacchetti esistenti."
    info "Per rimuovere questi pacchetti eseguire nuovamente lo script con:"
    info "  ./scripts/installa-docker-ubuntu.sh --rimuovi-conflitti"
    exit 1
  fi
}

mostra_riepilogo() {
  info "Riepilogo operazioni previste"
  info "Sistema rilevato : ${PRETTY_NAME:-Ubuntu 24.04}"
  info "Codename APT     : ${VERSION_CODENAME}"
  info "Architettura APT : ${arch_dpkg}"
  info "Repository       : https://download.docker.com/linux/ubuntu"
  info "Chiave APT       : /etc/apt/keyrings/docker.asc"
  info "Sorgente APT     : /etc/apt/sources.list.d/docker.sources"
  info
  info "Pacchetti da installare:"
  printf '  - %s\n' "${pacchetti_docker[@]}"
  info

  if [[ "${#conflitti_installati[@]}" -gt 0 ]]; then
    info "Pacchetti incompatibili da rimuovere con apt-get remove -y:"
    printf '  - %s\n' "${conflitti_installati[@]}"
    info
  fi

  if "$esegui_test"; then
    info "Test finale       : sudo docker run --rm hello-world"
  else
    info "Test finale       : non eseguito, nessuna immagine verra' scaricata per il test."
  fi
}

chiedi_conferma() {
  if "$assumi_si"; then
    info "Conferma interattiva saltata per opzione --yes."
    return 0
  fi

  local risposta
  printf 'Continuare con l'\''installazione di Docker? [s/N] '
  if ! read -r risposta; then
    info
    errore "conferma non ricevuta. Usare --yes solo per installazioni automatizzate consapevoli."
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

rimuovi_pacchetti_conflitto() {
  if [[ "${#conflitti_installati[@]}" -eq 0 ]]; then
    return 0
  fi

  info "Rimozione dei soli pacchetti incompatibili installati..."
  sudo apt-get remove -y "${conflitti_installati[@]}"
}

configura_repository_docker() {
  local sorgente_temporanea
  sorgente_temporanea="$(mktemp)"

  info "Aggiornamento indice APT iniziale..."
  sudo apt-get update

  info "Installazione prerequisiti APT..."
  sudo apt-get install -y ca-certificates curl

  info "Preparazione keyring APT..."
  sudo install -m 0755 -d /etc/apt/keyrings

  info "Download della chiave ufficiale Docker..."
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  cat >"$sorgente_temporanea" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
Architectures: ${arch_dpkg}
EOF

  if [[ -e /etc/apt/sources.list.d/docker.sources ]]; then
    if cmp -s "$sorgente_temporanea" /etc/apt/sources.list.d/docker.sources; then
      info "Il file docker.sources esiste gia' ed e' aggiornato."
      rm -f "$sorgente_temporanea"
      return 0
    fi

    info "Il file /etc/apt/sources.list.d/docker.sources esiste e verra' aggiornato dopo conferma gia' ricevuta."
  else
    info "Creazione del file /etc/apt/sources.list.d/docker.sources."
  fi

  sudo install -m 0644 "$sorgente_temporanea" /etc/apt/sources.list.d/docker.sources
  rm -f "$sorgente_temporanea"
}

installa_docker() {
  configura_repository_docker

  info "Aggiornamento indice APT con il repository Docker..."
  sudo apt-get update

  info "Installazione Docker Engine e plugin ufficiali..."
  sudo apt-get install -y "${pacchetti_docker[@]}"
}

verifiche_finali() {
  info "Verifica servizio Docker..."
  sudo systemctl is-active docker

  info "Verifica docker version..."
  sudo docker version

  info "Verifica docker buildx version..."
  sudo docker buildx version

  info "Verifica docker compose version..."
  sudo docker compose version
}

test_hello_world() {
  if ! "$esegui_test"; then
    return 0
  fi

  info "Esecuzione test hello-world. Questa operazione puo' scaricare un'immagine Docker."
  sudo docker run --rm hello-world
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rimuovi-conflitti)
      rimuovi_conflitti=true
      shift
      ;;
    --test)
      esegui_test=true
      shift
      ;;
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

verifica_sistema
verifica_comandi_docker
gestisci_conflitti
mostra_riepilogo
chiedi_conferma
rimuovi_pacchetti_conflitto
installa_docker
verifiche_finali
test_hello_world

info
info "Installazione Docker completata."
info "L'utente corrente non e' stato aggiunto al gruppo docker."
