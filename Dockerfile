# NetWatch – Container-Image
#
# Basis: Debian 13 "trixie" (gleiche Distribution wie die VM) in der schlanken Variante.
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

# iputils-ping:      ping mit Antwortzeit und Timeout (-W)
# postgresql-client: psql zum Schreiben in die Datenbank
# tzdata:            korrekte lokale Zeit (Europe/Berlin) für den Prüfzeitpunkt
RUN apt-get update \
 && apt-get install -y --no-install-recommends iputils-ping postgresql-client tzdata \
 && rm -rf /var/lib/apt/lists/*

# Eigener Benutzer ohne Root-Rechte – die Anwendung braucht keine.
# (Ping funktioniert trotzdem: Docker erlaubt standardmäßig ICMP für alle Benutzer.)
RUN useradd --system --no-create-home --shell /usr/sbin/nologin netwatch

ENV TZ=Europe/Berlin \
    PGTZ=Europe/Berlin \
    NETWATCH_HOSTS_FILE=/app/config/hosts.conf \
    NETWATCH_SCHEMA_FILE=/app/sql/schema.sql \
    PATH="/app/bin:${PATH}"

WORKDIR /app
COPY bin/    bin/
COPY sql/    sql/
COPY config/ config/
# Ausführungsrechte explizit setzen – beim Commit unter Windows gehen sie leicht verloren
RUN chmod 0755 bin/*.sh

# Version (Git-Commit) wird von der Pipeline übergeben und beim Start geloggt.
# Steht bewusst weit unten, damit sich die Schichten darüber im Cache wiederverwenden lassen.
ARG VERSION=dev
ENV NETWATCH_VERSION=${VERSION}
LABEL org.opencontainers.image.title="NetWatch" \
      org.opencontainers.image.version="${VERSION}"

USER netwatch
ENTRYPOINT ["/app/bin/netwatch.sh"]
