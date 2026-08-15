#!/bin/sh
# claude-doctor.sh — Startdiagnose fuer Claude Code auf macOS
#
# Rein lesend: aendert, loescht und installiert nichts.
# Jeder Schritt laeuft mit Timeout, das Skript kann also nicht selbst haengen.
# Ergebnis landet in ~/claude-doctor.txt und wird am Ende ausgegeben.

OUT="$HOME/claude-doctor.txt"
: > "$OUT"

say() { printf '%s\n' "$*" >> "$OUT"; }
hr()  { say ""; say "=== $* ==="; }

# Befehl mit Timeout ausfuehren, Ausgabe (stdout+stderr) in den Report.
# $1 = Sekunden, Rest = Befehl
run_t() {
  _secs=$1; shift
  _tmp=$(mktemp /tmp/cdoc.XXXXXX)
  say "\$ $*"
  ( "$@" </dev/null >"$_tmp" 2>&1 ) &
  _pid=$!
  ( sleep "$_secs"; kill -9 "$_pid" 2>/dev/null ) &
  _watch=$!
  wait "$_pid" 2>/dev/null; _rc=$?
  kill -9 "$_watch" 2>/dev/null
  if [ "$_rc" -ge 128 ]; then
    say "  >>> HAENGT / ABGEBROCHEN nach ${_secs}s (rc=$_rc)  <<<"
  else
    say "  (rc=$_rc)"
  fi
  sed 's/^/  /' "$_tmp" >> "$OUT"
  rm -f "$_tmp"
}

hr "1. Umgebung"
say "Datum:  $(date)"
say "System: $(uname -a)"
say "macOS:  $(sw_vers -productVersion 2>/dev/null)"
say "SHELL=$SHELL"
say "TERM=$TERM"
say "TMUX=${TMUX:-<nicht in tmux>}"
say "TERM_PROGRAM=${TERM_PROGRAM:-}"
say "PATH=$PATH"
say "claude gefunden unter:"
command -v -a claude 2>/dev/null | sed 's/^/  /' >> "$OUT"
say "node: $(node -v 2>&1)"

hr "2. Binary antwortet?"
run_t 25 claude --version

hr "3. Headless-Start (Kern ohne Oberflaeche)"
run_t 90 claude -p "sag nur: ok"

hr "4. Start ohne MCP-Server"
run_t 90 claude --strict-mcp-config --mcp-config '{"mcpServers":{}}' -p "sag nur: ok"

hr "5. Debug-Start (letzte 60 Zeilen)"
_dbg=$(mktemp /tmp/cdoc.XXXXXX)
( claude --debug -p "sag nur: ok" </dev/null >"$_dbg" 2>&1 ) &
_p=$!
( sleep 90; kill -9 "$_p" 2>/dev/null ) &
_w=$!
wait "$_p" 2>/dev/null; _rc=$?
kill -9 "$_w" 2>/dev/null
[ "$_rc" -ge 128 ] && say "  >>> HAENGT nach 90s — letzte Zeilen zeigen, worauf gewartet wird <<<"
tail -n 60 "$_dbg" | sed 's/^/  /' >> "$OUT"
rm -f "$_dbg"

hr "6. Konfiguration (Groessen)"
for f in "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
  if [ -f "$f" ]; then
    say "$(ls -lh "$f" | awk '{print $5"  "$9}')"
  else
    say "fehlt: $f"
  fi
done
say "Inhalt ~/.claude (oberste Ebene):"
ls -lh "$HOME/.claude" 2>/dev/null | sed 's/^/  /' >> "$OUT"

hr "7. Hooks und MCP-Server (Namen/Kommandos, Secrets geschwaerzt)"
python3 - "$HOME" >> "$OUT" 2>&1 <<'PY'
import json, os, sys
home = sys.argv[1]

def load(p):
    try:
        with open(p) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except Exception as e:
        print(f"  {p}: nicht lesbar ({e})")
        return None

for p in (f"{home}/.claude/settings.json", f"{home}/.claude/settings.local.json"):
    d = load(p)
    if not d:
        continue
    print(f"  {p}")
    hooks = d.get("hooks") or {}
    if not hooks:
        print("    hooks: keine")
    for event, entries in hooks.items():
        for entry in (entries if isinstance(entries, list) else [entries]):
            for h in (entry.get("hooks") or [entry]) if isinstance(entry, dict) else []:
                cmd = str(h.get("command", h))[:200]
                print(f"    hook {event}: {cmd}")
    env = d.get("env") or {}
    if env:
        print(f"    env-Keys: {', '.join(env)}")

d = load(f"{home}/.claude.json") or {}
servers = d.get("mcpServers") or {}
print(f"  ~/.claude.json: {len(servers)} MCP-Server global")
for name, cfg in servers.items():
    cmd = cfg.get("command") or cfg.get("url") or cfg.get("type") or "?"
    print(f"    - {name}: {str(cmd)[:120]}")
projs = d.get("projects") or {}
print(f"  ~/.claude.json: {len(projs)} Projekt-Eintraege")
for name, cfg in projs.items():
    s = (cfg or {}).get("mcpServers") or {}
    if s:
        print(f"    {name}: {', '.join(s)}")
PY

hr "8. Gatekeeper / Quarantaene"
run_t 15 xattr -l /opt/homebrew/bin/claude
run_t 15 ls -l /opt/homebrew/bin/claude

hr "9. Laufende claude-Prozesse (evtl. Altlasten, die blockieren)"
ps ax -o pid,etime,stat,command 2>/dev/null | grep -i "[c]laude" | sed 's/^/  /' >> "$OUT"

# Sicherheitsnetz: moegliche Tokens im Report schwaerzen
sed -i '' -E \
  -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-REDACTED/g' \
  -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1REDACTED/g' \
  -e 's/(ey[A-Za-z0-9_-]{10,})\.[A-Za-z0-9._-]+/JWT-REDACTED/g' \
  "$OUT" 2>/dev/null

printf '\n----- Report: %s -----\n\n' "$OUT"
cat "$OUT"
printf '\n----- Ende. Diesen Text zurueckschicken. -----\n'
