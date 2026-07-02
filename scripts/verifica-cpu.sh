#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

profilo=""

mostra_uso() {
  cat <<'EOF'
Uso:
  ./scripts/verifica-cpu.sh
  ./scripts/verifica-cpu.sh --profilo avx
  ./scripts/verifica-cpu.sh --profilo avx2

Opzioni:
  --profilo avx    Verifica che la CPU supporti AVX.
  --profilo avx2   Verifica che la CPU supporti AVX2.
  -h, --help       Mostra questo messaggio.
EOF
}

errore() {
  printf 'Errore: %s\n' "$*" >&2
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

leggi_flags_cpu() {
  local flags=""

  if command -v lscpu >/dev/null 2>&1; then
    flags="$(lscpu | awk -F: '
      tolower($1) == "flags" {
        sub(/^[[:space:]]+/, "", $2)
        print tolower($2)
        exit
      }
    ')"
  fi

  if [[ -z "$flags" && -r /proc/cpuinfo ]]; then
    flags="$(awk -F: '
      tolower($1) ~ /^[[:space:]]*flags[[:space:]]*$/ {
        sub(/^[[:space:]]+/, "", $2)
        print tolower($2)
        exit
      }
    ' /proc/cpuinfo)"
  fi

  printf '%s\n' "$flags"
}

leggi_core_fisici() {
  local core_per_socket=""
  local socket=""

  if command -v lscpu >/dev/null 2>&1; then
    core_per_socket="$(leggi_lscpu_campo 'Core(s) per socket')"
    socket="$(leggi_lscpu_campo 'Socket(s)')"

    if [[ "$core_per_socket" =~ ^[0-9]+$ && "$socket" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$((core_per_socket * socket))"
      return 0
    fi
  fi

  if [[ -r /proc/cpuinfo ]]; then
    awk '
      BEGIN { FS = ":" }
      $1 ~ /^[[:space:]]*physical id[[:space:]]*$/ {
        physical_id = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", physical_id)
      }
      $1 ~ /^[[:space:]]*core id[[:space:]]*$/ {
        core_id = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", core_id)
        if (physical_id != "" && core_id != "") {
          core[physical_id ":" core_id] = 1
        }
      }
      END {
        for (id in core) {
          count++
        }
        if (count > 0) {
          print count
        }
      }
    ' /proc/cpuinfo
  fi
}

ha_flag() {
  local flag="$1"
  [[ " $flags_cpu " == *" $flag "* ]]
}

stato_flag() {
  local flag="$1"

  if ha_flag "$flag"; then
    printf 'supportato'
  else
    printf 'non supportato'
  fi
}

valore_ggml() {
  local flag="$1"

  if ha_flag "$flag"; then
    printf 'ON'
  else
    printf 'OFF'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profilo)
      if [[ $# -lt 2 ]]; then
        errore "opzione --profilo senza valore."
        mostra_uso >&2
        exit 2
      fi
      profilo="$2"
      shift 2
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

case "$profilo" in
  ""|avx|avx2)
    ;;
  *)
    errore "profilo non riconosciuto: $profilo"
    mostra_uso >&2
    exit 2
    ;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
  errore "questo script supporta solo sistemi Linux."
  exit 1
fi

architettura="$(uname -m)"
if [[ "$architettura" != "x86_64" ]]; then
  errore "architettura non supportata: $architettura. Richiesto Linux x86_64."
  exit 1
fi

flags_cpu="$(leggi_flags_cpu)"
flags_cpu=" ${flags_cpu//$'\n'/ } "
flags_cpu="${flags_cpu,,}"

if [[ -z "${flags_cpu// }" ]]; then
  errore "impossibile leggere i flag CPU da lscpu o /proc/cpuinfo."
  exit 1
fi

hostname_corrente="$(hostname 2>/dev/null || printf 'non rilevabile')"
modello_cpu="$(leggi_lscpu_campo 'Model name')"
if [[ -z "$modello_cpu" ]]; then
  modello_cpu="$(leggi_cpuinfo_campo 'model name')"
fi
if [[ -z "$modello_cpu" ]]; then
  modello_cpu="non rilevabile"
fi

cpu_logiche="$(leggi_lscpu_campo 'CPU(s)')"
if [[ -z "$cpu_logiche" ]]; then
  cpu_logiche="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
fi
if [[ -z "$cpu_logiche" ]]; then
  cpu_logiche="non rilevabile"
fi

core_fisici="$(leggi_core_fisici)"
if [[ -z "$core_fisici" ]]; then
  core_fisici="non rilevabile"
fi

cat <<EOF
Informazioni CPU rilevate
Hostname          : $hostname_corrente
Modello CPU       : $modello_cpu
Architettura      : $architettura
CPU logiche       : $cpu_logiche
Core fisici       : $core_fisici

Flag CPU
AVX   : $(stato_flag avx)
AVX2  : $(stato_flag avx2)
FMA   : $(stato_flag fma)
F16C  : $(stato_flag f16c)
BMI1  : $(stato_flag bmi1)
BMI2  : $(stato_flag bmi2)

Configurazione GGML suggerita per questa CPU
GGML_NATIVE=OFF
GGML_AVX=$(valore_ggml avx)
GGML_AVX2=$(valore_ggml avx2)
GGML_FMA=$(valore_ggml fma)
GGML_F16C=$(valore_ggml f16c)
GGML_BMI2=$(valore_ggml bmi2)

Avviso: questo risultato descrive solo la CPU sulla quale lo script viene eseguito.
Ogni nodo deve essere verificato separatamente prima della compilazione e prima dell'avvio del container.
EOF

case "$profilo" in
  avx)
    if ! ha_flag avx; then
      errore "profilo avx richiesto, ma la CPU non supporta AVX."
      exit 1
    fi
    printf '\nProfilo richiesto: avx compatibile.\n'
    ;;
  avx2)
    if ! ha_flag avx2; then
      errore "profilo avx2 richiesto, ma la CPU non supporta AVX2."
      exit 1
    fi
    printf '\nProfilo richiesto: avx2 compatibile.\n'
    ;;
esac
