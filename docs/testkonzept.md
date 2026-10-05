# Testkonzept NetWatch

Ziel: Nachweisen, dass NetWatch Systeme korrekt als ONLINE/OFFLINE erkennt, die Ergebnisse
dauerhaft speichert und dass die Pipeline fehlerhafte Versionen zuverlässig stoppt.

**Testebenen**

| Ebene | Werkzeug | Wann | Automatisch |
|-------|----------|------|-------------|
| Statische Analyse | ShellCheck | jeder Pipeline-Lauf (Stage *Lint*) | ja |
| Unit-Tests (U) | bats, `tests/netwatch.bats` | jeder Pipeline-Lauf (Stage *Unit-Tests*) | ja |
| Integrationstests (I) | `tests/integration.sh` mit echter Test-DB | jeder Pipeline-Lauf (Stage *Integrationstest*) | ja |
| Pipeline-Tests (P) | Commit/Push, Jenkins-Oberfläche | einmalig, manuell | nein |
| Betriebstests (B) | Docker/VM-Befehle | einmalig, manuell | nein |

Für jeden durchgeführten Test das **Ist-Ergebnis** eintragen und als Nachweis einen
Screenshot (Jenkins-Konsole, `psql`-Ausgabe, …) im CMS ablegen.

## Automatisierte Tests

Nachweis: Konsolenausgabe von **Build #1 vom 05.10.2026** (Stages *Unit-Tests* und
*Integrationstest*). Diese Tests laufen bei jedem Pipeline-Durchlauf erneut.

| Nr. | Testfall | Art | Soll-Ergebnis | Ist-Ergebnis | OK? |
|-----|----------|-----|---------------|--------------|-----|
| U1 | Gültige IP-Adressen (127.0.0.1, 255.255.255.255 …) | positiv | werden akzeptiert | `ok 1` | ✓ |
| U2 | Ungültige IP-Adressen (256.1.1.1, 1.2.3, abc …) | negativ | werden abgelehnt | `ok 2` | ✓ |
| U3 | Antwortzeit aus ping-Ausgabe lesen | positiv | `time=0.045 ms` → `0.045` | `ok 5–7` | ✓ |
| U4 | ping erfolgreich (simuliert) | positiv | `ONLINE 12.3` | `ok 8` | ✓ |
| U5 | ping fehlgeschlagen (simuliert) | negativ | `OFFLINE` | `ok 9` | ✓ |
| U6 | Hostliste mit Kommentaren, Leerzeilen, CRLF | positiv | nur gültige Einträge werden gelesen | `ok 10, 12` | ✓ |
| U7 | Hostliste mit ungültigen Einträgen / fehlende Datei | negativ | Einträge übersprungen / Fehler | `ok 11, 13` | ✓ |
| I1 | Prüfdurchlauf `--once` mit Test-Hostliste | positiv | Exit-Code 0 | `PASS I1` | ✓ |
| I2 | 127.0.0.1 prüfen, Ergebnis in DB | positiv | Status `ONLINE`, Antwortzeit vorhanden | `ONLINE`, 0.034 ms (`PASS I2`, `PASS I3`) | ✓ |
| I4 | 192.0.2.1 (TEST-NET, nicht erreichbar) prüfen | negativ | Status `OFFLINE`, Antwortzeit `NULL` | `OFFLINE`, NULL (`PASS I4`, `PASS I5`) | ✓ |
| I6 | Ungültiger Eintrag 999.1.1.1 | negativ | nicht in der DB | 0 Treffer, nur 2 Prüfungen gespeichert (`PASS I6`, `PASS I7`) | ✓ |
| I8 | Falsches Datenbank-Passwort | negativ | Fehlermeldung, Exit-Code ≠ 0 | `password authentication failed for user "netwatch_test"` (`PASS I8`) | ✓ |
| I9 | Datenbank gestoppt | negativ | Fehlermeldung, Exit-Code ≠ 0 | `could not translate host name "db"` (`PASS I9`) | ✓ |
| I10 | `docker compose down` (ohne `-v`) und neu starten | positiv | Daten weiterhin vorhanden | 2 von 2 Datensätzen (`PASS I10`) | ✓ |

## Pipeline-Tests (manuell)

Durchgeführt am 05.10.2026. Build-Nummern beziehen sich auf den Jenkins-Job `netwatch`.

| Nr. | Testfall | Durchführung | Soll-Ergebnis | Ist-Ergebnis | OK? |
|-----|----------|--------------|---------------|--------------|-----|
| P1 | Neue Version wird erkannt | `netwatch-vm 192.168.56.10` in `config/hosts.conf` ergänzt, Commit `2e1c752`, Push um 12:19 | Jenkins startet innerhalb von ≈ 2 min, alle Stages grün, neues Image `netwatch:<Build>`; neuer Commit-Hash in `docker logs netwatch-netwatch-1` | Build #3 um 12:22, „Build wurde durch eine SCM-Änderung ausgelöst“, 37 s, alle Stages grün; `docker ps` zeigt `netwatch:3`, neuer Host wird mit 0.040 ms als ONLINE überwacht | ✓ |
| P2 | Fehlerhafter Code wird gestoppt | In `check_host` `ONLINE` und `OFFLINE` vertauscht, Commit `45032d6` | Stage *Unit-Tests* rot, Pipeline bricht ab, **kein Deploy**, alte Version läuft weiter (`docker ps`) | Build #4 um 12:36 nach 8,6 s rot; Testergebnis: „check_host meldet ONLINE mit Antwortzeit, wenn ping erfolgreich ist“ fehlgeschlagen; kein Image `netwatch:4`, `netwatch:3` lief ununterbrochen weiter | ✓ |
| P3 | Syntax-/Stilfehler wird gestoppt | `echo $max_rows` ohne Anführungszeichen in `netwatch-report.sh`, Commit `2689e81` | Stage *Lint* rot, kein Deploy | Build #5 um 12:40 rot in der Stage *Lint* nach 1 Sekunde: `SC2086 (info): Double quote to prevent globbing and word splitting`, `script returned exit code 1`. Die Stages *Unit-Tests*, *Image bauen*, *Integrationstest* und *Deploy* wurden übersprungen, es entstand kein Image | ✓ |
| P4 | Fehler zurücknehmen | `git revert` beider Commits (`ebc3b8e`, `5e4f37b`), Push | Pipeline wieder grün, Deploy erfolgt | Build #6 um 12:44, 37 s, alle Stages grün, Deploy von `netwatch:6` | ✓ |

## Betriebstests (manuell)

| Nr. | Testfall | Durchführung | Soll-Ergebnis | Ist-Ergebnis | OK? |
|-----|----------|--------------|---------------|--------------|-----|
| B1 | Regelmäßige Prüfung | 5 min laufen lassen, Abfrage B-SQL1 | ≈ 1 Eintrag pro Host und Minute | genau 5 Prüfungen je Host im Zeitraum 12:48:46–12:52:46, für alle 5 Hosts | ✓ |
| B2 | Neustart des Anwendungscontainers | `docker restart netwatch-netwatch-1` | Container läuft wieder, Messung geht weiter, alte Daten vorhanden | Container sofort wieder „Up“, nächste Messung um 12:54:49, danach 12:55:49 und 12:56:49; Report zeigt weiterhin alle Hosts samt Verlauf | ✓ |
| B3 | Ausfall der Datenbank im Betrieb | `docker stop netwatch-db-1`, 2 min warten, `docker start netwatch-db-1` | NetWatch meldet Fehler im Log, stürzt nicht ab, schreibt danach weiter | Pro Host `psql: error: could not translate host name "db"` und `[ERROR] Ergebnis für … konnte nicht gespeichert werden`, danach `[WARN] Prüfdurchlauf mit Fehlern beendet`. Ping-Prüfung lief weiter, Container blieb „Up 5 minutes“. Nach Start der Datenbank ab 13:00:49 wieder gespeicherte Ergebnisse; die Messungen während des Ausfalls fehlen (erwartet) | ✓ |
| B4 | Neustart der kompletten VM | `sudo reboot` | Jenkins, Docker und beide Container starten automatisch, Daten vorhanden | Vor dem Neustart 462 Prüfungen, danach 477; `systemctl is-active docker jenkins` → zweimal `active`; beide Container ohne Eingriff wieder „Up“ | ✓ |
| B5 | Keine Passwörter im Repository | `git grep -i password`, Jenkinsfile prüfen | nur Variablennamen/Platzhalter, keine echten Werte | Treffer nur bei Variablennamen (`POSTGRES_PASSWORD`, `PGPASSWORD`), dem Platzhalter `bitte-aendern` in `.env.example` und dem Einmal-Passwort des Integrationstests; `.env` ist nicht versioniert und existiert auf der VM gar nicht | ✓ |

## Nützliche SQL-Abfragen

Direkt in der Datenbank (Produktivsystem):

```bash
docker exec -it netwatch-db-1 psql -U netwatch -d netwatch
```

```sql
-- Letzter Status je System
SELECT * FROM v_latest_status;

-- B-SQL1: Anzahl Prüfungen pro Host in den letzten 5 Minuten
SELECT h.hostname, count(*)
FROM checks c JOIN hosts h USING (host_id)
WHERE c.checked_at > now() - interval '5 minutes'
GROUP BY h.hostname;

-- Letzte 10 Prüfungen
SELECT h.hostname, h.ip_address, c.checked_at, c.status, c.response_time_ms
FROM checks c JOIN hosts h USING (host_id)
ORDER BY c.checked_at DESC LIMIT 10;
```
