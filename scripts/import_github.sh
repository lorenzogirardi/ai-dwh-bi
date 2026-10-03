#!/usr/bin/env bash
# Importa in ClickHouse le PR (via gh) e i commit del branch di default (via git log)
# del repository corrente, per correlarli con la telemetria di Claude Code.
#   ./scripts/import_github.sh [percorso-repo]     (default: questa cartella)
# Idempotente: tabelle ReplacingMergeTree, rilanciabile senza duplicati.
# Privacy: nessun titolo, autore o messaggio salvato; l'autore serve solo a calcolare il flag is_bot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "${1:-$ROOT}" && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

ch() {
  docker compose exec -T clickhouse clickhouse-client \
    --user "${CLICKHOUSE_USER:-otel}" --password "${CLICKHOUSE_PASSWORD:-}" \
    --database "${CLICKHOUSE_DB:-otel}" "$@"
}

ch --multiquery --query "
CREATE TABLE IF NOT EXISTS otel.gh_pull_request (
  repo LowCardinality(String), number UInt32, state LowCardinality(String), is_draft UInt8,
  created_at DateTime, merged_at Nullable(DateTime), closed_at Nullable(DateTime),
  additions UInt32, deletions UInt32, changed_files UInt32, commits UInt32, review_count UInt32,
  ai_assisted UInt8, imported_at DateTime DEFAULT now(), is_bot UInt8 DEFAULT 0
) ENGINE = ReplacingMergeTree(imported_at) ORDER BY (repo, number);

CREATE TABLE IF NOT EXISTS otel.gh_commit (
  repo LowCardinality(String), sha String, committed_at DateTime,
  files UInt32, additions UInt32, deletions UInt32,
  is_merge UInt8, via_pr UInt8, ai_assisted UInt8, imported_at DateTime DEFAULT now(), is_bot UInt8 DEFAULT 0
) ENGINE = ReplacingMergeTree(imported_at) ORDER BY (repo, sha);

ALTER TABLE otel.gh_commit ADD COLUMN IF NOT EXISTS is_bot UInt8 DEFAULT 0;
ALTER TABLE otel.gh_pull_request ADD COLUMN IF NOT EXISTS is_bot UInt8 DEFAULT 0;"

cd "$REPO_DIR"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
export REPO BRANCH

# --- PR ---
# GraphQL paginato (pagine da 20): gh pr list --json con commits/reviews supera il limite dei nodi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
PR_ROWS="$(gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -f query='
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 20, after: $endCursor, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number state isDraft author { __typename login } createdAt mergedAt closedAt additions deletions changedFiles
        commits(first: 100) { totalCount nodes { commit { message } } }
        reviews { totalCount }
      }
    }
  }
}' | python3 -c '
import json, os, sys
def ts(v): return v.replace("T"," ").rstrip("Z") if v else None
dec, buf, i = json.JSONDecoder(), sys.stdin.read(), 0
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i += 1
    if i >= len(buf): break
    page, i = dec.raw_decode(buf, i)
    for p in page["data"]["repository"]["pullRequests"]["nodes"]:
        ai = any("co-authored-by: claude" in c["commit"]["message"].lower() for c in p["commits"]["nodes"])
        print(json.dumps({"repo": os.environ["REPO"], "number": p["number"], "state": p["state"],
          "is_draft": int(p["isDraft"]), "created_at": ts(p["createdAt"]), "merged_at": ts(p["mergedAt"]),
          "closed_at": ts(p["closedAt"]), "additions": p["additions"], "deletions": p["deletions"],
          "changed_files": p["changedFiles"], "commits": p["commits"]["totalCount"],
          "review_count": p["reviews"]["totalCount"], "ai_assisted": int(ai),
          "is_bot": int((p.get("author") or {}).get("__typename") == "Bot" or "[bot]" in ((p.get("author") or {}).get("login") or ""))}))')"
if [[ -n "$PR_ROWS" ]]; then
  printf '%s\n' "$PR_ROWS" | ( cd "$ROOT" && ch --query "INSERT INTO otel.gh_pull_request FORMAT JSONEachRow" )
else
  echo "nessuna PR da importare"
fi

# --- Commit sul branch di default (include i commit diretti, senza PR) ---
TZ=UTC git log "$BRANCH" --first-parent --numstat --date=format-local:'%Y-%m-%d %H:%M:%S' \
  --format='@@%H|%cd|%P|%an|%s|%(trailers:key=Co-Authored-By,valueonly,separator=;)' 2>/dev/null |
python3 -c '
import json, os, re, sys
rows, cur = [], None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("@@"):
        if cur: rows.append(cur)
        sha, date, parents, author, rest = line[2:].split("|", 4)
        subject, _, trailers = rest.rpartition("|")
        merge = int(len(parents.split()) > 1)
        via_pr = int(merge or bool(re.search(r"\(#\d+\)\s*$", subject)) or subject.startswith("Merge pull request"))
        cur = {"repo": os.environ["REPO"], "sha": sha, "committed_at": date, "files": 0, "additions": 0,
               "deletions": 0, "is_merge": merge, "via_pr": via_pr, "ai_assisted": int("claude" in trailers.lower()),
               "is_bot": int(bool(re.search(r"\[bot\]|github.?actions|dependabot|renovate", author, re.I)))}
    elif line.strip() and cur:
        a, d, _ = line.split("\t", 2)
        cur["files"] += 1
        cur["additions"] += int(a) if a.isdigit() else 0
        cur["deletions"] += int(d) if d.isdigit() else 0
if cur: rows.append(cur)
for r in rows: print(json.dumps(r))' |
  ( cd "$ROOT" && ch --query "INSERT INTO otel.gh_commit FORMAT JSONEachRow" )

cd "$ROOT"
echo "== $REPO ($BRANCH) =="
ch --query "SELECT 'PR' AS tabella, count() AS righe FROM otel.gh_pull_request FINAL WHERE repo='$REPO' UNION ALL SELECT 'commit', count() FROM otel.gh_commit FINAL WHERE repo='$REPO' FORMAT PrettyCompact"
