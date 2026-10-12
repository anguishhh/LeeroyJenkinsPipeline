# Vorführung – Befehlsliste

Kurzliste für die Vorstellung des Projekts. Befehle für die **VM** laufen in der SSH-Sitzung,
Befehle für **Windows** in PowerShell im Projektordner.

## Vorbereitung

- VM starten, etwa eine Minute warten, dann `docker ps`: beide Container „Up“
- PowerShell 1: `ssh a@192.168.56.10` · PowerShell 2: im Projektordner
- Browser: Jenkins unter `http://192.168.56.10:8080/job/netwatch/` angemeldet
- Projektdokumentation offen (Architektur in Abschnitt 3, Netzdiagramm in 2.4)

**Nicht vorführen:** `docker exec … env` und `docker inspect` ohne `--format` – beide zeigen
das Datenbank-Passwort im Klartext.

## 1. VM, Netzwerk, Absicherung (VM)

```bash
hostnamectl                          # Debian 13, Hostname netwatch-vm, Virtualisierung: oracle
ip -br addr                          # enp0s3 10.0.2.15 (NAT), enp0s8 192.168.56.10 (Host-only)
ip route                             # Standard-Gateway nur über NAT (10.0.2.2)
sudo ufw status verbose              # eingehend alles verboten, 22 und 8080 nur aus 192.168.56.0/24
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin)'   # beide "no"
sudo passwd -S root                  # "L" = Root-Anmeldung gesperrt
systemctl is-active ssh docker jenkins   # dreimal "active"
groups jenkins                       # jenkins ist in der Gruppe docker
```

## 2. Git und GitHub (Windows)

```powershell
git log --oneline -15                # thematische Commits, Testfälle P1–P3 und die Reverts
git remote -v                        # öffentliches GitHub-Repository
git check-ignore -v .env             # .env ist durch .gitignore ausgeschlossen
git grep -n -i password              # nur Variablennamen und Platzhalter, kein echtes Passwort
```

## 3. NetWatch und Docker (VM)

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'   # netwatch:<Build> und postgres:17
docker images netwatch               # ein Image je erfolgreichem Build, dazu "latest"
docker exec netwatch-netwatch-1 netwatch.sh --once            # sofort ein Prüfdurchlauf: ONLINE/OFFLINE
docker logs --tail 10 netwatch-netwatch-1                     # laufender Betrieb, eine Zeile je Prüfung
docker logs netwatch-netwatch-1 2>&1 | grep startet | tail -1 # Version = Commit-Hash
docker exec netwatch-netwatch-1 netwatch-report.sh 10         # Status je System, letzte Prüfungen
docker exec netwatch-netwatch-1 id   # läuft als Benutzer netwatch, nicht als root
docker port netwatch-db-1            # keine Ausgabe = Datenbank veröffentlicht keinen Port
```

## 4. Datenbank (VM)

```bash
docker inspect netwatch-db-1 --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'
                                     # Daten liegen im Volume netwatch_pgdata
docker exec -it netwatch-db-1 psql -U netwatch -d netwatch
```

In `psql`:

```sql
\dt                                  -- Tabellen hosts und checks
\d checks                            -- Datentypen, Fremdschlüssel, CHECK-Regeln
SELECT * FROM v_latest_status;       -- letzter Status je System
SELECT count(*) FROM checks;         -- Anzahl gespeicherter Prüfungen
\q
```

Den Nachweis, dass die Daten das Löschen der Container überstehen, liefert der Integrationstest
in jedem Build (I10, `docker compose down` und Neustart).

## 5. Jenkins und Pipeline (Browser)

- Job `netwatch`: Stage-Ansicht mit Checkout → Lint → Unit-Tests → Image bauen → Integrationstest → Deploy
- Build #3: „Build wurde durch eine SCM-Änderung ausgelöst“ (automatischer Start)
- Build #4 und #5: rot, kein Deploy · Build #6: wieder grün
- „Testergebnis“ eines Builds: 14 Unit-Tests · „Console Output“: Zeilen `PASS I1` bis `PASS I10`
- *Jenkins verwalten → Credentials*: `netwatch-db`, Passwort nur als `******`
- `Jenkinsfile` im Editor zeigen

## 6. Live-Durchlauf (Windows, optional)

Jeder Push braucht bis zu 2 Minuten Polling plus etwa 40 Sekunden Pipeline.

```powershell
# Positiv: neuer Commit löst Build aus, alle Stages grün, neue Version läuft
git commit --allow-empty -m "Vorführung: Pipeline über Polling auslösen"
git push

# Negativ: Fehler aus Testfall P3 erneut einspielen -> rot in Lint, kein Deploy
git cherry-pick 2689e81
git push

# Fehler zurücknehmen -> Pipeline wieder grün
git revert --no-edit HEAD
git push
```

Nach dem roten Build auf der VM `docker ps` zeigen: Die vorherige Version läuft unverändert weiter.
