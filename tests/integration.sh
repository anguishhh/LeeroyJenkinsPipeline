#!/usr/bin/env bash
#
# Integrationstest für NetWatch
#
# Startet Datenbank und NetWatch in einem eigenen, temporären Compose-Projekt,
# führt einen Prüfdurchlauf mit config/hosts.test.conf aus und prüft danach
# DIREKT IN DER DATENBANK, ob die Ergebnisse korrekt gespeichert wurden.
# Zum Schluss wird alles wieder entfernt (inkl. Test-Volume).
#
# Aufruf:  NETWATCH_TAG=<image-tag> bash tests/integration.sh
#          (das Image netwatch:<image-tag> muss bereits gebaut sein)
#
# Exit-Code 0 = alle Tests bestanden, 1 = mindestens ein Test fehlgeschlagen

set -euo pipefail
cd "$(dirname "$0")/.."

# Eigenes Compose-Projekt → eigene Container, eigenes Netz, eigenes Volume.
# Die produktive Installation (Projekt "netwatch") wird nicht berührt.
PROJECT="${COMPOSE_PROJECT_NAME:-netwatch-test}"
if [[ "$PROJECT" == "netwatch" ]]; then
    echo "Abbruch: Der Test darf nicht im Produktiv-Projekt 'netwatch' laufen (löscht am Ende das Volume)." >&2
    exit 1
fi
export NETWATCH_TAG="${NETWATCH_TAG:-latest}"
export NETWATCH_HOSTS_FILE=/app/config/hosts.test.conf
export POSTGRES_DB=netwatch_test
export POSTGRES_USER=netwatch_test
# Zufälliges Einmal-Passwort – steht nirgends im Code und wird nicht gespeichert
POSTGRES_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export POSTGRES_PASSWORD

failures=0

# docker compose immer mit ausdrücklich gesetztem Test-Projektnamen aufrufen
compose() {
    docker compose -p "$PROJECT" "$@"
}

# Aufräumen – auch wenn das Skript vorzeitig abbricht
cleanup() {
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# SQL-Abfrage direkt in der Datenbank ausführen, nur den Wert ausgeben
sql() {
    compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "$1"
}

# Vergleicht Soll- und Ist-Wert und gibt das Ergebnis aus
# Aufruf: check ID BESCHREIBUNG IST SOLL
check() {
    local id="$1" description="$2" actual="$3" expected="$4" result="PASS"
    if [[ "$actual" != "$expected" ]]; then
        result="FAIL"
        failures=$(( failures + 1 ))
    fi
    printf '%-4s %-4s %-52s soll: %-8s ist: %s\n' "$result" "$id" "$description" "$expected" "$actual"
}

# Führt einen Prüfdurchlauf aus und gibt "ok" oder "fehler" zurück
run_once() {
    if compose run --rm "$@" netwatch --once >&2; then echo ok; else echo fehler; fi
}

echo "== Test-Datenbank starten (Projekt $PROJECT, Image netwatch:$NETWATCH_TAG) =="
compose up -d --wait db

echo "== Prüfdurchlauf mit config/hosts.test.conf =="
result=$(run_once)
echo
echo "== Ergebnisse =="
check I1 "Prüfdurchlauf endet ohne Fehler" "$result" "ok"
check I2 "127.0.0.1 wird als ONLINE gespeichert" \
    "$(sql "SELECT status FROM v_latest_status WHERE hostname = 'test-localhost'")" "ONLINE"
check I3 "ONLINE-Ergebnis enthält eine Antwortzeit" \
    "$(sql "SELECT response_time_ms IS NOT NULL FROM v_latest_status WHERE hostname = 'test-localhost'")" "t"
check I4 "192.0.2.1 (TEST-NET) wird als OFFLINE gespeichert" \
    "$(sql "SELECT status FROM v_latest_status WHERE hostname = 'test-unreachable'")" "OFFLINE"
check I5 "OFFLINE-Ergebnis hat keine Antwortzeit" \
    "$(sql "SELECT response_time_ms IS NULL FROM v_latest_status WHERE hostname = 'test-unreachable'")" "t"
check I6 "Ungültiger Eintrag wird nicht gespeichert" \
    "$(sql "SELECT count(*) FROM hosts WHERE hostname = 'test-invalid'")" "0"
check I7 "Genau 2 Prüfergebnisse gespeichert" \
    "$(sql "SELECT count(*) FROM checks")" "2"

echo
echo "== Negativtests: falsches Passwort, Datenbank gestoppt =="
check I8 "Falsches DB-Passwort wird als Fehler erkannt" \
    "$(run_once -e PGPASSWORD=falsches-passwort -e NETWATCH_DB_RETRIES=1)" "fehler"
compose stop db >/dev/null
check I9 "Ausgefallene Datenbank wird als Fehler erkannt" \
    "$(run_once --no-deps -e NETWATCH_DB_RETRIES=1)" "fehler"

echo
echo "== Persistenz: docker compose down (ohne -v) und neu starten =="
compose down >/dev/null
compose up -d --wait db >/dev/null
check I10 "Daten nach down/up weiterhin vorhanden" \
    "$(sql "SELECT count(*) FROM checks")" "2"

echo
if (( failures > 0 )); then
    echo "Integrationstest FEHLGESCHLAGEN: $failures Test(s) nicht bestanden"
    exit 1
fi
echo "Integrationstest erfolgreich: alle Tests bestanden"
