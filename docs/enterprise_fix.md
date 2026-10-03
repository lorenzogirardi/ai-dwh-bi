# enterprise_fix — proposte per il passaggio da POC a rollout di team

Questo POC misura **solo la telemetria AI** di Claude Code (adozione, costo, token, output).
Le proposte qui sotto non sono implementate: richiedono sistemi che il POC non ha.

## EF-1 · Integrazione Jira (work item, flow, qualità)

**Problema.** Il framework di misurazione (throughput Done vs Cancelled, cycle time per fase,
aging WIP, blocked duration, AI-assisted vs non-assisted stratificato) richiede dati sugli item
di lavoro. La telemetria di Claude Code non li contiene, e questo POC non ha Jira.

**Proposta.**

1. **Chiave di correlazione sessione → item.** Convenzione: Jira key nel nome del branch
   (`PROJ-123-descrizione`) e nel messaggio di commit. Il link sessione → item si ricava poi da
   `vcs.*` + branch/commit, oppure da un attributo di risorsa impostato all'avvio della sessione
   (`OTEL_RESOURCE_ATTRIBUTES=work.item=PROJ-123`). Attenzione: ogni chiave attributo è una
   etichetta su tutte le serie (cardinalità).
2. **Tabelle dei fatti in ClickHouse**, alimentate da un export Jira schedulato:
   - `work_item(key, type, size_class, ai_assistance, ai_use_case, external_dependency, created, resolved, resolution, cancellation_reason)`
   - `item_transition(key, from_state, to_state, ts)` — stati minimi: Ready for engineering,
     Discovery/design, Implementation, Review, Test/validation, Ready for release, Released
   - `item_blocked(key, start, end, reason_code)` — reason code obbligatori, non un flag
3. **Done e Cancelled separati** già nello schema (`resolution`), in ogni vista di throughput,
   cycle time e forecast.
4. **Campi obbligatori su Jira**: work type, size class, AI assistance (none/light/substantial),
   AI use case, external dependency.
5. **Dashboard di confronto** per work type × size, AI-assisted vs non, con cycle time per fase,
   review rounds, rework e costo AI.

**Prerequisiti.** Accesso API Jira (token di servizio, read-only), workflow Jira con stati
allineati alle fasi sopra, accordo del team sulle definizioni di size class e work type.

**Vincoli di privacy.** Solo aggregati per team/repository/classe di lavoro: niente ranking
individuali, niente token usati come proxy di produttività. Hash di `user.id` / `user.email`
nel Collector prima di condividere i dati (vedi EF-2).

**Esito atteso.** Evidenza su dove si sposta il vincolo (implementation → review, decisioni di
prodotto, dipendenze) e base per decidere se investire in review practices, test automation,
discovery o rimozione di dipendenze.

## EF-2 · Identità e privacy
- Processor `transform`/`attributes` nel Collector: hash di `user.id`, `user.email`,
  `user.account_uuid`.
- Attributi `team`, `work_class`, `ai_use_case` via `OTEL_RESOURCE_ATTRIBUTES` (managed settings).
- Utente ClickHouse read-only dedicato a Grafana.

## EF-3 · Distribuzione e hardening
- Configurazione Claude Code tramite managed settings, non export manuale in shell.
- Collector con TLS e autenticazione; porte non solo loopback.
- Retention e aggregati permanenti (materialized view) oltre i 90 giorni del POC.
- Persistenza/backup di ClickHouse, Grafana con SSO, dashboard e alert come codice.

## EF-4 · Altre fonti
- GitHub/GitLab: PR aperte/mergeate, review rounds, reopen rate, revert/hotfix, change failure rate.
- Survey mensile anonima (5 domande: focus, context switching, toil, qualità percepita, fiducia
  nell'output AI), solo aggregata.
