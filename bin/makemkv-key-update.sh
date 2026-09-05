#!/bin/zsh
# makemkv-key-update.sh — holt den aktuellen MakeMKV-Beta-Key und traegt ihn ein.
#
# Warum: Der Beta-Key laeuft rund alle 60 Tage ab; ohne gueltigen Key steht der
# Blu-ray-Zweig von dvd-rip-m5.sh. Gekauft werden kann er nicht — der Shop des
# Herstellers ist geschlossen ("one cannot purchase MakeMKV for a moment").
#
# Aufruf: makemkv-key-update.sh [--dry-run]
# Exit:   0 = Key aktuell oder erfolgreich erneuert, 1 = Fehler (Meldung faellig)

set -u
setopt PIPE_FAIL 2>/dev/null || set -o pipefail

SETTINGS="${MAKEMKV_SETTINGS:-$HOME/Library/MakeMKV/settings.conf}"
LOG="${MAKEMKV_KEY_LOG:-$HOME/CoworkProjects/logs/makemkv-key.log}"
HASS_ENV="${HASS_ENV:-$HOME/CoworkProjects/.hass-env}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

# Meldung nur im Fehlerfall — ueber HA-Telegram, wenn die .hass-env am Host liegt.
melden() {
  log "MELDUNG: $*"
  [ -r "$HASS_ENV" ] || { log "keine .hass-env — Meldung nur im Log"; return 0; }
  # shellcheck disable=SC1090
  . "$HASS_ENV"
  [ -n "${HASS_URL:-}" ] && [ -n "${HASS_TOKEN:-}" ] || { log "hass-env unvollstaendig"; return 0; }
  curl -sS -m 15 -X POST "${HASS_URL%/}/api/services/telegram_bot/send_message" \
    -H "Authorization: Bearer $HASS_TOKEN" -H "Content-Type: application/json" \
    -d "$(printf '{"message":"MakeMKV-Key: %s"}' "$*")" >/dev/null 2>&1 \
    || log "Telegram-Meldung fehlgeschlagen"
}

# --- 1. Key holen -----------------------------------------------------------
# Primaer der maschinenlesbare Spiegel, Fallback der Forum-Thread des Autors.
# Der Spiegel blockt Abrufe ohne Browser-User-Agent mit HTTP 403.
key_holen() {
  local k
  k=$(curl -sS -m 20 -A "$UA" 'https://cable.ayra.ch/makemkv/api.php?raw' 2>/dev/null | tr -d '[:space:]')
  if key_gueltig "$k"; then printf '%s' "$k"; return 0; fi
  log "Spiegel lieferte keinen brauchbaren Key — Fallback Forum"
  k=$(curl -sS -m 30 -A "$UA" 'https://forum.makemkv.com/forum/viewtopic.php?f=5&t=1053' 2>/dev/null \
      | tr -d '\r' \
      | grep -oE 'T-[A-Za-z0-9@_]{58,80}' \
      | head -1)
  if key_gueltig "$k"; then printf '%s' "$k"; return 0; fi
  return 1
}

# Format des Beta-Keys: 'T-' plus Base64-artiger Rumpf. Ein HTML-Fehlerdokument
# oder eine leere Antwort faellt hier durch, statt eine gute Datei zu zerstoeren.
key_gueltig() {
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1" | grep -qE '^T-[A-Za-z0-9@_]{58,80}$'
}

KEY=$(key_holen) || { melden "kein Key abrufbar (Spiegel und Forum)"; exit 1; }
log "Key abgerufen: ${KEY:0:12}… (${#KEY} Zeichen)"

# --- 2. Vergleich mit dem eingetragenen Key ---------------------------------
ALT=""
if [ -f "$SETTINGS" ]; then
  ALT=$(grep -E '^[[:space:]]*app_Key[[:space:]]*=' "$SETTINGS" | tail -1 \
        | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
fi

if [ "$KEY" = "$ALT" ]; then
  log "unveraendert — nichts zu tun"
  exit 0
fi

if [ "$DRY" -eq 1 ]; then
  log "dry-run: wuerde ${ALT:-<leer>} durch ${KEY:0:12}… ersetzen"
  printf 'dry-run: neuer Key %s\n' "$KEY"
  exit 0
fi

# --- 3. Eintragen, mit Backup vorher ----------------------------------------
mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
  cp -p "$SETTINGS" "$SETTINGS.BAK-$(date '+%Y-%m-%d-%H%M')" || { melden "Backup fehlgeschlagen"; exit 1; }
  if grep -qE '^[[:space:]]*app_Key[[:space:]]*=' "$SETTINGS"; then
    # grep -v liefert Exit 1, wenn NICHTS uebrig bleibt — das ist der Normalfall
    # bei einer settings.conf, die nur die app_Key-Zeile enthaelt, und kein Fehler.
    # Nur Exit >1 ist ein echtes Lese-/Schreibproblem.
    grep -vE '^[[:space:]]*app_Key[[:space:]]*=' "$SETTINGS" >"$SETTINGS.neu"
    rc=$?
    [ "$rc" -le 1 ] || { melden "Schreiben fehlgeschlagen"; exit 1; }
  else
    cat "$SETTINGS" >"$SETTINGS.neu"
  fi
else
  : >"$SETTINGS.neu"
fi
printf 'app_Key = "%s"\n' "$KEY" >>"$SETTINGS.neu"
mv "$SETTINGS.neu" "$SETTINGS" || { melden "Ersetzen fehlgeschlagen"; exit 1; }

# --- 4. Zurueckgelesen pruefen ----------------------------------------------
NEU=$(grep -E '^[[:space:]]*app_Key[[:space:]]*=' "$SETTINGS" | tail -1 \
      | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
if [ "$NEU" != "$KEY" ]; then
  melden "Datei enthaelt nach dem Schreiben nicht den neuen Key"
  exit 1
fi
log "eingetragen in $SETTINGS (vorher: ${ALT:-<leer>})"

# --- 5. Funktionsprobe, soweit ohne Scheibe moeglich ------------------------
# makemkvcon meldet den Registrierungszustand beim Start. Ein Treffer auf
# expired/evaluation ist ein echter Fehler; alles andere wird nicht bewertet,
# weil ohne eingelegte Scheibe kein vollstaendiger Lauf moeglich ist.
MMC="${MAKEMKVCON:-/Applications/MakeMKV.app/Contents/MacOS/makemkvcon}"
if [ -x "$MMC" ]; then
  PROBE=$("$MMC" -r --cache=1 info disc:9999 2>&1 | head -40)
  if printf '%s' "$PROBE" | grep -qiE 'expired|evaluation period|registration key'; then
    melden "Key eingetragen, aber makemkvcon meldet weiterhin ein Registrierungsproblem"
    log "$PROBE"
    exit 1
  fi
  log "Funktionsprobe ohne Registrierungsfehler"
else
  log "makemkvcon nicht unter $MMC — Funktionsprobe uebersprungen"
fi

exit 0
