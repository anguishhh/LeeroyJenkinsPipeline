# Einrichtung der VM, Docker und Jenkins

Schritt-für-Schritt-Anleitung. Alles, was mit **TODO** markiert ist, beim Einrichten mit den
tatsächlichen Werten füllen – die Tabellen sind gleichzeitig die Dokumentation für das CMS.

## 1. Virtuelle Maschine (VirtualBox)

| Parameter | Wert |
|-----------|------|
| Betriebssystem | Debian 13.x „trixie“, 64 Bit (Netinst-ISO) |
| RAM / CPU | 8 GB / 6 Kerne |
| Festplatte | 50 GB, dynamisch |
| Netzwerkadapter 1 | NAT – Internetzugang (Pakete, GitHub, Docker Hub) |
| Netzwerkadapter 2 | Host-only-Adapter (`192.168.56.0/24`) – Zugriff vom Windows-PC auf SSH und Jenkins |
| Hostname | `netwatch-vm` |

Installation: ohne Desktop-Umgebung, nur **SSH-Server** und **Standard-Systemwerkzeuge**.
Beim Root-Passwort **nichts eingeben** – dann ist das Root-Konto gesperrt und der
angelegte Benutzer erhält `sudo`-Rechte.

## 2. Netzwerk

Schnittstellen anzeigen: `ip -br addr` (in VirtualBox meist `enp0s3` = NAT, `enp0s8` = Host-only).

Feste IP für den Host-only-Adapter in `/etc/network/interfaces` ergänzen:

```
auto enp0s8
iface enp0s8 inet static
    address 192.168.56.10/24
```

```bash
sudo systemctl restart networking
ip -br addr                     # Kontrolle
ping -c 3 deb.debian.org        # Internet über NAT
```

Vom Windows-PC aus: `ping 192.168.56.10`, `ssh <benutzer>@192.168.56.10`

| Schnittstelle | Typ | Adresse | Zweck |
|---------------|-----|---------|-------|
| enp0s3 | NAT | 10.0.2.15 (DHCP) | Internet |
| enp0s8 | Host-only | 192.168.56.10/24 (statisch) | Verwaltung vom PC |
| docker0 / Compose-Netze | Bridge | 172.x.x.x | Container intern |

## 3. Grundpakete und Absicherung

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git curl ca-certificates ufw unattended-upgrades
```

**Firewall** – nur SSH und Jenkins, und nur aus dem Host-only-Netz:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.56.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 8080 proto tcp
sudo ufw enable
sudo ufw status verbose
```

> Achtung: Von Docker veröffentlichte Ports (`ports:` in Compose) umgehen ufw. Deshalb
> veröffentlicht die Datenbank bewusst keinen Port.

**SSH mit Schlüssel statt Passwort** (auf dem Windows-PC in PowerShell):

```powershell
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <benutzer>@192.168.56.10 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Wenn die Anmeldung per Schlüssel klappt, auf der VM `/etc/ssh/sshd_config.d/10-hardening.conf` anlegen:

```
PermitRootLogin no
PasswordAuthentication no
```

```bash
sudo systemctl reload ssh
```

Sicherheitsupdates automatisch: `sudo dpkg-reconfigure -plow unattended-upgrades`

## 4. Docker

Offizielles Docker-Repository (aktuelle Anleitung: <https://docs.docker.com/engine/install/debian/>):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo docker run --rm hello-world     # Test
docker compose version
```

## 5. Jenkins

Java und Jenkins aus dem offiziellen Jenkins-Repository. Die Schlüssel-URL wird gelegentlich
erneuert – vorher mit <https://www.jenkins.io/doc/book/installing/linux/#debianubuntu> abgleichen.

```bash
sudo apt install -y fontconfig openjdk-21-jre
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list
sudo apt update
sudo apt install -y jenkins

# Jenkins darf Docker verwenden (Neustart nötig, damit die Gruppe greift)
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
systemctl status jenkins
```

Einrichtung im Browser unter `http://192.168.56.10:8080`:

1. Initialpasswort: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`
2. „Install suggested plugins“ (enthält Git, Pipeline, Credentials Binding, JUnit, Timestamper)
3. Eigenen Admin-Benutzer anlegen

**Credential für die Datenbank** – *Jenkins verwalten → Credentials → System → Global → Add Credentials*:

| Feld | Wert |
|------|------|
| Kind | Username with password |
| Username | `netwatch` |
| Password | sicheres Passwort (nirgends sonst notieren als im Passwortmanager) |
| ID | `netwatch-db` (so heißt es im Jenkinsfile) |

**Pipeline-Job** – *Neues Element → Pipeline*:

| Einstellung | Wert |
|-------------|------|
| Definition | Pipeline script from SCM |
| SCM | Git, URL `https://github.com/anguishhh/LeeroyJenkinsPipeline.git` |
| Credentials | keine, falls das Repository öffentlich ist; sonst GitHub-Token (nur Lesezugriff) |
| Branch | `*/main` |
| Script Path | `Jenkinsfile` |

Danach **einmal manuell „Jetzt bauen“** – erst beim ersten Lauf liest Jenkins das
Jenkinsfile und aktiviert das Polling. Ob Polling läuft, zeigt der Job unter „Git Polling Log“.

> Hinweis: Postgres übernimmt Benutzer und Passwort nur beim **ersten** Anlegen des Volumes.
> Wurde NetWatch vorher schon manuell mit `docker compose up` und anderen Zugangsdaten
> gestartet, entweder dieselben Daten im Credential verwenden oder vorher einmalig
> `docker compose down -v` ausführen (löscht die Daten!).

## 6. Übersicht für die Dokumentation

**Benutzer**

| Benutzer | Zweck | Rechte |
|----------|-------|--------|
| root | – | Anmeldung gesperrt |
| TODO (eigener Admin) | Administration per SSH | sudo, nur SSH-Schlüssel |
| jenkins | Dienstkonto von Jenkins | Gruppe `docker` |
| netwatch (im Container) | führt das Skript aus | keine Root-Rechte |

**Dienste**

| Dienst | Port | Erreichbar von |
|--------|------|----------------|
| OpenSSH | 22/tcp | Host-only-Netz |
| Jenkins | 8080/tcp | Host-only-Netz |
| Docker / containerd | – | lokal |
| Container `netwatch` | – | – (nur ausgehende Pings, DB-Verbindung) |
| Container `db` (PostgreSQL) | 5432/tcp | nur internes Docker-Netz |
