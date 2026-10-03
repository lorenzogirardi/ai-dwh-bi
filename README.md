# POC locale: utilizzo di Claude Code via OpenTelemetry → ClickHouse → Grafana

Proof of concept **solo locale** per raccogliere e visualizzare l'utilizzo di Claude Code.
Nessun componente cloud, nessun Kubernetes, nessun Prometheus/Loki: solo Docker Compose.

```
Claude Code (host)
   │  OTLP gRPC  → 127.0.0.1:4317   (o OTLP HTTP → 127.0.0.1:4318)
   ▼
OpenTelemetry Collector (container)  ──►  ClickHouse (container, nessuna porta esposta)
                                              │
                                              ▼
                                         Grafana (container) → http://localhost:3000
```

## Componenti e versioni

| Componente | Immagine | Versione |
| --- | --- | --- |
| OpenTelemetry Collector (contrib, include `clickhouse` exporter) | `otel/opentelemetry-collector-contrib` | `0.161.0` |
| ClickHouse | `clickhouse/clickhouse-server` | `25.10.7.6` |
| Grafana | `grafana/grafana` | `13.2.3` |
| Datasource ClickHouse per Grafana (installato all'avvio) | `grafana-clickhouse-datasource` | `4.22.0` |

Nessuna immagine usa `latest`.

### Porte

| Servizio | Porta host | Note |
| --- | --- | --- |
| Collector OTLP gRPC | `127.0.0.1:4317` | solo loopback |
| Collector OTLP HTTP/protobuf | `127.0.0.1:4318` | solo loopback |
| Collector health check | `127.0.0.1:13133` | extension `health_check`, `GET /` |
| Grafana | `127.0.0.1:3000` | solo loopback; `GRAFANA_HOST_PORT` in `.env` se la 3000 è occupata |
| ClickHouse | — | **nessuna porta pubblicata**, accessibile solo dalla network Compose |

## Prerequisiti

- Docker con Docker Compose v2 (`docker compose version`)
- Claude Code CLI installato sull'host (`claude --version`)
- curl e bash (per i controlli)

## Configurazione

Copia il file degli esempi e cambia le password:

```bash
cp .env.example .env
# apri .env e sostituisci i valori "replace-me-..."
```

- `.env` è in `.gitignore`: **non viene committato**.
- Le password non devono contenere `$` (Grafana espande le variabili `$VAR` nei file di provisioning).
- Le credenziali ClickHouse e l'admin di Grafana passano **solo** da `.env`:
  - Collector: `${env:CLICKHOUSE_USER}` / `${env:CLICKHOUSE_PASSWORD}` nel YAML;
  - Grafana: `$CLICKHOUSE_USER` / `$CLICKHOUSE_PASSWORD` nel provisioning del datasource;
  - admin Grafana: `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`.

## Avvio dello stack

```bash
docker compose up -d
docker compose ps          # clickhouse e grafana devono diventare "healthy"
```

Controllo di readiness:

```bash
# Collector (l'immagine è distroless: niente healthcheck Docker interni)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:13133/   # atteso 200

# Grafana
curl -s http://127.0.0.1:3000/api/health

# ClickHouse (dal container)
docker compose exec clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT 1"
```

> Nota: in questa macchina la porta 3000 era già occupata da un altro progetto Docker;
> in tal caso imposta `GRAFANA_HOST_PORT=3001` in `.env` e usa `http://localhost:3001`.

## Configurazione di Claude Code (solo shell corrente)

Tutte le variabili valgono per la shell in cui le esporti: **non** modifica `~/.claude.json`
né file di settings, e non persiste dopo `exit`.

```bash
# 1. abilita la telemetria e scegli gli exporter
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=none            # nessuna pipeline traces in questo POC

# 2. endpoint e protocollo (Claude Code NON ha un protocollo di default: va impostato)
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

# 3. privacy: contenuti disattivati (sono anche i default, li rendiamo espliciti)
export OTEL_LOG_USER_PROMPTS=0              # nessun testo dei prompt
export OTEL_LOG_ASSISTANT_RESPONSES=0       # nessuna risposta del modello
export OTEL_LOG_TOOL_DETAILS=0              # nessun dettaglio/argomento dei tool
export OTEL_LOG_TOOL_CONTENT=0              # nessun contenuto di output dei tool
export OTEL_LOG_RAW_API_BODIES=0            # nessun corpo API

# 4. attributi utili all'analisi
export OTEL_METRICS_INCLUDE_VERSION=true       # attributo app.version sulle metriche
export OTEL_METRICS_INCLUDE_REPOSITORY=true    # attributi vcs.* (serve remote "origin", vedi sotto)

# 5. intervalli più brevi comodi per il test (default: metriche 60000 ms, log 5000 ms)
export OTEL_METRIC_EXPORT_INTERVAL=5000
export OTEL_LOGS_EXPORT_INTERVAL=2000

# 6. avvia Claude Code DA QUESTA SHELL
claude
```

Chiudi la sessione con `exit`/`Ctrl-D` e le variabili spariscono dalla shell.

Variante alternativa su sola metriche/log via HTTP/protobuf (se preferisci la 4318):

```bash
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

### Identità: cosa finisce nei dati

- `user.id`: è un **identificatore anonimo e casuale** generato al primo avvio e salvato in
  `~/.claude.json`. Non è un codice dipendente/aziendale e non è derivato dal tuo account:
  cancellando il file, la volta successiva ne comparirebbe uno nuovo e non correlato.
  Per questo test usiamo l'identità standard fornita da Claude Code, senza toccare quel file.
- `user.account_uuid`, `user.account_id`, `user.email`: presenti **solo se la sessione è
  autenticata**; sono quelli più utili come identità reale dell'utente.
- `session.id`: identificativo della singola sessione.
- `service.name`: `claude-code` per le sessioni da terminale (`claude-code-desktop` per la
  Code tab di Claude Desktop).
- `OTEL_RESOURCE_ATTRIBUTES` è disponibile per aggiungere attributi custom, ma ogni chiave
  diventa una etichetta su tutte le serie: in un POC con un solo utente non serve.

## Copertura del framework di misurazione

La telemetria di Claude Code copre **solo l'area AI** (e in parte output/qualità):
non contiene cicli di vita degli item, WIP, review o survey.

| Area framework | Metrica | Fonte dati | Stato in questo POC |
| --- | --- | --- | --- |
| AI | Adozione (sessioni, utenti, start_type, repo) | `claude_code.session.count` + attributi `session.id`, `user.account_uuid`, `start_type`, `vcs.*` | **verificato con dati reali** |
| AI | Tempo attivo (utente vs CLI) | `claude_code.active_time.total` (`type=user\|cli`) | **verificato con dati reali** |
| AI | Costo | `claude_code.cost.usage` (USD, `model`, `query_source`) | **verificato con dati reali** |
| AI | Token e tipo d'uso | `claude_code.token.usage` (`type=input\|output\|cacheRead\|cacheCreation`, `model`, `query_source`) | **verificato con dati reali** |
| AI | Output/modifiche | `claude_code.lines_of_code.count` (`type=added\|removed`), `claude_code.commit.count`, `claude_code.pull_request.count` | `commit` e `pull_request` **verificati**; `lines_of_code` ancora 0 (serve edit via `Edit`/`Write`, vedi Limitazioni) |
| AI | Decisioni di editing | `claude_code.code_edit_tool.decision` (`tool_name`, `decision`, `source`, `language`) | mai emesso finora: nelle sessioni osservate gli edit passano da `Bash` |
| AI | Tool call | eventi `tool_result` / `tool_decision` in `otel_logs` | i nomi dei tool built-in sono visibili (`Bash`, `Read`, `ToolSearch`); nomi MCP/skill/agent risultano `custom`/`third-party` senza `OTEL_LOG_TOOL_DETAILS=1` |
| Quality (parziale) | errori API | evento `claude_code.api_error` | **verificato con dati reali** |
| Delivery / Flow / Product / Business / Survey | cycle time, WIP, aging, PR reopen, hotfix, survey, attesa decisioni | Jira / GitHub / GitLab / survey | **non coperti**: non li esporta Claude Code, servono altre fonti in ClickHouse |

Correlazione "adozione AI ↔ outcome": i join possibili sono **tempo**, **repository**
(`OTEL_METRICS_INCLUDE_REPOSITORY=true` → attributi `vcs.repository.name`, `vcs.owner.name`,
`vcs.provider.name`) e **utente** (`user.account_uuid`). Attenzione: i `vcs.*` vengono emessi
solo se la cartella di lavoro ha un remote `origin` url-shaped **al momento di avviare la
sessione** (questa cartella lo ha dal push del repo; le sessioni aperte prima non li
acquisiscono).

## Verifica dei dati

### 1. Il Collector riceve?

```bash
docker compose logs --tail=50 otel-collector
```

Cerca righe del clickhouse exporter ed eventuali errori di connessione/insert.

### 2. Le tabelle esistono e crescono?

```bash
./scripts/discover.sh
```

Lo script mostra: database, tabelle, conteggi righe, metriche ricevute, nomi degli eventi,
attributi di risorsa e attributi delle metriche. Eseguilo dopo una sessione Claude Code.

Controlli rapidi manuali:

```bash
docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "SHOW TABLES FROM otel"

docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "SELECT MetricName, count() FROM otel.otel_metrics_sum GROUP BY MetricName"

docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "SELECT Body, count() FROM otel.otel_logs GROUP BY Body ORDER BY 2 DESC"
```

### 3. Test minimo end-to-end

1. `docker compose up -d` e verifica i tre health check di cui sopra.
2. Esporta le variabili nella shell (sezione precedente).
3. Avvia `claude` da quella shell e fai una richiesta breve (es. "rispondi con ok").
4. Attendi un paio di secondi (metriche e log hanno intervallo ridotto), poi esegui
   `./scripts/discover.sh`: deve comparire `claude_code.session.count` in
   `otel_metrics_sum` e almeno l'evento `claude_code.user_prompt` in `otel_logs`.
5. Apri Grafana: la dashboard **"Claude Code - Adozione, costo e outcome (POC)"**
   (folder *Claude Code*) deve mostrare sessioni, tempo attivo, eventi nel tempo e top
   eventi. I pannelli di costo/token/output si riempiono dopo una sessione con chiamate
   API riuscite (nell'esempio la quota era esaurita, quindi restano a 0/vuoti).

Verifica ufficiale (dalla documentazione Claude Code): la metrica `claude_code.session.count`
viene emessa all'avvio di una sessione; per i log di sola verifica l'evento è
`claude_code.user_prompt`.

### 4. Grafana

- URL: `http://localhost:3000` (o `http://localhost:3001` se hai cambiato `GRAFANA_HOST_PORT`)
- Credenziali: quelle in `.env` (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`)
- Il datasource **ClickHouse** è già provisionato (`grafana/provisioning/datasources/`):
  non serve inserirlo a mano.
- La dashboard è provisionata da file (`grafana/dashboards/claude-code-poc.json`) e viene
  ricaricata ogni 30 s.

Dashboard organizzata per righe, allineate alla sezione
"Copertura del framework di misurazione" qui sopra:

| Riga | Contenuto | Stato |
| --- | --- | --- |
| AI · Adozione | sessioni, sessioni distinte, utenti, tempo attivo, `start_type`, tempo attivo per tipo | **verificata con dati reali** |
| AI · Costo e token | costo USD, token per `type`/`model`/`query_source` | **verificata con dati reali** |
| AI · Output e modifiche | linee aggiunte/rimosse, commit, PR, edit accettati/rifiutati, per repository | commit/PR **verificati**; linee ed edit a 0 (servono `Edit`/`Write`) |
| Outcome · GitHub | commit su branch di default (diretti vs via PR, AI-assisted), PR mergeate, costo per commit AI-assisted, cache hit, correlazione grezza adozione↔commit, outcome per repository | **dati reali** (import locale) |
| Eventi e qualità | eventi nel tempo, top eventi, ultimi eventi, errori API | **verificata con dati reali** |
| Copertura del framework | pannello testuale con cosa è/non è coperto | — |

### 5. Outcome da GitHub/git (import)

La telemetria OTel non contiene outcome di delivery. `scripts/import_github.sh` carica in
ClickHouse due tabelle, aggregabili per repository e tempo:

- `otel.gh_commit`: commit first-parent del **branch di default locale**, inclusi i commit
  **diretti su main**; `files/additions/deletions` da `git log --numstat`; `via_pr` (euristica:
  merge o subject `(#N)`); `ai_assisted` = trailer `Co-Authored-By: Claude`.
- `otel.gh_pull_request`: PR via GraphQL paginato (`gh`), con review count e `ai_assisted`.
- `is_bot` (commit e PR): autore bot (`[bot]`, github-actions, dependabot, renovate); la
  dashboard li esclude.

Nessun titolo, messaggio o nome autore viene salvato (l'autore serve solo a calcolare `is_bot`).

#### Guida: lanciare l'import

Si lancia a mano, un repo alla volta, sempre da questo progetto. Non parte in automatico.

1. **Prerequisiti (una volta)**: stack acceso (`docker compose ps`, clickhouse *healthy*),
   `gh auth status` loggato, `.env` presente.
2. **Aggiorna il repo da importare** (lo script legge il `main` *locale*):
   ```bash
   cd ~/Storage/home/<repo> && git pull
   ```
3. **Lancia l'import** (argomento = percorso del repo; senza argomento importa questo):
   ```bash
   cd <questo-progetto>
   ./scripts/import_github.sh ~/Storage/home/<repo>
   ```
   Per repo con molte PR servono alcune decine di secondi.
4. **Controlla l'esito**: a fine esecuzione stampa le righe importate (`PR`, `commit`).
5. **Guarda la dashboard**: riga *Outcome · GitHub*. Il default è 7 giorni: allarga l'intervallo
   (30 giorni, 1 anno) per vedere lo storico. Il costo per repo compare solo per sessioni Claude
   Code avviate dentro quel repo (attributi `vcs.*`).

Rilanciabile quante volte vuoi: le tabelle sono `ReplacingMergeTree`, niente duplicati.
Rilancialo dopo ogni `git pull` per avere dati aggiornati.

| Sintomo | Causa probabile |
| --- | --- |
| `docker compose ... not running` | Stack spento: `docker compose up -d` |
| `gh: ... not logged in` | `gh auth login` |
| Pannelli vuoti | Intervallo troppo corto, oppure repo mai importato |
| `PR 0` | Il repo non ha PR su GitHub |
| Commit mancanti | `git pull` non fatto prima dell'import |

Un commit AI senza trailer risulta manuale. Correlazione con la telemetria: solo grezza
(tempo/repo), non causale.

### 6. Log e utilità

```bash
docker compose logs -f otel-collector      # log del Collector
docker compose logs --tail=100 grafana
docker compose logs --tail=100 clickhouse

# valida la configurazione del Collector (stessa immagine usata dallo stack)
docker run --rm -v "$PWD/config/otel-collector.yaml:/config.yaml:ro" \
  -e CLICKHOUSE_USER=otel -e CLICKHOUSE_PASSWORD=x \
  otel/opentelemetry-collector-contrib:0.161.0 validate --config /config.yaml

# valida il Compose
docker compose config
```

## Checklist diagnostica se non arrivano dati

1. **Variabili della shell**: `echo $CLAUDE_CODE_ENABLE_TELEMETRY` deve stampare `1`;
   `echo $OTEL_EXPORTER_OTLP_ENDPOINT` deve essere `http://localhost:4317`.
   Le variabili devono essere esportate **nella stessa shell** da cui lanci `claude`.
2. **Protocollo mancante**: Claude Code non ha un protocollo OTLP di default: senza
   `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` l'export non parte.
3. **Collector raggiungibile**: `curl -s http://127.0.0.1:13133/` → `200`;
   `docker compose ps` deve mostrare `otel-collector` Up.
4. **Errori di export in Claude Code**: avvia `claude --debug-file /tmp/cc-debug.log`
   e cerca `[3P telemetry]`. (Le righe `[Anthropic telemetry]` non c'entrano.)
5. **Export caduti nel Collector**: `docker compose logs otel-collector | grep -i error`
   (tipici: connessione ClickHouse rifiutata, password errata, coda piena).
6. **ClickHouse non scrive**:
   `docker compose exec clickhouse clickhouse-client --user ... --password ... -q "SHOW TABLES FROM otel"`
   → se le tabelle non ci sono, l'exporter non ha mai ricevuto dati (create solo al primo insert).
7. **Grafana mostra "no data"**: verifica che il datasource risponda
   `GET /api/datasources/uid/clickhouse-poc/health` (atteso `"status":"OK"`) e che
   il range di tempo della dashboard contenga i dati.
8. **Contenuti**: se vedi `<REDACTED>` negli attributi `prompt`/`prompt_text`, la
   disattivazione del contenuto funziona come previsto.

## Arresto e cancellazione

```bash
docker compose down          # ferma i container, i volumi restano
docker compose down -v       # ferma i container E cancella i volumi (dati e stato Grafana)
```

Per un reset completo della cartella:

```bash
docker compose down -v && rm -rf .env
```

## Struttura dei file

```
docker-compose.yml                     # Collector, ClickHouse, Grafana
.env.example                           # modello delle credenziali (copiare in .env)
.gitignore                             # ignora .env
config/otel-collector.yaml             # config Collector (OTLP in, ClickHouse out)
grafana/provisioning/datasources/      # datasource ClickHouse (password da env)
grafana/provisioning/dashboards/       # provider delle dashboard file-based
grafana/dashboards/claude-code-poc.json# dashboard provisionata
scripts/discover.sh                    # scoperta schema/dati in ClickHouse
scripts/import_github.sh               # import commit/PR in ClickHouse (outcome)
docs/enterprise_fix.md                 # proposte per il rollout enterprise (Jira, privacy, hardening)
```

## Oltre il POC

Jira, flow, identità e hardening non sono coperti: vedi [`docs/enterprise_fix.md`](docs/enterprise_fix.md).

## Limitazioni note

- **Retention**: `ttl: 2160h` (90 giorni) nel clickhouse exporter. L'exporter applica la TTL solo
  alla *creazione* delle tabelle: per tabelle già esistenti usa
  `ALTER TABLE otel.<tabella> MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(90)`
  (`Timestamp` per `otel_logs`).
- **Schema**: `create_schema: true` (supportato dalla versione usata): database `otel` e
  tabelle `otel_logs`, `otel_metrics_sum`, `otel_metrics_gauge` … creati automaticamente.
- **Traces**: non configurati: Claude Code esporta span solo con
  `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` e `OTEL_TRACES_EXPORTER`, scelta che qui non serve.
- **Healthcheck del Collector**: l'immagine contrib è distroless (niente shell né wget),
  quindi non è possibile un `HEALTHCHECK` Docker interno: si usa l'estensione
  `health_check` sulla 13133, verificabile dall'host.
- **Metriche costo/token**: `claude_code.cost.usage`, `claude_code.token.usage`,
  `claude_code.commit.count` e `claude_code.pull_request.count` sono state verificate con
  dati reali (arrivano dopo le prime chiamate API riuscite). `claude_code.lines_of_code.count`
  e `claude_code.code_edit_tool.decision` restano a 0 finché la sessione non usa gli
  strumenti di editing.
- **Linee di codice ≠ commit**: `lines_of_code.count` conta solo le righe scritte con
  `Edit`/`Write`/`NotebookEdit`; le modifiche fatte da shell (git, script, CI) non vengono
  conteggiate, quindi "Linee aggiunte/rimosse" può restare 0 anche con molti commit.
  `commit.count` conta solo i commit creati da Claude Code (non quelli manuali o del bot CI).
- **Attribuzione `vcs.*` per sessione**: Claude Code legge l'`origin` **una volta all'avvio
  della sessione** e applica quegli attributi a tutte le metriche/eventi di quella sessione.
  Lavori su altri progetti fatti dalla stessa sessione restano accreditati al repo di
  partenza: per attribuzioni corrette, una sessione per progetto (con `cd` nella root).
- **Fusi orari**: ClickHouse lavora in **UTC** (`now()` è UTC): gli orari mostrati da
  `discover.sh` e dai pannelli tabellari sono UTC, non locale (CEST = UTC+2).
- **Colonna `EventName`**: negli `otel_logs` il nome evento è nella colonna `Body`
  (es. `claude_code.user_prompt`) e in `LogAttributes['event.name']`; la colonna `EventName`
  è vuota con questa combinazione di versioni. Le query della dashboard usano `Body`.
- **Singolo utente, nessuna TLS/auth sul Collector**: accettabile solo perché le porte OTLP
  sono bound a `127.0.0.1` e il test è su una sola macchina.
- **Stesso utente ClickHouse per Collector e Grafana**: in produzione userei un utente
  read-only dedicato per Grafana.
