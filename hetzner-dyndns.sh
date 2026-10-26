#!/usr/bin/env bash
# Hetzner DynDNS: setzt A/AAAA-Records einer DNS-Zone (Hetzner Console -> Projekt -> DNS)
# auf die aktuelle öffentliche IP dieses Servers.
# Abhängigkeiten: bash >= 4, curl, jq (optional: flock)
set -euo pipefail

API="https://api.hetzner.cloud/v1"
SELF=$(readlink -f "$0")

usage() {
  cat <<EOF
Aufruf: $(basename "$0") [-n] [-c CONFIG]
  -n         Dry-Run: nur anzeigen, was geändert würde
  -c CONFIG  Config-Datei (Standard: hetzner-dyndns.conf neben dem Skript,
             sonst /etc/hetzner-dyndns.conf)
  -h         Diese Hilfe
EOF
}

log()  { echo "$(date '+%F %T') $*"; }
warn() { log "WARNUNG: $*" >&2; }
err()  { log "FEHLER: $*" >&2; }
die()  { err "$*"; exit 1; }

DRY_RUN=0
while getopts "nc:h" opt; do
  case $opt in
    n) DRY_RUN=1 ;;
    c) CONFIG=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# --- Config laden ----------------------------------------------------------
if [ -n "${CONFIG:-}" ]; then
  [ -f "$CONFIG" ] || die "Config $CONFIG nicht gefunden"
else
  CONFIG="$(dirname "$SELF")/hetzner-dyndns.conf"
  [ -f "$CONFIG" ] || CONFIG=/etc/hetzner-dyndns.conf
fi
if [ -f "$CONFIG" ]; then
  [ -n "$(find "$CONFIG" -perm /044 2>/dev/null)" ] && warn "$CONFIG ist für andere lesbar, bitte: chmod 600 $CONFIG"
  # shellcheck source=/dev/null
  . "$CONFIG"
fi

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || die "$cmd ist nicht installiert"
done

[ -n "${HETZNER_API_TOKEN:-}" ] || die "HETZNER_API_TOKEN fehlt (Projekt -> Sicherheit -> API-Tokens, Lesen & Schreiben)"
[ -n "${ZONE:-}" ] || die "ZONE fehlt (z.B. example.com)"
ZONE=${ZONE,,}; ZONE=${ZONE%.}
read -ra RECORD_LIST <<<"${RECORDS:-@}"  # "@" = Zone selbst
TTL=${TTL-60}                             # leer = TTL nicht verwalten
IPV4=${IPV4:-1}
IPV6=${IPV6:-0}

[[ -z $TTL || ( $TTL =~ ^[0-9]+$ && $TTL -ge 60 ) ]] || die "TTL muss leer oder eine Zahl >= 60 sein"
[[ $IPV4 =~ ^[01]$ && $IPV6 =~ ^[01]$ ]] || die "IPV4/IPV6 müssen 0 oder 1 sein"
[ "$IPV4$IPV6" != 00 ] || die "IPV4 und IPV6 sind beide deaktiviert"
[ ${#RECORD_LIST[@]} -gt 0 ] || die "RECORDS ist leer"

# --- Nur eine Instanz gleichzeitig (z.B. überlappende Cronjobs) ------------
if command -v flock >/dev/null; then
  exec 9<"$SELF"
  flock -n 9 || { log "Läuft bereits, beende."; exit 0; }
fi

# --- API -------------------------------------------------------------------
# api METHOD PFAD [JSON] -> setzt STATUS (000 = keine Verbindung) und BODY.
# Wiederholt bei Verbindungsfehlern, 429 und 5xx bis zu $RETRIES mal (Standard 3).
# Der Token geht per stdin an curl, damit er nicht in der Prozessliste steht.
api() {
  local res attempt delay
  for ((attempt = 0; ; attempt++)); do
    if res=$(printf 'header = "Authorization: Bearer %s"\n' "$HETZNER_API_TOKEN" |
      curl -sS -K - -X "$1" "$API$2" \
        --proto =https -A hetzner-dyndns -H "Content-Type: application/json" \
        --connect-timeout 10 --max-time 30 \
        ${3:+--data "$3"} -w '\n%{http_code}'); then
      BODY=${res%$'\n'*}
      STATUS=${res##*$'\n'}
    else
      BODY=""
      STATUS=000
    fi
    [[ $STATUS == 000 || $STATUS == 429 || $STATUS == 5* ]] || return 0
    ((attempt < ${RETRIES:-3})) || return 0
    delay=$((5 * (attempt + 1)))
    warn "$1 $2: $(api_error), neuer Versuch in ${delay}s"
    sleep "$delay"
  done
}

# jget FILTER -> Wert aus BODY; Fehler (ohne Ausgabe) bei null/fehlend/kein JSON
jget() { jq -er "($1) // empty" <<<"$BODY" 2>/dev/null; }

api_error() {
  if [ "$STATUS" = 000 ]; then
    echo "keine Verbindung zur API"
  else
    echo "HTTP $STATUS: $(jget '.error.message' || echo "${BODY:0:200}")"
  fi
}

# Wartet, bis die Action aus BODY abgeschlossen ist.
wait_action() {
  local id status
  id=$(jget '.action.id') || { err "Antwort enthält keine Action"; return 1; }
  for _ in $(seq 30); do
    status=$(jget '.action.status') || { err "Action $id: ungültige Antwort"; return 1; }
    case $status in
      success) return 0 ;;
      error) err "Action $id: $(jget '.action.error.message' || echo unbekannter Fehler)"; return 1 ;;
    esac
    sleep 2
    api GET "/zones/actions/$id"
    [ "$STATUS" = 200 ] || { err "Action $id abfragen: $(api_error)"; return 1; }
  done
  err "Action $id: Zeitüberschreitung"
  return 1
}

# action PFAD JSON BESCHREIBUNG [RETRIES]
action() {
  if [ "$DRY_RUN" = 1 ]; then
    log "[Dry-Run] $3"
    return 0
  fi
  RETRIES=${4:-3} api POST "$1" "$2"
  [[ $STATUS == 2* ]] || { err "$3: $(api_error)"; return 1; }
  wait_action || { err "$3: fehlgeschlagen"; return 1; }
  log "$3"
}

# --- Logik -----------------------------------------------------------------
# public_ip 4|6 -> erste gültige Antwort mehrerer Dienste
public_ip() {
  local url ip
  for url in https://api64.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -"$1" -sS --proto =https --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    ip=${ip,,}
    valid_ip "$1" "$ip" && { echo "$ip"; return 0; }
  done
  return 1
}

valid_ip() {
  local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  if [ "$1" = 4 ]; then
    [[ $2 =~ ^$o\.$o\.$o\.$o$ ]]
  else
    [[ $2 =~ ^[0-9a-f:]+$ && $2 == *:*:* && ${#2} -le 39 ]]
  fi
}

# "home.example.com." -> "home", "example.com" -> "@"
normalize() {
  local n=${1,,}
  n=${n%.}
  if [ "$n" = "$ZONE" ]; then echo @; else echo "${n%."$ZONE"}"; fi
}

# update NAME TYPE IP
update() {
  local name=$1 type=$2 ip=$3 path="/zones/$ZONE/rrsets/$1/$2" current ttl
  api GET "$path"
  case $STATUS in
    200) ;;
    404)
      # Kein Retry beim Anlegen, sonst droht bei Timeouts ein Konflikt
      action "/zones/$ZONE/rrsets" \
        "$(jq -nc --arg n "$name" --arg t "$type" --arg ip "$ip" --arg ttl "$TTL" \
          '{name: $n, type: $t, ttl: (if $ttl == "" then null else ($ttl | tonumber) end), records: [{value: $ip}]}')" \
        "$name $type angelegt: $ip" 0
      return
      ;;
    *) err "$name $type abfragen: $(api_error)"; return 1 ;;
  esac

  current=$(jget '[.rrset.records[].value] | join(" ")') || { err "$name $type: ungültige API-Antwort"; return 1; }
  ttl=$(jget '.rrset.ttl // "zone-default"') || ttl=""

  if [ "$current" = "$ip" ]; then
    log "$name $type unverändert ($ip)"
  else
    action "$path/actions/set_records" "$(jq -nc --arg ip "$ip" '{records: [{value: $ip}]}')" \
      "$name $type aktualisiert: ${current:-(leer)} -> $ip" || return 1
  fi

  if [ -n "$TTL" ] && [ "$ttl" != "$TTL" ]; then
    action "$path/actions/change_ttl" "{\"ttl\": $TTL}" "$name $type TTL: $ttl -> $TTL" || return 1
  fi
}

rc=0
for v in 4 6; do
  enabled="IPV$v"
  [ "${!enabled}" = 1 ] || continue
  type=A; [ "$v" = 6 ] && type=AAAA
  if ! ip=$(public_ip "$v"); then
    err "Öffentliche IPv$v konnte nicht ermittelt werden"
    rc=1
    continue
  fi
  for name in "${RECORD_LIST[@]}"; do
    update "$(normalize "$name")" "$type" "$ip" || rc=1
  done
done
exit "$rc"
