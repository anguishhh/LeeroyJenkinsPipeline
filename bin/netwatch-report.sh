#!/usr/bin/env bash
#
# NetWatch-Report – zeigt die Monitoring-Ergebnisse aus der Datenbank auf der Konsole an.
#
# Aufruf:  netwatch-report.sh [ANZAHL]    (Standard: die letzten 20 Prüfungen)
#
# Im laufenden Container:
#   docker exec netwatch-netwatch-1 netwatch-report.sh 50
#
# Verbindungsdaten wie bei netwatch.sh über PGHOST, PGDATABASE, PGUSER, PGPASSWORD.

set -euo pipefail
echo $max_rows

max_rows="${1:-20}"
if [[ ! "$max_rows" =~ ^[1-9][0-9]*$ ]]; then
    echo "Aufruf: $(basename "$0") [ANZAHL]" >&2
    exit 2
fi

# psql mit einheitlichen Optionen; die SQL-Abfrage kommt über stdin
query() {
    psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 --set max_rows="$max_rows"
}

echo "=== Aktueller Status je System ==="
query <<'SQL'
SELECT hostname                                     AS "Hostname",
       ip_address                                   AS "IP-Adresse",
       to_char(checked_at, 'YYYY-MM-DD HH24:MI:SS') AS "Prüfzeitpunkt",
       status                                       AS "Status",
       round(response_time_ms, 1) || ' ms'          AS "Antwortzeit"
FROM   v_latest_status
ORDER  BY hostname;
SQL

echo "=== Letzte $max_rows Prüfungen ==="
query <<'SQL'
SELECT h.hostname                                     AS "Hostname",
       h.ip_address                                   AS "IP-Adresse",
       to_char(c.checked_at, 'YYYY-MM-DD HH24:MI:SS') AS "Prüfzeitpunkt",
       c.status                                       AS "Status",
       round(c.response_time_ms, 1) || ' ms'          AS "Antwortzeit"
FROM   checks c
JOIN   hosts  h USING (host_id)
ORDER  BY c.checked_at DESC, c.check_id DESC
LIMIT  :max_rows;
SQL
