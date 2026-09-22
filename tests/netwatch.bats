#!/usr/bin/env bats
#
# Unit-Tests für bin/netwatch.sh (Framework: bats-core)
#
# Getestet werden die einzelnen Funktionen – ohne Netzwerk und ohne Datenbank.
# "ping" wird dazu bei Bedarf durch eine Test-Funktion ersetzt (Mock).
#
# Ausführen auf der VM:   docker run --rm -v "$PWD:/code:ro" bats/bats:latest /code/tests

setup() {
    # Lädt nur die Funktionen – main wird beim Einbinden per "source" nicht ausgeführt
    source "$BATS_TEST_DIRNAME/../bin/netwatch.sh"
    HOSTS="$BATS_TEST_TMPDIR/hosts.conf"
}

# --- is_valid_ipv4 ---------------------------------------------------------

@test "is_valid_ipv4 akzeptiert gültige Adressen" {
    is_valid_ipv4 127.0.0.1
    is_valid_ipv4 192.168.10.25
    is_valid_ipv4 0.0.0.0
    is_valid_ipv4 255.255.255.255
}

@test "is_valid_ipv4 lehnt ungültige Adressen ab" {
    for ip in 256.1.1.1 1.2.3 1.2.3.4.5 1.2.3.-4 abc "" "1.2.3.4 "; do
        run is_valid_ipv4 "$ip"
        [ "$status" -ne 0 ] || { echo "fälschlich akzeptiert: '$ip'"; return 1; }
    done
}

# --- is_valid_hostname -----------------------------------------------------

@test "is_valid_hostname akzeptiert übliche Hostnamen" {
    is_valid_hostname fileserver01
    is_valid_hostname web-01.example.org
    is_valid_hostname a
}

@test "is_valid_hostname lehnt ungültige Hostnamen ab" {
    for name in "-start" "ende-" "mit leerzeichen" "semi;kolon" "quote'" ""; do
        run is_valid_hostname "$name"
        [ "$status" -ne 0 ] || { echo "fälschlich akzeptiert: '$name'"; return 1; }
    done
}

# --- parse_ping_time -------------------------------------------------------

@test "parse_ping_time liest Antwortzeit mit Nachkommastellen" {
    result=$(parse_ping_time "64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.045 ms")
    [ "$result" = "0.045" ]
}

@test "parse_ping_time liest ganzzahlige Antwortzeit" {
    result=$(parse_ping_time "64 bytes from 192.168.10.25: icmp_seq=1 ttl=63 time=12 ms")
    [ "$result" = "12" ]
}

@test "parse_ping_time gibt nichts aus, wenn keine Antwortzeit enthalten ist" {
    result=$(parse_ping_time "1 packets transmitted, 0 received, 100% packet loss")
    [ -z "$result" ]
}

# --- check_host (ping wird simuliert) --------------------------------------

@test "check_host meldet ONLINE mit Antwortzeit, wenn ping erfolgreich ist" {
    ping() { echo "64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=12.3 ms"; return 0; }
    result=$(check_host 10.0.0.1)
    [ "$result" = "ONLINE 12.3" ]
}

@test "check_host meldet OFFLINE, wenn ping fehlschlägt" {
    ping() { echo "1 packets transmitted, 0 received, 100% packet loss"; return 1; }
    result=$(check_host 192.0.2.1)
    [ "$result" = "OFFLINE" ]
}

# --- read_hosts ------------------------------------------------------------

@test "read_hosts liest gültige Einträge und ignoriert Kommentare und Leerzeilen" {
    cat > "$HOSTS" <<'EOF'
# Kommentarzeile
fileserver01   192.168.10.25

router         10.0.0.1      # Kommentar am Zeilenende
EOF
    result=$(read_hosts "$HOSTS" 2>/dev/null)
    [ "$result" = $'fileserver01 192.168.10.25\nrouter 10.0.0.1' ]
}

@test "read_hosts überspringt ungültige Einträge" {
    cat > "$HOSTS" <<'EOF'
gut            10.0.0.1
kaputt         999.1.1.1
nur-hostname
zu viele       10.0.0.2
EOF
    result=$(read_hosts "$HOSTS" 2>/dev/null)
    [ "$result" = "gut 10.0.0.1" ]
}

@test "read_hosts verarbeitet Windows-Zeilenenden und fehlendes letztes Zeilenende" {
    printf 'win1 10.0.0.1\r\nwin2 10.0.0.2' > "$HOSTS"
    result=$(read_hosts "$HOSTS" 2>/dev/null)
    [ "$result" = $'win1 10.0.0.1\nwin2 10.0.0.2' ]
}

@test "read_hosts meldet Fehler, wenn die Datei fehlt" {
    run read_hosts "$BATS_TEST_TMPDIR/gibt-es-nicht.conf"
    [ "$status" -eq 1 ]
}

# --- require_positive_int --------------------------------------------------

@test "require_positive_int prüft Konfigurationswerte" {
    require_positive_int TEST 60
    run require_positive_int TEST 0
    [ "$status" -eq 1 ]
    run require_positive_int TEST abc
    [ "$status" -eq 1 ]
}
