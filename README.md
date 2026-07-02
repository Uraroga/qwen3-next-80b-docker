# Qwen3-Next-80B distribuito su due PC con Docker e llama.cpp RPC

Esecuzione locale di **Qwen3-Next-80B-A3B-Instruct Q4_K_M** su due computer x86_64 senza GPU, usando:

- Docker
- `llama.cpp`
- backend RPC
- CPU con profili differenti
- RAM distribuita tra un nodo principale e un nodo remoto

Il progetto nasce come esperimento pratico: verificare fin dove può arrivare hardware desktop datato, purché configurato con attenzione.

> Stato del progetto: funzionante sul sistema descritto in questo README, ma ancora sperimentale e in fase di miglioramento.

---

## Risultato ottenuto

Configurazione realmente provata:

| Nodo | Ruolo | CPU | RAM | Profilo |
|---|---|---|---:|---|
| `atlas5` | nodo principale, modello e `llama-server` | Intel Core i5-4590, 4 core | 32 GB | AVX2 |
| `argo3` | nodo remoto `ggml-rpc-server` | Intel Core i3-3240, 2 core / 4 thread | 32 GB | AVX |

Software:

- Ubuntu 24.04 LTS
- Docker Engine
- `llama.cpp` revisione fissata a `b9858`
- modello `Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf`
- contesto iniziale: 4096 token
- un solo slot parallelo
- Web UI integrata di `llama-server`

Dati osservati nel test:

- dimensione GGUF: circa **45,09 GiB**
- parametri dichiarati dal modello: circa **79,67 miliardi**
- elaborazione prompt: circa **2,16 token/s**
- generazione: circa **1,18 token/s**

Questi valori appartengono a una singola configurazione reale e non sono una promessa di prestazioni su altro hardware.

Qwen3-Next-80B-A3B è un modello Mixture-of-Experts: la capacità totale è circa 80B, mentre una parte molto più piccola dei parametri viene attivata per ogni token. Il file completo deve comunque rimanere disponibile in memoria.

---

## Architettura

```text
                              rete locale fidata
                    ┌────────────────────────────────┐
                    │                                │
                    │          RPC TCP 50052         │
                    │                                ▼
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ atlas5                       │       │ argo3                        │
│                              │       │                              │
│ llama-server                 │◄─────►│ ggml-rpc-server              │
│ build AVX2                   │       │ build AVX                    │
│ modello GGUF locale          │       │ cache RPC locale             │
│ API e Web UI su 127.0.0.1    │       │ nessuna API pubblica         │
│ porta HTTP 8080              │       │ porta RPC vincolata alla LAN │
└──────────────────────────────┘       └──────────────────────────────┘
```

Argo3 non presta soltanto spazio di memoria: il backend RPC espone un dispositivo remoto a `llama.cpp` e partecipa anche alle operazioni assegnate a quel dispositivo.

---

## Avvertenza di sicurezza

Il backend RPC di `llama.cpp` è sperimentale e non deve essere esposto su Internet.

Usarlo esclusivamente:

- su una rete locale fidata;
- con la porta RPC vincolata all’indirizzo LAN corretto;
- senza port forwarding sul router;
- senza pubblicazione su interfacce non necessarie.

L’API HTTP, nella configurazione di esempio, viene pubblicata soltanto su:

```text
127.0.0.1:8080
```

---

## Struttura del repository

```text
.
├── argo3/
│   └── Dockerfile.rpc
├── atlas5/
│   └── Dockerfile.server
├── logs/
│   └── .gitkeep
├── scripts/
│   ├── avvia-argo3.sh
│   ├── avvia-atlas5.sh
│   ├── build-argo3.sh
│   ├── build-atlas5.sh
│   ├── installa-docker-ubuntu.sh
│   ├── verifica-cpu.sh
│   ├── verifica-risorse-cluster.sh
│   └── verifica-rpc-atlas5.sh
├── .env.example
├── .gitignore
├── AGENTS.md
├── docker-compose.yml
└── README.md
```

Il file `.env` contiene i valori locali e non deve essere pubblicato.

Il modello GGUF, le cache RPC, i log e le immagini Docker non fanno parte del repository.

---

## Prerequisiti

Su entrambi i nodi:

- Linux x86_64
- Ubuntu 24.04 LTS per lo script di installazione Docker incluso
- collegamento Ethernet locale
- accesso SSH consigliato
- spazio libero sufficiente per immagini Docker, cache e modello
- CPU compatibile con il profilo scelto
- Docker funzionante

Il progetto usa due immagini diverse perché le CPU non supportano le stesse istruzioni:

- atlas5: AVX2, FMA, F16C e BMI2
- argo3: AVX e F16C, senza AVX2

Non usare la stessa build AVX2 su entrambi i nodi.

---

## 1. Clonare il repository

Eseguire su entrambi i computer:

```bash
git clone https://github.com/Uraroga/qwen3-next-80b-docker.git
cd qwen3-next-80b-docker
```

In alternativa, il progetto può essere copiato tra i due nodi con `rsync`, mantenendo separati i file `.env`.

---

## 2. Preparare la configurazione locale

Su ciascun nodo:

```bash
cp .env.example .env
chmod 600 .env
```

Modificare `.env` con i valori della propria rete e dei propri percorsi.

Valori essenziali:

```dotenv
LLAMA_CPP_REF=b9858

RPC_HOST=192.168.1.20
RPC_PORT=50052

SERVER_PUBLISH_HOST=127.0.0.1
SERVER_PORT=8080

MODEL_HOST_DIR=/percorso/ai/modelli
MODEL_CONTAINER_DIR=/models
MODEL_FILENAME=Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf

CONTEXT_SIZE=4096
N_GPU_LAYERS=auto
TENSOR_SPLIT=
SPLIT_MODE=layer

SERVER_PARALLEL=1
SERVER_UI_ENABLED=true
```

### Configurazione di argo3

Su argo3, `RPC_HOST` deve essere l’indirizzo IPv4 assegnato ad argo3 stesso.

La cache RPC deve indicare una directory locale esterna al repository:

```dotenv
RPC_CACHE_ENABLED=true
RPC_CACHE_HOST_DIR=/percorso/cache/llama-rpc
RPC_CACHE_CONTAINER_DIR=/var/cache/llama.cpp
```

### Configurazione di atlas5

Su atlas5:

- `RPC_HOST` deve indicare argo3;
- `MODEL_HOST_DIR` deve contenere il GGUF;
- `SERVER_PUBLISH_HOST=127.0.0.1` mantiene API e Web UI accessibili solo localmente;
- `SERVER_UI_ENABLED=true` abilita la Web UI incorporata.

---

## 3. Verificare le CPU

Su argo3:

```bash
./scripts/verifica-cpu.sh --profilo avx
```

Su atlas5:

```bash
./scripts/verifica-cpu.sh --profilo avx2
```

Interrompere la procedura se il profilo richiesto non è compatibile con la CPU.

---

## 4. Installare Docker

Lo script incluso supporta Ubuntu 24.04 amd64 e usa il repository APT ufficiale Docker.

Eseguire su entrambi i nodi:

```bash
./scripts/installa-docker-ubuntu.sh --test
```

Lo script:

- non aggiunge l’utente al gruppo `docker`;
- non modifica `sudoers`;
- non modifica il firewall;
- non elimina immagini, container o volumi esistenti.

Per questo motivo gli altri script possono usare automaticamente `sudo docker`.

---

## 5. Preparare argo3

Su argo3:

```bash
./scripts/build-argo3.sh
```

Poi avviare il server RPC:

```bash
./scripts/avvia-argo3.sh
```

Il container viene creato con il nome:

```text
qwen3-next-rpc
```

Controllo rapido:

```bash
sudo docker ps --filter name=qwen3-next-rpc
sudo docker logs --tail 50 qwen3-next-rpc
```

---

## 6. Preparare atlas5

Su atlas5:

```bash
./scripts/build-atlas5.sh
```

Verificare il collegamento RPC:

```bash
./scripts/verifica-rpc-atlas5.sh
```

Verificare memoria locale, dimensione del modello e memoria remota:

```bash
./scripts/verifica-risorse-cluster.sh
```

Avviare il server principale:

```bash
./scripts/avvia-atlas5.sh
```

Il container viene creato con il nome:

```text
qwen3-next-server
```

Lo script attende che `/health` restituisca HTTP 200. Durante il caricamento HTTP 503 è normale.

---

## 7. Web UI e API

Quando il modello è pronto, aprire su atlas5:

```text
http://127.0.0.1:8080/
```

Endpoint utili:

```text
http://127.0.0.1:8080/health
http://127.0.0.1:8080/v1/models
http://127.0.0.1:8080/v1/chat/completions
```

Verifica della Web UI da terminale:

```bash
curl --compressed -sS -o /dev/null \
  -w 'HTTP %{http_code} - %{content_type}\n' \
  http://127.0.0.1:8080/
```

Risultato atteso:

```text
HTTP 200 - text/html; charset=utf-8
```

Un normale `curl` senza `--compressed` può ricevere HTTP 415 perché gli asset della UI sono serviti compressi.

---

## 8. Test dell’API

Elenco modelli:

```bash
curl -sS http://127.0.0.1:8080/v1/models | python3 -m json.tool
```

Esempio chat:

```bash
MODEL_ID="$(
  curl -sS http://127.0.0.1:8080/v1/models |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'
)"

curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "$(
    python3 - "$MODEL_ID" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [
        {
            "role": "user",
            "content": "Spiega in italiano che cosa rende particolare questo cluster."
        }
    ],
    "temperature": 0.3,
    "max_tokens": 256,
    "stream": False
}))
PY
  )" |
python3 -m json.tool
```

---

## 9. Evitare la sospensione durante i test lunghi

Passaggio facoltativo, usato sulla configurazione originale.

Su entrambi i nodi:

```bash
sudo systemctl mask \
  sleep.target \
  suspend.target \
  hibernate.target \
  hybrid-sleep.target
```

Questo impedisce la sospensione e l’ibernazione durante caricamenti o inferenze lunghe.

Per annullare la modifica:

```bash
sudo systemctl unmask \
  sleep.target \
  suspend.target \
  hibernate.target \
  hybrid-sleep.target
```

Questa impostazione modifica il comportamento generale del sistema: applicarla soltanto se realmente desiderata.

---

## 10. Arresto e log

Arrestare il server principale:

```bash
sudo docker stop qwen3-next-server
```

Arrestare il nodo RPC:

```bash
sudo docker stop qwen3-next-rpc
```

Log del server principale:

```bash
sudo docker logs -f qwen3-next-server
```

Log del server RPC:

```bash
sudo docker logs -f qwen3-next-rpc
```

Stato e consumo risorse:

```bash
sudo docker stats --no-stream qwen3-next-server
sudo docker stats --no-stream qwen3-next-rpc
```

---

## 11. Sincronizzazione tra i nodi

Nel sistema originale atlas5 viene trattato come copia principale del progetto.

Da atlas5 verso argo3:

```bash
rsync -av \
  --exclude='.env' \
  --exclude='.git' \
  ./ \
  utente@IP_ARGO3:/percorso/qwen3-next-80b-docker/
```

Il file `.env` deve rimanere specifico per ciascun nodo.

---

## Memoria e swap

La swap non sostituisce la RAM e non aumenta le prestazioni.

Durante i test originali:

- atlas5 ha utilizzato intensamente la swap durante il caricamento;
- argo3 ha utilizzato gran parte della RAM disponibile;
- il modello ha comunque completato il caricamento e l’inferenza.

Prima di modificare la swap, verificare:

```bash
free -h
swapon --show
vmstat -y -w 1 10
```

Non eseguire `swapoff` mentre il modello è caricato o quando una parte significativa del processo risiede nella swap.

---

## Risoluzione dei problemi

### `Illegal instruction`

La build non è compatibile con la CPU.

Verificare il profilo:

```bash
./scripts/verifica-cpu.sh --profilo avx
./scripts/verifica-cpu.sh --profilo avx2
```

### RPC non raggiungibile

Controllare su atlas5:

```bash
timeout 3 bash -c '</dev/tcp/192.168.1.20/50052'
```

Verificare inoltre:

- IP configurato;
- container RPC attivo;
- porta pubblicata sull’indirizzo LAN corretto;
- firewall locale;
- assenza di isolamento tra i nodi.

### `/health` restituisce 503

Il modello è ancora in caricamento.

### La radice `/` restituisce 404

Verificare:

```dotenv
SERVER_UI_ENABLED=true
```

e assicurarsi che l’immagine atlas5 sia stata compilata con:

```text
LLAMA_BUILD_UI=ON
LLAMA_USE_PREBUILT_UI=ON
```

### La radice `/` restituisce 415 con curl

Usare:

```bash
curl --compressed http://127.0.0.1:8080/
```

### Memoria insufficiente

Ridurre inizialmente:

- `CONTEXT_SIZE`;
- `SERVER_PARALLEL`;
- cache aggiuntive;
- richieste simultanee.

Controllare sempre RAM, swap e log del kernel prima di cambiare la distribuzione dei layer.

---

## Limiti attuali

- configurazione provata soltanto su due specifiche CPU Intel;
- backend RPC ancora sperimentale;
- nessuna cifratura o autenticazione del canale RPC;
- prestazioni fortemente dipendenti da RAM, rete, modello e quantizzazione;
- nessun supporto GPU configurato;
- nessuna gestione automatica completa del ciclo di vita del cluster;
- `docker-compose.yml` non è ancora il flusso operativo principale;
- la configurazione iniziale privilegia stabilità e prudenza, non prestazioni massime.

---

## Perché questo progetto è interessante

Non dimostra che un 80B diventi improvvisamente leggero.

Dimostra però che:

- due macchine con CPU differenti possono collaborare tramite `llama.cpp` RPC;
- build separate AVX e AVX2 possono usare la stessa revisione del codice;
- un modello quantizzato da circa 45 GiB può essere distribuito su circa 64 GB di RAM complessiva;
- un modello MoE di grandi dimensioni può produrre risposte utilizzabili anche su hardware desktop molto datato;
- Docker può rendere la procedura più riproducibile senza installare `llama.cpp` direttamente sugli host.

---

## Riferimenti

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [llama.cpp RPC backend](https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc)
- [llama.cpp HTTP server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
- [Qwen3-Next-80B-A3B-Instruct](https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct)

---

## Autore

Progetto e test reali di **Uraroga**.

Repository:

```text
https://github.com/Uraroga/qwen3-next-80b-docker
```

Contributi, test su hardware differente e segnalazioni sono benvenuti.

---

## Licenza

Questo progetto è software libero distribuito con licenza MIT.

Chiunque può usare, copiare, modificare e ridistribuire il codice, anche per scopi commerciali, mantenendo l'avviso di copyright e il testo della licenza.

Il testo completo è disponibile nel file [`LICENSE`](LICENSE).

Le licenze di `llama.cpp`, Qwen e del modello utilizzato restano separate e devono essere rispettate.
