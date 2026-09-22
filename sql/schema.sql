-- NetWatch – Datenbankschema (PostgreSQL)
--
-- Wird bei jedem Start von netwatch.sh ausgeführt. Alle Befehle sind idempotent
-- (IF NOT EXISTS / OR REPLACE), vorhandene Daten bleiben also erhalten.
--
-- ERM:   hosts (1) ────< (n) checks
--   hosts   – ein überwachtes System; der Hostname ist eindeutig
--   checks  – ein einzelnes Prüfergebnis eines Systems zu einem Zeitpunkt

CREATE TABLE IF NOT EXISTS hosts (
    host_id     integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hostname    varchar(253) NOT NULL UNIQUE,
    ip_address  inet         NOT NULL
);

CREATE TABLE IF NOT EXISTS checks (
    check_id          bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    host_id           integer      NOT NULL REFERENCES hosts (host_id) ON DELETE CASCADE,
    checked_at        timestamptz  NOT NULL,
    status            varchar(7)   NOT NULL CHECK (status IN ('ONLINE', 'OFFLINE')),
    response_time_ms  numeric(8,3) CHECK (response_time_ms >= 0),
    -- Ein nicht erreichbares System kann keine Antwortzeit haben
    CONSTRAINT response_time_only_if_online
        CHECK (status = 'ONLINE' OR response_time_ms IS NULL)
);

-- Beschleunigt "letztes Ergebnis je Host" und zeitliche Abfragen
CREATE INDEX IF NOT EXISTS idx_checks_host_time ON checks (host_id, checked_at DESC);

-- Letztes Prüfergebnis je System
CREATE OR REPLACE VIEW v_latest_status AS
SELECT DISTINCT ON (h.host_id)
       h.hostname,
       h.ip_address,
       c.checked_at,
       c.status,
       c.response_time_ms
FROM   hosts  h
JOIN   checks c USING (host_id)
ORDER  BY h.host_id, c.checked_at DESC, c.check_id DESC;
