# NetWatch – CI/CD-Umgebung mit GitHub, Jenkins und Docker

Projektdokumentation · NetDorm Solutions GmbH (fiktiv) · Stand 05.10.2026
Repository: <https://github.com/anguishhh/LeeroyJenkinsPipeline>

> Hinweis zur Übernahme ins CMS: Die mit **[Screenshot: …]** markierten Stellen zeigen, welcher
> Bildschirmfoto-Nachweis dort eingefügt wird. Mit **[TODO: …]** markierte Angaben noch ergänzen.

---

## 1. Ausgangslage und Ziel

Die Entwicklungsabteilung verwaltet ihren Quellcode bereits mit GitHub, testet neue Versionen
aber von Hand und lässt sie anschließend von einem Administrator auf einem Linux-Server
bereitstellen. Daraus entstehen immer wieder dieselben Probleme: Tests werden vergessen,
auf verschiedenen Systemen laufen unterschiedliche Softwarestände, und fehlerhafte Versionen
gelangen auf Testsysteme.

Ziel des Projekts ist ein lauffähiger Prototyp, der diesen Ablauf automatisiert. Als
Demonstrationsanwendung dient **NetWatch**, ein Monitoring-Programm in Bash, das Server und
Netzwerkgeräte im Minutentakt per Ping prüft und die Ergebnisse dauerhaft in einer Datenbank
speichert. Nach jedem Commit auf GitHub soll NetWatch automatisch getestet und – nur bei
fehlerfreiem Durchlauf – als Docker-Container bereitgestellt werden.

Der Prototyp ist vollständig umgesetzt und im Betrieb. Alle in Abschnitt 9 aufgeführten
Testfälle wurden durchgeführt und bestanden.

---

## 2. Planung der Gesamtumgebung

### 2.1 Vorgehen

Die Umgebung wurde in fünf aufeinander aufbauenden Schritten geplant und umgesetzt. Jeder
Schritt war für sich prüfbar, bevor der nächste begann:

| Schritt | Inhalt | Prüfkriterium |
|---------|--------|---------------|
| 1 | Linux-VM mit Netzwerk, Benutzern und Absicherung | VM per SSH erreichbar, Internetzugang vorhanden |
| 2 | Git-Repository mit Projektstruktur | Repository geklont, Struktur steht |
| 3 | NetWatch-Skript und Datenbankschema | Prüflauf speichert Ergebnisse |
| 4 | Dockerfile und Docker Compose | Anwendung und Datenbank laufen als getrennte Container |
| 5 | Jenkins mit Pipeline und Trigger | Commit löst Test und Bereitstellung aus |

### 2.2 Anforderungen und gewählte Lösungen

| Anforderung aus dem Auftrag | Umsetzung im Projekt |
|---|---|
| Linux läuft als virtuelle Maschine | Debian 13 „trixie“ in Oracle VirtualBox |
| Quellcode mit Git und GitHub verwaltet | öffentliches Repository `anguishhh/LeeroyJenkinsPipeline` |
| Jenkins verwendet eine Pipeline aus einem Jenkinsfile | `Jenkinsfile` im Repository, Job-Typ „Pipeline script from SCM“ |
| Anwendung läuft als Docker-Container | Image `netwatch:<Buildnummer>` aus eigenem Dockerfile |
| Datenbank als separater Container | offizielles Image `postgres:17` |
| Ergebnisse werden tatsächlich gespeichert | Tabellen `hosts` und `checks`, Nachweis per SQL-Abfrage |
| Pipeline bezieht den Quellcode aus GitHub | `checkout scm` in der Stage *Checkout* |
| Automatisierter Test in der Pipeline | ShellCheck, 14 Unit-Tests, 10 Integrationstests |
| Deployment nur nach erfolgreichem Test | Stage *Deploy* wird nur bei grünen Vorstufen erreicht |
| Keine Zugangsdaten im Quellcode oder Jenkinsfile | Jenkins-Credential, Umgebungsvariablen, `.gitignore` |

### 2.3 Begründete Entscheidungen

**Jenkins direkt auf der VM statt als Container.** Die Pipeline startet selbst Container
(`docker build`, `docker compose`). Läuft Jenkins direkt auf dem System, nutzt es dafür
einfach den vorhandenen Docker-Dienst. Als Container bräuchte Jenkins zusätzlich die
Docker-CLI im Image und entweder den eingebundenen Docker-Socket oder „Docker in Docker“ in
einem privilegierten Container. Außerdem stimmen so die Pfade: Die Pipeline bindet ihr
Arbeitsverzeichnis in Testcontainer ein (`-v "$WORKSPACE:/code"`), was bei einem
containerisierten Jenkins zu Pfadkonflikten zwischen Host und Container führt. Jenkins läuft
als systemd-Dienst und startet nach einem Neustart der VM automatisch mit.
Nachteil: Java und Jenkins liegen direkt auf dem System, Updates sind aufwändiger als ein
Image-Austausch. Die nötige Mitgliedschaft des Benutzers `jenkins` in der Gruppe `docker`
entspricht faktisch Root-Rechten – das gilt beim eingebundenen Docker-Socket allerdings
genauso und ist daher kein Argument für die Container-Variante.

**Polling statt Webhook.**

| | Polling (gewählt) | Webhook |
|---|---|---|
| Prinzip | Jenkins fragt regelmäßig bei GitHub nach neuen Commits | GitHub schickt bei jedem Push eine Anfrage an Jenkins |
| Verzögerung | bis zum nächsten Intervall, hier höchstens 2 Minuten | wenige Sekunden |
| Last | Anfragen auch dann, wenn sich nichts geändert hat | nur bei tatsächlichen Änderungen |
| Netzwerk | nur ausgehende Verbindungen nötig | Jenkins muss aus dem Internet erreichbar sein |
| Sicherheit | kein offener Port nach außen | öffentlicher Endpunkt, Absicherung per Secret und HTTPS nötig |

Die VM steht hinter dem NAT von VirtualBox in einem Schulnetz und besitzt keine öffentliche
Adresse. Ein Webhook von GitHub könnte sie nicht erreichen. Gewählt wurde deshalb Polling mit
`pollSCM('H/2 * * * *')`. In einer Umgebung mit erreichbarem Server wäre der Webhook
vorzuziehen, weil er schneller reagiert und keine Leerlauf-Abfragen erzeugt. Als Mittelweg
ließe sich ein Weiterleitungsdienst wie smee.io einsetzen, der nur eine ausgehende Verbindung
benötigt.

**PostgreSQL als Datenbank.** Die Datentypen `inet` für IP-Adressen und `timestamptz` für
Zeitstempel mit Zeitzone passen unmittelbar zu den Monitoring-Daten, und `inet` prüft die
Gültigkeit einer Adresse bereits auf Datenbankebene. Entscheidend war außerdem, dass das
Kommandozeilenwerkzeug `psql` Werte als Variablen übergeben bekommen kann (`:'name'`) und
selbst korrekt maskiert. Ein Bash-Skript hat keine Datenbankbibliothek mit vorbereiteten
Anweisungen; über diesen Weg ist der Zugriff trotzdem gegen SQL-Injection abgesichert.

**Trennung von Anwendung und Datenbank in zwei Container.** Jeder Container hat eine Aufgabe.
Die Datenbank kann unabhängig von der Anwendung neu gestartet oder aktualisiert werden, und
die Anwendung lässt sich bei jedem Commit austauschen, ohne die Daten zu berühren.

---

## 3. Architektur

```
Entwickler ──git push──▶ GitHub-Repository
                              ▲
                              │ Polling alle 2 Minuten, danach git clone
┌─────────────────────────────┼──────────────────────────────────────────┐
│ Debian-13-VM (VirtualBox)   │                                          │
│                      ┌──────┴───────┐                                  │
│                      │   Jenkins    │  systemd-Dienst, Port 8080       │
│                      └──────┬───────┘                                  │
│                             │ Pipeline aus dem Jenkinsfile             │
│        Lint → Unit-Tests → Image bauen → Integrationstest → Deploy     │
│                             │                                          │
│                             ▼ docker compose                           │
│   ┌────────────────────┐        ┌──────────────────────┐               │
│   │ Container netwatch │──SQL──▶│ Container db         │               │
│   │ Bash · ping · psql │        │ PostgreSQL 17        │               │
│   └─────────┬──────────┘        └──────────┬───────────┘               │
│             │                              │                           │
│             │ ICMP                   Volume netwatch_pgdata            │
└─────────────┼──────────────────────────────────────────────────────────┘
              ▼
   überwachte Systeme (127.0.0.1, 1.1.1.1, 10.0.2.2, 192.168.56.10, 192.168.10.25)
```

Die beiden Container liegen in einem eigenen Docker-Netz (`netwatch_backend`). Die Datenbank
veröffentlicht bewusst keinen Port auf der VM: Sie ist ausschließlich für den
NetWatch-Container erreichbar. Zugriffe zur Kontrolle erfolgen über `docker exec`.

### Komponenten im Überblick

| Komponente | Version | Aufgabe |
|---|---|---|
| Oracle VirtualBox | Hypervisor | stellt die virtuelle Maschine bereit |
| Debian GNU/Linux 13 „trixie“ | Kernel 6.12.111 | Betriebssystem der VM |
| Docker CE | 29.8.2 | Container-Laufzeit |
| Docker Compose Plugin | 5.6.0 | startet Anwendung und Datenbank gemeinsam |
| Jenkins LTS | 2.580.1 (OpenJDK 21) | Automatisierungsserver, führt die Pipeline aus |
| Git / GitHub | 2.47.3 auf der VM | Versionsverwaltung, Quelle der Pipeline |
| PostgreSQL | 17 (Image `postgres:17`) | speichert die Monitoring-Ergebnisse |
| NetWatch | eigenes Image auf `debian:trixie-slim` | die Monitoring-Anwendung selbst |

---

## 4. Zusammenspiel der Komponenten

Der folgende Ablauf beschreibt, was nach einer Codeänderung passiert. Er wurde als Testfall P1
nachgewiesen.

1. **Commit und Push.** Die Entwicklerin ändert den Quellcode und überträgt den Commit nach
   GitHub. Beispiel aus dem Test: Commit `2e1c752`, gepusht um 12:19 Uhr.
2. **Erkennung.** Jenkins fragt alle zwei Minuten bei GitHub nach neuen Commits. Um 12:22 Uhr
   stellt es die Änderung fest und startet Build #3. Auf der Build-Seite steht als Auslöser
   „Build wurde durch eine SCM-Änderung ausgelöst“ – der Build wurde also nicht von Hand
   gestartet.
3. **Checkout.** Die Pipeline holt den Stand aus GitHub in ihr Arbeitsverzeichnis und gibt den
   Commit samt Autor im Protokoll aus.
4. **Statische Analyse.** ShellCheck prüft alle Bash-Skripte auf Fehler und riskante
   Konstruktionen. Findet es etwas, bricht die Pipeline hier ab.
5. **Unit-Tests.** 14 Tests mit dem Framework bats prüfen die einzelnen Funktionen des
   Skripts, ohne Netzwerk und ohne Datenbank. Das Ergebnis wird als JUnit-Bericht an Jenkins
   übergeben und erscheint dort als Testverlauf.
6. **Image bauen.** Erst jetzt entsteht aus dem Dockerfile das Image `netwatch:<Buildnummer>`.
   Der kurze Commit-Hash wird als Version in das Image geschrieben und beim Start protokolliert.
7. **Integrationstest.** In einem eigenen, temporären Compose-Projekt startet eine
   Test-Datenbank. NetWatch führt dort einen einzelnen Prüfdurchlauf aus, anschließend liest
   der Test die Ergebnisse direkt aus der Datenbank. Die Produktivumgebung bleibt unberührt.
8. **Deploy.** Die Stage *Deploy* holt Benutzername und Passwort der Produktivdatenbank aus dem
   Jenkins-Credential und startet die neue Version mit `docker compose up -d --wait`. Compose
   ersetzt nur den NetWatch-Container; die Datenbank und ihr Volume bleiben bestehen.
9. **Betrieb.** Der neue Container prüft ab sofort im Minutentakt alle Systeme aus der
   Hostliste und schreibt die Ergebnisse in die Datenbank.

Schlägt eine Stage fehl, bricht Jenkins sofort ab. Die Stage *Deploy* wird dann nie erreicht,
und die zuvor erfolgreich getestete Version läuft unverändert weiter. Das fehlerhafte Image
wird in der Nachbearbeitung wieder entfernt.

> **[Screenshot: Build #3 – Startseite mit „Build wurde durch eine SCM-Änderung ausgelöst“ und Revision 2e1c752]**

---

## 5. Linux und Virtualisierung

### 5.1 Virtuelle Maschine

| Parameter | Wert |
|---|---|
| Virtualisierung | Oracle VirtualBox |
| Betriebssystem | Debian 13.x „trixie“, 64 Bit, ohne grafische Oberfläche |
| Arbeitsspeicher | 8 GB |
| Prozessorkerne | 6 |
| Festplatte | 50 GB, dynamisch wachsend |
| Hostname | `netwatch-vm` |
| Zeitzone | Europe/Berlin |

Installiert wurde nur das Nötigste: Standard-Systemwerkzeuge und der SSH-Server. Auf eine
Desktop-Umgebung wurde verzichtet, weil ein Server sie nicht benötigt und sie unnötig
Ressourcen und Angriffsfläche kostet.

### 5.2 Netzwerk

Die VM besitzt zwei Netzwerkkarten mit klar getrennten Aufgaben:

| Schnittstelle | Typ | Adresse | Zweck |
|---|---|---|---|
| `enp0s3` | NAT | 10.0.2.15 (DHCP) | Internetzugang für Paketquellen, GitHub und Docker Hub |
| `enp0s8` | Host-only | 192.168.56.10/24 (statisch) | Verwaltung vom Windows-PC: SSH und Jenkins-Oberfläche |
| `docker0` und Compose-Netze | Bridge | 172.16.0.0/12 | interne Kommunikation der Container |

Der Host-only-Adapter erhält eine feste Adresse, damit SSH-Zugang und Jenkins-URL dauerhaft
gleich bleiben. Er bekommt bewusst **kein** Standard-Gateway: Der gesamte ausgehende Verkehr
läuft über den NAT-Adapter. Die Konfiguration steht in `/etc/network/interfaces`:

```
auto enp0s8
iface enp0s8 inet static
    address 192.168.56.10/24
```

### 5.3 Benutzer und Rechte

| Benutzer | Art | Rechte und Zweck |
|---|---|---|
| `a` | Mensch | Administration über SSH, Mitglied von `sudo` und `docker` |
| `jenkins` | Dienstkonto, automatisch angelegt | führt die Pipeline aus, Mitglied von `docker` |
| `netwatch` | Dienstkonto im Container | führt das Monitoring-Skript ohne Root-Rechte aus |
| `postgres` | Dienstkonto im Datenbank-Container | Datenbankserver |
| `root` | Systemkonto | **[TODO: Anmeldung gesperrt oder Passwort vergeben? bitte eintragen]** |

Die Mitgliedschaft in der Gruppe `docker` erlaubt den Zugriff auf den Docker-Socket und
entspricht damit faktisch Root-Rechten auf der VM. Für `jenkins` ist das unvermeidbar, weil
die Pipeline Container bauen und starten muss. Für einen produktiven Einsatz wäre „rootless
Docker“ oder ein eigener Build-Agent die sauberere Lösung; für einen Prototyp auf einer
isolierten VM ist das Risiko vertretbar und bewusst in Kauf genommen.

Im Container läuft die Anwendung dagegen als unprivilegierter Benutzer `netwatch`. Ping
funktioniert trotzdem, weil Docker unprivilegierte ICMP-Sockets standardmäßig erlaubt.

### 5.4 Installierte Dienste

| Dienst | Port | Erreichbar von |
|---|---|---|
| OpenSSH | 22/tcp | nur aus 192.168.56.0/24 |
| Jenkins | 8080/tcp | nur aus 192.168.56.0/24 |
| Docker und containerd | – | lokal |
| Container `db` (PostgreSQL) | 5432/tcp | nur im internen Docker-Netz |
| Container `netwatch` | – | keine eingehenden Verbindungen |

### 5.5 Absicherung

- **Firewall (ufw):** Standardregel „alles eingehende verbieten, alles ausgehende erlauben“.
  Freigegeben sind nur SSH und Jenkins, und zwar ausschließlich aus dem Host-only-Netz.
- **Keine veröffentlichten Container-Ports:** Von Docker veröffentlichte Ports umgehen ufw.
  Deshalb veröffentlicht die Datenbank keinen Port; sie ist nur containerintern erreichbar.
- **SSH mit Schlüssel:** Die Anmeldung erfolgt mit einem ed25519-Schlüsselpaar, das auf dem
  Windows-PC erzeugt wurde. **[TODO: Wurde `PasswordAuthentication no` gesetzt? bitte eintragen]**
- **Automatische Sicherheitsupdates** über `unattended-upgrades`.
- **Minimale Installation** ohne Desktop und ohne nicht benötigte Dienste.

> **[Screenshot: `sudo ufw status verbose` mit den beiden Freigaben]**

---

## 6. Git und GitHub

### 6.1 Aufbau des Repositorys

```
bin/netwatch.sh           Monitoring-Skript
bin/netwatch-report.sh    Konsolenanzeige der Ergebnisse
config/hosts.conf         Liste der überwachten Systeme
config/hosts.test.conf    feste Hostliste für den Integrationstest
sql/schema.sql            Tabellen, Index und View
tests/netwatch.bats       Unit-Tests
tests/integration.sh      Integrationstest gegen eine echte Datenbank
Dockerfile                Image der Anwendung
compose.yaml              Anwendung und Datenbank
Jenkinsfile               Definition der Pipeline
docs/                     Dokumentation (VM-Einrichtung, Testkonzept, dieser Text)
.env.example              Vorlage für Zugangsdaten, ohne echte Werte
.gitignore .gitattributes .dockerignore
```

Die Gliederung trennt Programm (`bin/`), Konfiguration (`config/`), Datenbank (`sql/`), Tests
(`tests/`) und Dokumentation (`docs/`). Die Definition der Infrastruktur liegt bewusst im
selben Repository: Dockerfile, Compose-Datei und Jenkinsfile werden damit genauso versioniert
und überprüft wie der Programmcode.

### 6.2 Einsatz von Git

Die Arbeit erfolgt in thematisch abgegrenzten Commits mit aussagekräftigen Nachrichten, zum
Beispiel:

```
Projektgrundlage: .gitignore und .gitattributes
NetWatch-Skript mit Datenbankanbindung
Unit-Tests für NetWatch (bats)
Docker-Image und Compose-Setup
Jenkins-Pipeline mit Integrationstest
Dokumentation: README, VM-Einrichtung, Testkonzept
Testfall P1: eigene VM in die Hostliste aufgenommen
Testfall P2: absichtlicher Fehler, ONLINE und OFFLINE vertauscht
Revert "Testfall P2: absichtlicher Fehler, ONLINE und OFFLINE vertauscht"
Pipeline: alte Testberichte vor jedem Lauf entfernen
```

Die absichtlich fehlerhaften Commits der Testfälle P2 und P3 wurden nicht gelöscht, sondern mit
`git revert` zurückgenommen. Dadurch bleibt in der Historie nachvollziehbar, dass der Fehler
eingebaut, von der Pipeline erkannt und anschließend korrigiert wurde.

### 6.3 Umgang mit Zeilenenden

Entwickelt wird unter Windows, ausgeführt wird unter Linux. Eine Datei mit
Windows-Zeilenenden bricht im Container mit der Meldung `$'\r': command not found` ab. Die
Datei `.gitattributes` legt deshalb mit `* text=auto eol=lf` fest, dass alle Textdateien mit
Unix-Zeilenenden gespeichert werden. Ergänzend verarbeitet das Skript auch eine Hostliste mit
Windows-Zeilenenden korrekt – das wird von einem eigenen Unit-Test abgedeckt.

### 6.4 Keine Passwörter im Repository

Die mitgelieferte `.gitignore` wurde durch eine projektbezogene Fassung ersetzt. Sie schließt
`.env`, `*.env`, `secrets/`, Schlüsseldateien, Testergebnisse und Editor-Dateien aus. Versioniert
ist nur die Vorlage `.env.example` mit dem Platzhalter `bitte-aendern`.

Nachweis (Testfall B5): Eine Volltextsuche im gesamten Repository findet ausschließlich
Variablennamen wie `POSTGRES_PASSWORD`, den Platzhalter der Vorlage und das zufällig erzeugte
Einmal-Passwort des Integrationstests. Das Passwort der Produktivdatenbank existiert weder im
Repository noch als Datei auf der VM, sondern ausschließlich im Credential-Speicher von Jenkins.

---

## 7. Die Anwendung NetWatch

### 7.1 Funktionsweise

NetWatch liest eine Liste zu überwachender Systeme, prüft jedes davon per ICMP-Ping und
speichert für jede Prüfung Hostname, IP-Adresse, Prüfzeitpunkt, Status und Antwortzeit. Danach
wartet es bis zum nächsten Intervall, standardmäßig eine Minute.

Die Hostliste `config/hosts.conf` ist bewusst einfach aufgebaut, damit sie ohne Spezialwissen
gepflegt werden kann:

```
# Format: <hostname> <IPv4-Adresse>
localhost        127.0.0.1
dns-cloudflare   1.1.1.1
vbox-nat-gateway 10.0.2.2
netwatch-vm      192.168.56.10
fileserver01     192.168.10.25
```

### 7.2 Aufbau des Skripts

Das Skript ist in kleine, einzeln prüfbare Funktionen gegliedert. Genau diese Gliederung macht
die Unit-Tests möglich:

| Funktion | Aufgabe |
|---|---|
| `is_valid_ipv4`, `is_valid_hostname` | prüfen Einträge der Hostliste auf Gültigkeit |
| `read_hosts` | liest die Hostliste, überspringt Kommentare, Leerzeilen und fehlerhafte Einträge |
| `check_host` | führt den Ping aus und liefert `ONLINE <ms>` oder `OFFLINE` |
| `parse_ping_time` | liest die Antwortzeit aus der Ausgabe von `ping` |
| `print_result` | gibt ein Ergebnis als Tabellenzeile aus |
| `wait_for_db`, `init_schema` | warten auf die Datenbank und legen das Schema an |
| `save_result` | speichert ein Ergebnis über `psql` |
| `run_checks`, `main` | Ablaufsteuerung und Intervall |

Weitere Eigenschaften:

- **Trennung von Daten und Meldungen:** Ergebnisse gehen auf die Standardausgabe, Meldungen
  der Stufen INFO, WARN und ERROR auf die Fehlerausgabe. Dadurch können Ergebnisse
  weiterverarbeitet werden, ohne dass Meldungen sie verfälschen.
- **Sauberes Beenden:** Auf das Signal SIGTERM, das `docker stop` sendet, beendet sich das
  Skript geordnet, statt abgebrochen zu werden.
- **Gleichmäßiger Takt:** Gewartet wird nur die verbleibende Zeit bis zur nächsten Minute, die
  Dauer der Prüfungen wird also abgezogen. Nachgewiesen in Testfall B1.
- **Fehlertoleranz:** Ein nicht erreichbarer Host ist kein Fehler, sondern das gültige Ergebnis
  OFFLINE. Fällt dagegen die Datenbank aus, meldet das Skript den Fehler, läuft aber weiter
  (Testfall B3).
- **Ausführlich kommentiert** in deutscher Sprache, mit Kopfkommentar zu Aufruf, Konfiguration
  und Rückgabewerten.

### 7.3 Ausgabe

Im laufenden Betrieb schreibt NetWatch jede Prüfung in sein Protokoll:

```
netwatch-vm          192.168.56.10   2026-10-05 12:55:49+0200  ONLINE  0.040 ms
fileserver01         192.168.10.25   2026-10-05 12:55:49+0200  OFFLINE
```

Zusätzlich gibt es die Konsolenanwendung `netwatch-report.sh`, die den aktuellen Status je
System und die letzten Prüfungen aus der Datenbank anzeigt:

```
docker exec netwatch-netwatch-1 netwatch-report.sh 10
```

> **[Screenshot: Ausgabe von `netwatch-report.sh` mit aktuellem Status und letzten Prüfungen]**

---

## 8. Datenbank

### 8.1 Datenmodell

Das Modell trennt die überwachten Systeme von den einzelnen Messungen. Ein System hat viele
Prüfergebnisse (1:n):

```
┌──────────────────────┐             ┌────────────────────────────────┐
│ hosts                │             │ checks                         │
├──────────────────────┤             ├────────────────────────────────┤
│ host_id      PK      │1           n│ check_id          PK           │
│ hostname     UNIQUE  │─────────────│ host_id           FK → hosts   │
│ ip_address   inet    │             │ checked_at        timestamptz  │
└──────────────────────┘             │ status            ONLINE/OFFLINE│
                                     │ response_time_ms  numeric, NULL │
                                     └────────────────────────────────┘
```

Ohne diese Trennung stünde der Hostname in jeder einzelnen Messung erneut – bei einer Prüfung
pro Minute und Host wären das schnell Zehntausende redundante Einträge.

### 8.2 Qualitätssicherung in der Datenbank

Das Schema lässt fehlerhafte Daten gar nicht erst zu:

| Regel | Wirkung |
|---|---|
| `ip_address inet` | nur gültige IP-Adressen werden angenommen |
| `status CHECK (… IN ('ONLINE','OFFLINE'))` | kein anderer Status ist möglich |
| `CHECK (status = 'ONLINE' OR response_time_ms IS NULL)` | ein nicht erreichbares System kann keine Antwortzeit haben |
| `hostname UNIQUE` | jedes System existiert genau einmal |
| `REFERENCES hosts … ON DELETE CASCADE` | keine Messungen ohne zugehöriges System |
| Index auf `(host_id, checked_at DESC)` | schnelle Abfrage des letzten Ergebnisses |

Die View `v_latest_status` liefert den jeweils aktuellsten Stand je System und wird von der
Konsolenanwendung und den Tests genutzt.

Das Schema wird beim Start der Anwendung automatisch angelegt. Alle Anweisungen sind so
formuliert, dass ein erneuter Start vorhandene Daten nicht verändert.

### 8.3 Persistenz

Die Datenbank legt ihre Dateien im benannten Volume `netwatch_pgdata` ab, das unabhängig von
den Containern besteht. Nachgewiesen wurde das dreifach: im Integrationstest nach
`docker compose down` (I10), nach dem Neustart des Anwendungscontainers (B2) und nach dem
Neustart der kompletten VM (B4: 462 Prüfungen davor, 477 danach).

### 8.4 Zugangsdaten

Das Skript enthält keine Zugangsdaten. Es liest ausschließlich die Standardvariablen von
`psql` (`PGHOST`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`). Der Weg des Passworts:

```
Jenkins-Credential "netwatch-db"
   → withCredentials in der Stage Deploy (nur dort sichtbar, im Protokoll maskiert)
   → Umgebungsvariable
   → Docker Compose setzt sie im Container
   → psql verwendet sie für die Verbindung
```

Im Integrationstest wird stattdessen bei jedem Lauf ein zufälliges Einmal-Passwort erzeugt, das
nirgends gespeichert wird. Für die Arbeit auf einem Entwicklungsrechner dient eine lokale
Datei `.env`, die von Git ausgeschlossen ist.

> **[Screenshot: SQL-Abfrage mit der Anzahl der Prüfungen je Host]**

---

## 9. Docker

### 9.1 Image der Anwendung

Das Dockerfile baut auf `debian:trixie-slim` auf, also derselben Distribution wie die VM. Es
installiert nur drei Pakete: `iputils-ping` für die Prüfung, `postgresql-client` für `psql` und
`tzdata` für die korrekte lokale Zeit. Anschließend legt es den unprivilegierten Benutzer
`netwatch` an, kopiert Programm, Schema und Konfiguration und setzt die Ausführungsrechte
explizit – unter Windows gehen diese beim Commit sonst verloren.

Die Buildnummer und der Commit-Hash werden als Version in das Image übernommen und beim Start
protokolliert. Dadurch ist im laufenden Betrieb jederzeit erkennbar, welcher Softwarestand
gerade aktiv ist.

Eine `.dockerignore` sorgt dafür, dass weder das `.git`-Verzeichnis noch Dokumentation oder
eine eventuell vorhandene `.env` in den Build-Kontext gelangen.

### 9.2 Zusammenspiel über Docker Compose

| Einstellung | Begründung |
|---|---|
| zwei Dienste `netwatch` und `db` | klare Aufgabentrennung, unabhängig austauschbar |
| `depends_on` mit `condition: service_healthy` | NetWatch startet erst, wenn die Datenbank wirklich bereit ist |
| Healthcheck `pg_isready` | prüft die Bereitschaft der Datenbank statt nur den Containerstatus |
| benanntes Volume `pgdata` | Daten überleben Neustart, Update und `docker compose down` |
| eigenes Netz `backend` | Container erreichen sich über den Dienstnamen `db` |
| kein `ports:` bei der Datenbank | von außen nicht erreichbar, auch nicht an der Firewall vorbei |
| `restart: unless-stopped` | beide Container starten nach einem Neustart der VM automatisch |
| `${POSTGRES_PASSWORD:?…}` | fehlt das Passwort, bricht Compose mit klarer Meldung ab |

Der Integrationstest startet dieselbe Compose-Datei unter einem eigenen Projektnamen
(`netwatch-test-<Buildnummer>`). Dadurch entstehen eigene Container, ein eigenes Netz und ein
eigenes Volume; die Produktivumgebung läuft ungestört weiter. Im Testfall B2 war dieser Zustand
sichtbar: Während `netwatch-test-7-db-1` lief, prüfte `netwatch-netwatch-1` ununterbrochen weiter.

> **[Screenshot: `docker ps` mit Produktiv- und Testcontainern gleichzeitig]**

---

## 10. Jenkins und die CI/CD-Pipeline

### 10.1 Einrichtung

Jenkins 2.580.1 wurde aus dem offiziellen Jenkins-Repository installiert und läuft als
systemd-Dienst unter OpenJDK 21. Der Benutzer `jenkins` wurde in die Gruppe `docker`
aufgenommen, damit die Pipeline Images bauen und Container starten kann. Die Oberfläche ist
unter `http://192.168.56.10:8080` erreichbar, ausschließlich aus dem Host-only-Netz.

Eingerichtet wurden:

- ein Credential vom Typ „Username with password“ mit der ID `netwatch-db` für die
  Produktivdatenbank,
- ein Job vom Typ *Pipeline* mit der Definition „Pipeline script from SCM“, der das Jenkinsfile
  aus dem Branch `main` des GitHub-Repositorys liest.

Damit liegt die gesamte Pipeline-Definition im Repository und nicht in der
Jenkins-Konfiguration. Sie ist versioniert, überprüfbar und bei einer Neuinstallation von
Jenkins mit wenigen Klicks wiederhergestellt.

> **[Screenshot: Credential `netwatch-db` in der Jenkins-Verwaltung]**
> **[Screenshot: Job-Konfiguration „Pipeline script from SCM“ mit Repository-URL und Branch]**

### 10.2 Aufbau der Pipeline

| Stage | Inhalt | Dauer (Build #6) |
|---|---|---|
| Checkout | Quellcode aus GitHub holen, alte Testberichte entfernen | < 1 s |
| Lint | ShellCheck prüft alle Bash-Skripte | ≈ 2 s |
| Unit-Tests | 14 bats-Tests, Ergebnis als JUnit-Bericht | ≈ 5 s |
| Image bauen | `docker build` mit Commit-Hash als Version | ≈ 10 s |
| Integrationstest | Test-Datenbank, Prüflauf, 10 Kontrollen in der Datenbank | ≈ 18 s |
| Deploy | neue Version mit Zugangsdaten aus dem Credential starten | ≈ 8 s |

Insgesamt dauert ein vollständiger Durchlauf etwa 37 Sekunden. Weitere Einstellungen:

- **Trigger:** `pollSCM('H/2 * * * *')` – Abfrage alle zwei Minuten.
- **Zeitlimit:** 20 Minuten, damit ein hängender Build nicht dauerhaft blockiert.
- **Keine parallelen Builds**, damit sich zwei Durchläufe nicht gegenseitig die Container
  wegräumen.
- **Aufbewahrung** der letzten 20 Builds.
- **Nach einem Fehlschlag** wird das eventuell entstandene Image wieder gelöscht, damit keine
  ungetestete Version im System zurückbleibt.

### 10.3 Teststufen in der Pipeline

Die Tests sind nach Aufwand gestaffelt, sodass einfache Fehler früh und billig auffallen:

1. **ShellCheck** findet Syntax- und Stilfehler in Sekunden, ohne etwas auszuführen.
2. **Unit-Tests** prüfen die Logik der einzelnen Funktionen, ohne Netzwerk und Datenbank. Der
   Ping wird dabei durch eine Testfunktion ersetzt, sodass beide Fälle – erreichbar und nicht
   erreichbar – zuverlässig und ohne Wartezeit prüfbar sind.
3. **Integrationstest** prüft das Zusammenspiel aller Teile gegen eine echte PostgreSQL-Datenbank,
   einschließlich der Fehlerfälle „falsches Passwort“ und „Datenbank nicht erreichbar“.

> **[Screenshot: Job-Übersicht mit den Builds #1 bis #6 und dem Trend der Testergebnisse]**

---

## 11. Testkonzept und Ergebnisse

Getestet wurde auf vier Ebenen: automatisierte Unit-Tests (U), automatisierte Integrationstests
(I), Tests der Pipeline selbst (P) und Tests des laufenden Betriebs (B). U und I laufen bei
jedem Commit automatisch, P und B wurden einmalig von Hand durchgeführt und dokumentiert.

### 11.1 Automatisierte Tests (Nachweis: Build #1 und folgende)

| Nr. | Testfall | Art | Soll | Ist | OK |
|---|---|---|---|---|---|
| U1 | gültige IP-Adressen | positiv | werden akzeptiert | `ok 1` | ✓ |
| U2 | ungültige IP-Adressen (256.1.1.1, 1.2.3, abc) | negativ | werden abgelehnt | `ok 2` | ✓ |
| U3 | Antwortzeit aus ping-Ausgabe lesen | positiv | `time=0.045 ms` → `0.045` | `ok 5–7` | ✓ |
| U4 | Ping erfolgreich (simuliert) | positiv | `ONLINE 12.3` | `ok 8` | ✓ |
| U5 | Ping fehlgeschlagen (simuliert) | negativ | `OFFLINE` | `ok 9` | ✓ |
| U6 | Hostliste mit Kommentaren, Leerzeilen, Windows-Zeilenenden | positiv | nur gültige Einträge | `ok 10, 12` | ✓ |
| U7 | ungültige Einträge, fehlende Datei | negativ | übersprungen bzw. Fehler | `ok 11, 13` | ✓ |
| I1 | Prüfdurchlauf `--once` | positiv | Rückgabewert 0 | `PASS I1` | ✓ |
| I2 | 127.0.0.1 prüfen | positiv | `ONLINE` mit Antwortzeit | `ONLINE`, 0.034 ms | ✓ |
| I4 | 192.0.2.1 (nicht erreichbar) prüfen | negativ | `OFFLINE`, keine Antwortzeit | `OFFLINE`, NULL | ✓ |
| I6 | ungültiger Eintrag 999.1.1.1 | negativ | wird nicht gespeichert | 0 Treffer, genau 2 Messungen | ✓ |
| I8 | falsches Datenbank-Passwort | negativ | Fehler, Rückgabewert ≠ 0 | `password authentication failed` | ✓ |
| I9 | Datenbank gestoppt | negativ | Fehler, Rückgabewert ≠ 0 | `could not translate host name "db"` | ✓ |
| I10 | `docker compose down` und Neustart | positiv | Daten noch vorhanden | 2 von 2 Datensätzen | ✓ |

Als Negativtest dient die Adresse 192.0.2.1. Sie stammt aus dem laut RFC 5737 für
Dokumentationszwecke reservierten Bereich und wird im Internet nie geroutet – der Test ist
dadurch unabhängig von der jeweiligen Netzumgebung immer aussagekräftig.

### 11.2 Tests der Pipeline (05.10.2026)

| Nr. | Testfall | Soll | Ist | OK |
|---|---|---|---|---|
| P1 | Commit löst Build aus | Start ohne Zutun innerhalb von 2 Minuten, Deploy der neuen Version | Push 12:19, Build #3 um 12:22, „durch eine SCM-Änderung ausgelöst“, danach läuft `netwatch:3` und überwacht den neuen Host | ✓ |
| P2 | fehlerhafter Code wird gestoppt | Abbruch in den Unit-Tests, kein Deploy | Build #4 nach 8,6 s rot, Test „check_host meldet ONLINE …“ fehlgeschlagen, kein Image `netwatch:4`, alte Version lief ununterbrochen weiter | ✓ |
| P3 | Stilfehler wird gestoppt | Abbruch, kein Deploy | Build #5 nach 8,7 s rot, kein Deploy **[TODO: Stage aus der Konsolenausgabe ergänzen]** | ✓ |
| P4 | Korrektur per `git revert` | Pipeline wieder grün | Build #6, 37 s, alle Stages grün, Deploy von `netwatch:6` | ✓ |

P2 ist der Kerntest des Auftrags: Eine fehlerhafte Version darf nicht bereitgestellt werden.
Die Pipeline hat den Fehler nicht nur erkannt, sie hat ihn so früh erkannt, dass gar kein Image
entstanden ist.

> **[Screenshot: Build #4 – rot, mit dem Namen des fehlgeschlagenen Tests]**
> **[Screenshot: Build-Dauer-Trend, der den Unterschied zwischen 8,6 s und 37 s zeigt]**
> **[Screenshot: Build #6 – grün, mit beiden Revert-Commits]**

### 11.3 Tests des laufenden Betriebs

| Nr. | Testfall | Soll | Ist | OK |
|---|---|---|---|---|
| B1 | regelmäßige Prüfung | etwa eine Messung je Host und Minute | genau 5 Messungen je Host in 5 Minuten, bei allen 5 Hosts | ✓ |
| B2 | Neustart des Anwendungscontainers | läuft weiter, Daten bleiben | Messungen ab 12:54:49 fortgesetzt, bisherige Daten unverändert | ✓ |
| B3 | Ausfall der Datenbank | Fehlermeldung, kein Absturz, danach weiter | Fehler je Host protokolliert, Container blieb „Up“, ab 13:00:49 wieder Messungen gespeichert | ✓ |
| B4 | Neustart der VM | alles startet automatisch, Daten bleiben | Docker und Jenkins aktiv, beide Container automatisch gestartet, 462 → 477 Messungen | ✓ |
| B5 | keine Passwörter im Repository | nur Variablennamen und Platzhalter | bestätigt, `.env` nicht versioniert und auf der VM nicht vorhanden | ✓ |

> **[Screenshot: B3 – Protokoll mit den Fehlermeldungen während des Datenbankausfalls]**
> **[Screenshot: B4 – Anzahl der Messungen vor und nach dem Neustart der VM]**

---

## 12. Probleme und Abweichungen

Die folgenden Punkte traten während der Umsetzung auf. Sie sind bewusst dokumentiert, weil sie
zeigen, wie die jeweilige Ursache gefunden und behoben wurde.

| # | Problem | Ursache | Lösung |
|---|---|---|---|
| 1 | Kein SSH-Zugang nach der Installation | Der SSH-Server war bei der Paketauswahl nicht mit ausgewählt worden | `openssh-server` nachinstalliert, Dienst startet seitdem automatisch |
| 2 | `ping: Temporary failure in name resolution` | Nur der Host-only-Adapter war konfiguriert, der NAT-Adapter und damit DNS und Standard-Gateway fehlten | Beide Adapter in `/etc/network/interfaces` eingetragen und die VM neu gestartet; vermutlich hatte zusätzlich die DHCP-Zuweisung nicht gegriffen **[TODO: eigene Beschreibung ergänzen]** |
| 3 | `apt` lehnte das Jenkins-Repository ab: „The repository is not signed“ | Jenkins hatte den Signaturschlüssel gewechselt; die gängigen Anleitungen nennen noch `jenkins.io-2023.key` | Aktuellen Schlüssel `jenkins.io-2026.key` geladen, Fingerprint mit der Fehlermeldung abgeglichen, Anleitung im Repository korrigiert |
| 4 | SSH-Schlüsselpaar zunächst auf der VM erzeugt | Missverständnis: Der Schlüssel gehört auf den Client, nicht auf den Server | Schlüssel auf dem Windows-PC erzeugt, öffentlichen Teil in `authorized_keys` der VM übertragen |
| 5 | Jenkins-Job hieß zunächst „Pipeline script from SCM“ | Die Bezeichnung der Definitionsart wurde als Jobname eingetragen | Job als `netwatch` neu angelegt und mit einer Beschreibung versehen |
| 6 | Zeitstempel der VM in US-Zeitzone (EDT) | Zeitzone bei der Installation nicht gesetzt | Auf `Europe/Berlin` umgestellt; Jenkins, Systemprotokoll und Datenbank zeigen seitdem dieselbe Zeit |
| 7 | Jenkins konnte das Repository nicht klonen | Das Repository war zunächst privat | Repository veröffentlicht; alternativ wäre ein GitHub-Token mit Leserecht als Jenkins-Credential möglich gewesen |
| 8 | `.gitignore` passte nicht zum Projekt | Bei der Erstellung auf GitHub war die Visual-Studio-Vorlage ausgewählt worden | Durch eine Fassung für dieses Projekt ersetzt (Zugangsdaten, Testergebnisse, Editor-Dateien) |
| 9 | Git verweigerte die Arbeit im Projektordner | Das Repository liegt auf einem Netzlaufwerk, dessen Besitzer Git nicht als vertrauenswürdig einstuft („dubious ownership“) | Den Pfad einmalig als `safe.directory` eingetragen |
| 10 | Jenkins zeigte bei Testfall P3 ein Testergebnis an, obwohl kein Test lief | Der Arbeitsbereich bleibt zwischen Builds bestehen; die Auswertung las den Bericht des vorherigen Builds erneut ein | Der Ordner `test-results` wird jetzt direkt nach dem Checkout gelöscht |

Problem 10 ist ein Nebenergebnis der eigenen Testreihe: Erst der absichtlich herbeigeführte
Fehlschlag hat diese Schwäche der Pipeline sichtbar gemacht.

---

## 13. Fazit

Der Prototyp erfüllt alle geforderten Punkte. Eine Codeänderung erreicht ohne manuelles
Zutun innerhalb von etwa drei Minuten das Testsystem: zwei Minuten Wartezeit durch das Polling
und rund 40 Sekunden für Test und Bereitstellung. Fehlerhafte Versionen werden zuverlässig
abgefangen, bevor sie ausgeliefert werden – nachgewiesen durch zwei absichtlich eingebaute
Fehler. Die Monitoring-Daten überstehen Container-Neustarts, einen Datenbankausfall und den
Neustart der gesamten virtuellen Maschine.

Die eingangs beschriebenen Probleme der Abteilung sind damit adressiert: Tests können nicht
mehr vergessen werden, weil sie Teil der Pipeline sind. Unterschiedliche Softwarestände sind
ausgeschlossen, weil jede Version als Image mit Commit-Hash gebaut und bereitgestellt wird.
Und fehlerhafte Versionen gelangen nicht auf das Testsystem, weil das Deployment erst nach
bestandenen Tests erfolgt.

### Mögliche Erweiterungen

- **Webhook statt Polling**, sobald der Server aus dem Internet erreichbar ist, oder über einen
  Weiterleitungsdienst wie smee.io. Das verkürzt die Reaktionszeit von Minuten auf Sekunden.
- **Eigene Datenbankrolle** für die Anwendung mit Rechten nur auf `hosts` und `checks`, statt
  des Administratorkontos.
- **Prüfung einzelner Dienste** zusätzlich zum Ping, etwa ein TCP-Verbindungstest auf Port 443.
- **Weboberfläche** als Ergänzung zur Konsolenausgabe.
- **Image-Registry**, damit dieselbe getestete Version auch auf anderen Servern eingesetzt
  werden kann.
- **Benachrichtigung** bei fehlgeschlagenen Builds oder bei Systemen, die mehrfach
  hintereinander OFFLINE sind.
- **Rootless Docker oder ein eigener Build-Agent**, um die weitreichenden Rechte der Gruppe
  `docker` einzuschränken.

---

## 14. Übersicht der Nachweise

| Nachweis | Bezug zur Bewertung |
|---|---|
| Architektur- und Ablaufbeschreibung (Abschnitte 3 und 4) | Teil 1 |
| `ufw status`, Netz- und Benutzertabellen (Abschnitt 5) | Teil 2 |
| Repository-Struktur, Commit-Liste, Passwortsuche (Abschnitt 6) | Teil 3 |
| Aufbau des Skripts, Protokoll- und Reportausgabe (Abschnitt 7) | Teil 4 |
| Datenmodell, SQL-Abfragen, Persistenznachweise (Abschnitt 8) | Teil 5 |
| Dockerfile, Compose-Einstellungen, `docker ps` (Abschnitt 9) | Teil 6 |
| Jenkins-Einrichtung, Pipeline-Stages, Builds #1 bis #7 (Abschnitt 10) | Teil 7 |
| Testtabellen U, I, P und B mit Soll und Ist (Abschnitt 11) | Teil 8 |
