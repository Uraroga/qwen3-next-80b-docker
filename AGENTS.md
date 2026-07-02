# AGENTS.md

## Scopo del progetto

Questo repository è destinato a una pubblicazione pubblica su GitHub. Deve rimanere generico, leggibile e riutilizzabile da altri utenti.

Il progetto eseguirà `Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf` tramite `llama.cpp`, interamente dentro container Docker, usando due computer Ubuntu 24.04 collegati in rete locale:

- un nodo principale, che esegue `llama-server` in container;
- un nodo di supporto RPC, che esegue il server RPC di `llama.cpp` in container.

I dettagli reali dell'installazione di sviluppo, inclusi IP, username, percorsi locali del modello, porte e parametri, devono essere configurabili tramite file `.env` e non devono essere incorporati direttamente negli script pubblici.

## Regole di configurazione

- Il file `.env` reale non deve essere pubblicato o aggiunto a Git.
- Deve essere fornito solo un file `.env.example`, privo di segreti e valori personali.
- Non inserire password, token, chiavi SSH o altri segreti nel repository.
- IP, username, percorsi del modello, porte e parametri devono essere letti da configurazione, preferibilmente da `.env`.
- Gli indirizzi e i percorsi reali dell'installazione di sviluppo non devono comparire in script, configurazioni operative o documentazione pubblica, salvo esempi chiaramente anonimizzati.
- Il modello GGUF non deve mai essere copiato dentro il repository o aggiunto a Git.

## Vincoli operativi

- Non modificare `sudoers`.
- Non concedere privilegi permanenti all'utente.
- Non configurare reboot, shutdown o aggiornamenti automatici.
- Non creare o abilitare servizi `systemd` senza una scelta esplicita dell'utente.
- Non eliminare file o directory dell'utente.
- Non sovrascrivere configurazioni esistenti senza controllo preventivo e messaggio esplicito.
- Non eseguire installazioni, download, accessi di rete o comandi privilegiati se non richiesti espressamente nel singolo incarico.
- Tutti i componenti `llama.cpp` devono essere eseguiti nei container Docker, non installati direttamente sull'host.
- Quando possibile, le immagini Docker devono usare una versione precisa e riproducibile, evitando il tag generico `latest`.
- I container non devono essere eseguiti con modalità `privileged`.
- Il socket Docker non deve essere montato dentro i container.
- Le porte devono essere pubblicate soltanto quando necessario e devono essere configurabili.
- Il server RPC non deve essere considerato sicuro per l'esposizione su Internet: è destinato esclusivamente a una rete locale fidata.
- La modalità RPC richiede una compilazione personalizzata di `llama.cpp` con `GGML_RPC=ON`.
- Sia `llama-server` sul nodo principale sia `ggml-rpc-server` sul nodo remoto devono essere costruiti dalla stessa identica revisione del sorgente.
- La revisione di `llama.cpp` deve essere indicata mediante un tag o commit preciso e configurabile.
- Non usare automaticamente `master` o immagini Docker con tag `latest` nelle configurazioni riproducibili.
- Prima di scegliere una revisione devono essere controllati gli avvisi di sicurezza ufficiali di `llama.cpp`.
- Il server RPC non deve mai essere esposto direttamente su Internet.
- L'indirizzo sul quale un processo ascolta dentro un container deve essere distinto dall'indirizzo sul quale Docker pubblica la porta sull'host.
- La compilazione deve essere compatibile con entrambe le CPU del progetto e non deve presupporre che tutte supportino lo stesso insieme di istruzioni CPU.

## Compatibilità CPU obbligatoria

- Il nodo principale `atlas5` usa una CPU Intel Core i5-4590 e supporta AVX2.
- Il nodo RPC `argo3` usa una CPU Intel Core i3-3240 e supporta AVX, ma non AVX2.
- Un binario compilato per AVX2 non deve mai essere eseguito su `argo3`.
- Non utilizzare indiscriminatamente `-march=native` per creare immagini destinate a entrambi i computer.
- Non copiare su `argo3` un'immagine compilata e ottimizzata automaticamente su `atlas5`.
- Le due immagini devono essere costruite dalla stessa identica revisione di `llama.cpp`, ma con profili CPU differenti.
- La build di `atlas5` può abilitare AVX2.
- La build di `argo3` deve disabilitare esplicitamente AVX2.
- Anche FMA, F16C e BMI2 devono essere configurati esplicitamente e verificati rispetto alle CPU reali, senza essere dedotti soltanto dalla presenza di AVX.
- Gli script devono controllare le CPU tramite `/proc/cpuinfo` o `lscpu` e interrompersi con un messaggio chiaro quando il profilo richiesto non è compatibile.
- Il controllo deve essere eseguito sia prima della compilazione sia prima dell'avvio del container.
- Il progetto deve evitare errori "Illegal instruction" causati da immagini compilate per una CPU più recente.
- La compatibilità RPC richiede stessa revisione del sorgente e stesso protocollo RPC, ma immagini e binari non necessariamente identici.
- Ogni nodo deve usare la build adatta alla propria CPU.

### Profili CPU verificati

Questi valori derivano dai flag realmente esposti dalle due CPU del progetto.

Profilo `atlas5`:

- `GGML_NATIVE=OFF`
- `GGML_AVX=ON`
- `GGML_AVX2=ON`
- `GGML_FMA=ON`
- `GGML_F16C=ON`
- `GGML_BMI2=ON`

Profilo `argo3`:

- `GGML_NATIVE=OFF`
- `GGML_AVX=ON`
- `GGML_AVX2=OFF`
- `GGML_FMA=OFF`
- `GGML_F16C=ON`
- `GGML_BMI2=OFF`

Il profilo `argo3` deve mantenere AVX2, FMA e BMI2 disabilitati. F16C può essere abilitato su entrambe le macchine. Il profilo deve comunque essere controllato prima di ogni compilazione e avvio mediante `scripts/verifica-cpu.sh`. BMI1 viene rilevato dallo script a scopo informativo, ma non deve essere inventata una variabile CMake `GGML_BMI1` se non esiste nella revisione di `llama.cpp` utilizzata.

## Regole per script e automazione

- Gli script devono usare Bash in modalità rigorosa, ad esempio con `set -euo pipefail`.
- Gli script devono includere controlli degli errori e messaggi comprensibili.
- Gli script devono essere il più possibile idempotenti.
- Ogni nuova fase deve essere sviluppata separatamente e verificata prima di continuare.
- Commenti, documentazione e messaggi destinati agli utenti devono essere chiari e preferibilmente in italiano.

## Regole per Codex

- Prima di apportare modifiche, Codex deve leggere questo file e i file già presenti nel repository.
- Codex deve rispettare il perimetro del singolo incarico e non creare file, script, servizi o configurazioni non richiesti.
- Alla fine di ogni incarico Codex deve indicare:
  - file creati o modificati;
  - controlli eseguiti;
  - problemi o assunzioni ancora aperti.
