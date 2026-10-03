#!/usr/bin/env bash
# Scoperta dello schema e dei dati realmente presenti in ClickHouse.
# Eseguire DOPO aver avviato lo stack e una sessione Claude Code:
#   ./scripts/discover.sh
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

ch() {
  docker compose exec -T clickhouse clickhouse-client \
    --user "${CLICKHOUSE_USER:-otel}" \
    --password "${CLICKHOUSE_PASSWORD:-}" \
    --database "${CLICKHOUSE_DB:-otel}" \
    --query "$1"
}

echo "== Database presenti =="
ch "SHOW DATABASES"

echo
echo "== Tabelle nel database otel =="
ch "SHOW TABLES FROM otel"

echo
echo "== Tabelle con righe (conteggio) =="
for t in $(ch "SELECT name FROM system.tables WHERE database = 'otel'" | tr -d '\r'); do
  n=$(ch "SELECT count() FROM otel.\`$t\`")
  printf '%-30s %s\n' "$t" "$n"
done

echo
echo "== Metriche ricevute (tabella sum) =="
ch "SELECT MetricName, count() AS punti, sum(Value) AS totale FROM otel.otel_metrics_sum GROUP BY MetricName ORDER BY punti DESC FORMAT PrettyCompact" \
  || echo "(tabella assente o vuota)"

echo
echo "== Metriche attese (documentazione Claude Code) vs presenti =="
expected=(
  claude_code.session.count
  claude_code.active_time.total
  claude_code.cost.usage
  claude_code.token.usage
  claude_code.lines_of_code.count
  claude_code.commit.count
  claude_code.pull_request.count
  claude_code.code_edit_tool.decision
)
for m in "${expected[@]}"; do
  hit=$(ch "SELECT count() FROM otel.otel_metrics_sum WHERE MetricName = '$m'" 2>/dev/null || echo 0)
  if [[ "${hit:-0}" -gt 0 ]]; then
    printf '  [presente]   %s (%s punti)\n' "$m" "$hit"
  else
    printf '  [assente]    %s\n' "$m"
  fi
done

echo
echo "== Attributi per metrica =="
ch "SELECT MetricName, groupArray(DISTINCT arrayJoin(mapKeys(Attributes))) AS attributi FROM otel.otel_metrics_sum GROUP BY MetricName FORMAT PrettyCompact" \
  || echo "(tabella assente)"

echo
echo "== Nomi degli eventi/log =="
ch "SELECT Body AS evento, count() AS n FROM otel.otel_logs GROUP BY evento ORDER BY n DESC FORMAT PrettyCompact" \
  || echo "(tabella assente)"

echo
echo "== Attributi di risorsa (service.name ecc.) =="
ch "SELECT DISTINCT ResourceAttributes['service.name'] AS service_name, ResourceAttributes['service.version'] AS version FROM otel.otel_logs FORMAT PrettyCompact"

echo
echo "== Attributi presenti sulle metriche =="
ch "SELECT DISTINCT arrayJoin(mapKeys(Attributes)) AS attr FROM otel.otel_metrics_sum ORDER BY attr FORMAT PrettyCompact"
