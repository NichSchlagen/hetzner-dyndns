# hetzner-dyndns

Setzt A- (und optional AAAA-) Records einer DNS-Zone in der Hetzner Console
(Projekt -> DNS) auf die aktuelle öffentliche IP des Servers. Nutzt die Hetzner Cloud API
(`api.hetzner.cloud/v1/zones/.../rrsets`).

- Bestehende Records werden nur geändert, wenn sich die IP (oder TTL) unterscheidet, fehlende werden angelegt.
- Wartet, bis Hetzner die Änderung bestätigt hat (asynchrone Actions).
- Wiederholt bei Netzwerkfehlern, 429 und 5xx automatisch mit Backoff.
- Fehler bei einem Record brechen die anderen nicht ab; Exit-Code 1, wenn irgendwas schiefging.
- Öffentliche IP über mehrere Dienste mit Fallback und strenger Validierung.
- Token wird per stdin an curl übergeben und taucht nicht in der Prozessliste auf.
- Keine parallelen Läufe (flock), Dry-Run mit `-n`.

## Setup

```bash
sudo apt install curl jq
sudo install -m 755 hetzner-dyndns.sh /usr/local/bin/
sudo install -m 600 hetzner-dyndns.conf.example /etc/hetzner-dyndns.conf
sudo nano /etc/hetzner-dyndns.conf          # Token, Zone, Records eintragen

sudo hetzner-dyndns.sh -n                   # Dry-Run: zeigt nur, was passieren würde
sudo hetzner-dyndns.sh                      # echt ausführen
```

API-Token: Hetzner Console -> Projekt -> Sicherheit -> API-Tokens -> Token mit **Lesen & Schreiben**.

Statt Config-Datei gehen auch Umgebungsvariablen (`HETZNER_API_TOKEN`, `ZONE`, `RECORDS`, `TTL`, `IPV4`, `IPV6`).

## Automatisch ausführen

**systemd (empfohlen)**, alle 5 Minuten, Logs im Journal:

```bash
sudo cp systemd/hetzner-dyndns.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hetzner-dyndns.timer
journalctl -u hetzner-dyndns -f             # Logs ansehen
```

**oder cron:**

```bash
*/5 * * * * /usr/local/bin/hetzner-dyndns.sh >> /var/log/hetzner-dyndns.log 2>&1
```
