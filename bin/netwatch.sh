#!/usr/bin/env bash
#
# NetWatch – einfaches Netzwerk-Monitoring per Ping
#
# Liest eine Liste von Systemen aus einer Konfigurationsdatei, prüft jedes System
# per ICMP-Ping auf Erreichbarkeit und speichert das Ergebnis (Hostname, IP-Adresse,
# Prüfzeitpunkt, Status, Antwortzeit) in einer PostgreSQL-Datenbank.
#
# Aufruf:
#   netwatch.sh           Dauerbetrieb: Prüfung alle NETWATCH_INTERVAL Sekunden
#   netwatch.sh --once    genau ein Prüfdurchlauf, danach Ende (für Tests)
#   netwatch.sh --help    Hilfe anzeigen
#
# Konfiguration ausschließlich über Umgebungsvariablen – Zugangsdaten stehen
# NICHT im Skript, sondern werden von Docker Compose / Jenkins übergeben:
#   NETWATCH_HOSTS_FILE    Hostliste                          (Standard: /app/config/hosts.conf)
#   NETWATCH_SCHEMA_FILE   SQL-Datei mit dem Datenbankschema  (Standard: /app/sql/schema.sql)
#   NETWATCH_INTERVAL      Prüfintervall in Sekunden          (Standard: 60)
#   NETWATCH_PING_TIMEOUT  Wartezeit pro Ping in Sekunden     (Standard: 2)
#   NETWATCH_DB_RETRIES    Verbindungsversuche beim Start     (Standard: 30, Abstand 2 s)
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD  – Standardvariablen von psql
#
# Ausgabe: Prüfergebnisse auf stdout, Meldungen (INFO/WARN/ERROR) auf stderr.
# Exit-Codes: 0 = OK, 1 = Fehler (z. B. Datenbank nicht erreichbar), 2 = falscher Aufruf

HOSTS_FILE="${NETWATCH_HOSTS_FILE:-/app/config/hosts.conf}"
SCHEMA_FILE="${NETWATCH_SCHEMA_FILE:-/app/sql/schema.sql}"
INTERVAL="${NETWATCH_INTERVAL:-60}"
PING_TIMEOUT="${NETWATCH_PING_TIMEOUT:-2}"
DB_RETRIES="${NETWATCH_DB_RETRIES:-30}"
VERSION="${NETWATCH_VERSION:-dev}"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

# Meldung mit Zeitstempel ausgeben. Geht auf stderr, damit sich Meldungen nicht
# mit Daten auf stdout vermischen (z. B. bei hosts=$(read_hosts ...)).
# Aufruf: log LEVEL NACHRICHT
log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--once | --help]
  (ohne Option)  Dauerbetrieb, Prüfung alle ${INTERVAL} Sekunden
  --once         genau ein Prüfdurchlauf, danach Ende
  --help         diese Hilfe anzeigen
EOF
}

# Prüft, ob $2 eine positive Ganzzahl ist; $1 ist der Name für die Fehlermeldung.
require_positive_int() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] && return 0
    log ERROR "Ungültiger Wert für $1: '$2' (erwartet: positive Ganzzahl)"
    return 1
}

# ---------------------------------------------------------------------------
# Eingaben prüfen und Hostliste einlesen
# ---------------------------------------------------------------------------

# Gibt 0 zurück, wenn $1 eine gültige IPv4-Adresse ist (4 Oktette, je 0–255).
is_valid_ipv4() {
    local octet
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        # 10# erzwingt Dezimalzahl – sonst würde "08" als (ungültige) Oktalzahl gelesen
        (( 10#$octet <= 255 )) || return 1
    done
}

# Gibt 0 zurück, wenn $1 ein gültiger Hostname ist (Buchstaben, Ziffern, "." und "-").
is_valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

# Liest die Hostliste $1 und gibt pro gültigem Eintrag "hostname ip" aus.
# Leerzeilen und Kommentare (#) werden übersprungen, ungültige Zeilen gemeldet.
# Dateiformat: <hostname> <IPv4-Adresse>   – eine Zeile pro System
read_hosts() {
    local file="$1" line hostname ip rest lineno=0

    if [[ ! -r "$file" ]]; then
        log ERROR "Hostliste nicht lesbar: $file"
        return 1
    fi

    # "|| -n $line": auch die letzte Zeile lesen, wenn sie kein Zeilenende hat
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"    # Windows-Zeilenende (CRLF) entfernen
        line="${line%%#*}"      # Kommentar entfernen
        read -r hostname ip rest <<< "$line"

        [[ -z "$hostname" ]] && continue    # Leer- bzw. reine Kommentarzeile

        if [[ -z "$ip" || -n "$rest" ]] || ! is_valid_hostname "$hostname" || ! is_valid_ipv4 "$ip"; then
            log WARN "$file, Zeile $lineno: ungültiger Eintrag wird übersprungen: '$line'"
            continue
        fi
        printf '%s %s\n' "$hostname" "$ip"
    done < "$file"
}

# ---------------------------------------------------------------------------
# Prüfung eines Systems
# ---------------------------------------------------------------------------

# Liest die Antwortzeit in ms aus der Ausgabe von ping ("... time=12.3 ms").
# Gibt nichts aus, wenn die Ausgabe keine Antwortzeit enthält.
parse_ping_time() {
    local pattern='time[=<]([0-9]+(\.[0-9]+)?) ?ms'
    if [[ "$1" =~ $pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# Pingt die IP-Adresse $1 einmal an.
# Ausgabe: "ONLINE <antwortzeit_ms>" oder "OFFLINE"
check_host() {
    local ip="$1" ping_output rtt
    if ping_output=$(ping -c 1 -W "$PING_TIMEOUT" "$ip" 2>&1); then
        rtt=$(parse_ping_time "$ping_output")
        printf 'OFFLINE %s\n' "$rtt"
    else
        printf 'OFFLINE\n'
    fi
}

# Gibt ein Prüfergebnis als Tabellenzeile auf stdout aus.
print_result() {
    local hostname="$1" ip="$2" checked_at="$3" status="$4" rtt="$5"
    printf '%-20s %-15s %s  %-7s %s\n' "$hostname" "$ip" "$checked_at" "$status" "${rtt:+$rtt ms}"
}

# ---------------------------------------------------------------------------
# Datenbank
# ---------------------------------------------------------------------------

# Wartet, bis die Datenbank erreichbar ist und die Zugangsdaten stimmen.
# Nach DB_RETRIES erfolglosen Versuchen wird mit Fehler abgebrochen.
wait_for_db() {
    local attempt error=""
    for (( attempt = 1; attempt <= DB_RETRIES; attempt++ )); do
        # stderr von psql abfangen, stdout verwerfen
        if error=$(psql --no-psqlrc --quiet --command 'SELECT 1' 2>&1 >/dev/null); then
            return 0
        fi
        log WARN "Datenbank nicht erreichbar (Versuch $attempt/$DB_RETRIES)"
        if (( attempt < DB_RETRIES )); then
            sleep 2
        fi
    done
    log ERROR "Keine Verbindung zur Datenbank: $error"
    return 1
}

# Legt Tabellen und Views an, falls sie noch nicht existieren.
init_schema() {
    psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 --file "$SCHEMA_FILE" >/dev/null
}

# Speichert ein Prüfergebnis in der Datenbank.
# Die Werte werden als psql-Variablen übergeben und im SQL mit :'name' eingesetzt.
# psql setzt sie dabei selbst korrekt in Anführungszeichen – dadurch ist keine
# SQL-Injection über die Hostliste möglich.
save_result() {
    local hostname="$1" ip="$2" checked_at="$3" status="$4" rtt="$5"
    psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 \
         --set hostname="$hostname" --set ip="$ip" --set checked_at="$checked_at" \
         --set status="$status" --set rtt="$rtt" >/dev/null <<'SQL'
-- Host anlegen bzw. IP-Adresse aktualisieren, danach das Prüfergebnis speichern
WITH host AS (
    INSERT INTO hosts (hostname, ip_address)
    VALUES (:'hostname', :'ip')
    ON CONFLICT (hostname) DO UPDATE SET ip_address = EXCLUDED.ip_address
    RETURNING host_id
)
INSERT INTO checks (host_id, checked_at, status, response_time_ms)
SELECT host_id, :'checked_at'::timestamptz, :'status', NULLIF(:'rtt', '')::numeric
FROM host;
SQL
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------

# Ein Prüfdurchlauf: jedes System aus der Hostliste prüfen, Ergebnis ausgeben
# und in der Datenbank speichern.
# Rückgabe 1, wenn die Hostliste fehlt/leer ist oder ein Ergebnis nicht
# gespeichert werden konnte. Ein nicht erreichbarer Host ist dagegen KEIN
# Fehler, sondern ein gültiges Ergebnis ("OFFLINE").
run_checks() {
    local hosts hostname ip checked_at status rtt failed=0

    hosts=$(read_hosts "$HOSTS_FILE") || return 1
    if [[ -z "$hosts" ]]; then
        log ERROR "Keine gültigen Einträge in $HOSTS_FILE"
        return 1
    fi

    # Hostliste über Dateideskriptor 3 lesen, damit Befehle in der Schleife
    # (ping, psql) nicht versehentlich Zeilen von stdin "verbrauchen".
    while read -r hostname ip <&3; do
        checked_at=$(date '+%Y-%m-%d %H:%M:%S%z')
        read -r status rtt <<< "$(check_host "$ip")"
        print_result "$hostname" "$ip" "$checked_at" "$status" "$rtt"
        if ! save_result "$hostname" "$ip" "$checked_at" "$status" "$rtt"; then
            log ERROR "Ergebnis für $hostname konnte nicht gespeichert werden"
            failed=1
        fi
    done 3<<< "$hosts"

    return "$failed"
}

main() {
    local once=false start elapsed

    case "${1:-}" in
        "")        ;;
        --once)    once=true ;;
        -h|--help) usage; return 0 ;;
        *)         usage >&2; return 2 ;;
    esac

    require_positive_int NETWATCH_INTERVAL "$INTERVAL" &&
        require_positive_int NETWATCH_PING_TIMEOUT "$PING_TIMEOUT" &&
        require_positive_int NETWATCH_DB_RETRIES "$DB_RETRIES" || return 2

    log INFO "NetWatch $VERSION startet (Hostliste: $HOSTS_FILE, Intervall: ${INTERVAL}s)"
    wait_for_db || return 1
    if ! init_schema; then
        log ERROR "Datenbankschema konnte nicht angelegt werden ($SCHEMA_FILE)"
        return 1
    fi

    if $once; then
        run_checks
        return
    fi

    # docker stop sendet SIGTERM → sauber beenden
    trap 'log INFO "NetWatch wird beendet"; exit 0' TERM INT

    while true; do
        start=$SECONDS
        run_checks || log WARN "Prüfdurchlauf mit Fehlern beendet"
        elapsed=$(( SECONDS - start ))
        # Nur die Restzeit bis zum nächsten Intervall warten, damit der Takt
        # auch bei langsamen Pings bei ca. 1 Minute bleibt. "sleep & wait",
        # damit SIGTERM sofort wirkt und nicht erst nach Ablauf von sleep.
        if (( elapsed < INTERVAL )); then
            sleep $(( INTERVAL - elapsed )) &
            wait $!
        fi
    done
}

# main nur ausführen, wenn das Skript direkt gestartet wird. Wird es per
# "source" eingebunden (Unit-Tests mit bats), stehen nur die Funktionen bereit.
# Bewusst ohne "set -e": ein fehlgeschlagener Ping ist ein normales Ergebnis
# und wird oben explizit ausgewertet.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
