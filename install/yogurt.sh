#!/usr/bin/env bash
# =============================================================================
#  🥣 Yogurt Private AI Meeting Server – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer
#
#  Lokale Meeting-Notizen im Stil von FrigadeHQ/yogurt (Open-Source,
#  MIT) – als SERVER statt Desktop-App: Yogurt selbst ist eine Electron-
#  Desktop-Anwendung und läuft nicht headless. Diese Variante überträgt
#  die Idee in den LXC:
#    • Meetings im Browser aufnehmen (Mikrofon, optional Tab-/System-Audio),
#      Audio-Datei hochladen oder Text einfügen
#    • lokal transkribieren (faster-whisper, CPU int8)
#    • lokal zusammenfassen (llama.cpp auf 127.0.0.1, Qwen3-GGUF)
#    • Notizen verwalten (React/Vite-UI) – KEINE Cloud, keine externen Dienste
#
#  Architektur im Container (Debian 13):
#    yogurt-meet-llama.service : llama-server (llama.cpp Release-Binary) auf 127.0.0.1:8081
#    yogurt-meet.service       : FastAPI + uvicorn, HTTPS :8097 (selbstsigniert,
#                                weil das Browser-Mikrofon einen Secure Context braucht)
#    App-Code wird bei JEDEM Install/Update als neuester main-Tarball aus
#    diesem Repo geladen – "immer das aktuelle Repo ziehen".
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 8192 --whisper small
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.4"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="yogurt"           # Kurzname (Logs, Services heißen yogurt-meet*)
CT_HOSTNAME="yogurt"        # CT bekommt den passenden Namen
REPO_OWNER="HatchetMan111"
REPO_REPO="Yogurt-PrivateAI-MeetingServer"
REPO_BRANCH="main"          # App-Quelle: IMMER neuester Stand dieses Branches
APP_TARBALL_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_REPO}/tar.gz/refs/heads/${REPO_BRANCH}"
APP_DIR="/opt/yogurt"       # Projektverzeichnis im Container (app/, venv/, llama/, tls/, data/)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_STORAGE="local-lvm"
CT_ROOTFS=32                # GB – Modelle (~2,2 GB) + venv + Audio-Daten
CT_CORES=4                  # Whisper + llama profitieren von Kernen
CT_MEMORY=6144              # MB – llama-server (1,7 GB GGUF + Kontext) + Whisper gleichzeitig
CT_SWAP=1024
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
# Host-Architektur bestimmt Template- UND llama.cpp-Binary-Auswahl.
# Live-Fund 2026-11-19 (ProxSmartHome): ohne Arch-Filter nahm die rV-Sortierung
# das arm64-Template (13.6) vor dem amd64-Template (13.2) → lxc_start-Fehler.
RAW_ARCH="$(uname -m 2>/dev/null || echo x86_64)"
HOST_ARCH=""; LLAMA_ARCH=""
case "$RAW_ARCH" in
    x86_64)          HOST_ARCH="amd64"; LLAMA_ARCH="x64" ;;
    aarch64|arm64)   HOST_ARCH="arm64"; LLAMA_ARCH="arm64" ;;
    *)               HOST_ARCH=""; LLAMA_ARCH="" ;;
esac
UI_PORT=8097                # Web-UI im Container (HTTPS, selbstsigniert)
LLM_PORT=8081               # llama-server – NUR localhost im CT (kein Expose)
WHISPER_MODEL="small"       # tiny|base|small|medium|large-v3|large-v3-turbo
WHISPER_LANG=""             # leer = automatisch erkennen; z. B. "de"
LLM_GGUF_URL="https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf"
LLM_MODEL_NAME="Qwen3-1.7B-Q8_0"   # nur Anzeige/API-Name
LLAMA_TAG=""                # leer = neuestes b-Release via GitHub-API (Fallback: LLAMA_TAG_FALLBACK)
LLAMA_TAG_FALLBACK="b12541" # geprüftes Release – falls die API mal nicht antwortet
LLAMA_RELEASES_API="https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10"
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Services), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Services):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/yogurt-setup.log 2>/dev/null
            echo "--- journalctl yogurt-meet-llama ---"
            journalctl -u yogurt-meet-llama --no-pager 2>/dev/null | tail -n 12 || true
            echo "--- journalctl yogurt-meet ---"
            journalctl -u yogurt-meet --no-pager 2>/dev/null | tail -n 12 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # Schneller Weg: `pct list`, Name ist (meist) die LETZTE Spalte
    local id
    id=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}' || true)
    if [[ -n "$id" ]]; then
        echo "$id"
        return 0
    fi
    # Fallback: Spaltenformat variiert zwischen PVE-Versionen → jede VMID
    # einzeln über `pct config` gegen den Hostname prüfen.
    local cand
    for cand in $(pct list 2>/dev/null | awk 'NR>1 {print $1}' || true); do
        if pct config "$cand" 2>/dev/null | grep -q "^hostname: ${CT_HOSTNAME}$"; then
            echo "$cand"
            return 0
        fi
    done
    return 0
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Modell-/Tarball-Downloads brauchen Namensauflösung.
    # 3 Erfolge in Folge verlangen; eine einzige Störung → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts huggingface.co >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals)
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts huggingface.co >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

resolve_llama_tag() {
    # Neuestes b-Release von ggml-org/llama.cpp (die `latest`-API liefert seit
    # v1.0.0 nur einen Metadaten-Eintrag ohne Binaries – deshalb Release-Liste).
    # Bei API-Problemen greift der geprüfte Fallback-Tag.
    if [[ -n "$LLAMA_TAG" ]]; then
        echo "$LLAMA_TAG"
        return 0
    fi
    local tag=""
    tag=$(curl -s --max-time 15 "$LLAMA_RELEASES_API" 2>/dev/null \
          | grep -o '"tag_name": *"b[0-9]\+"' | head -1 | grep -o 'b[0-9]\+' || true)
    if [[ -z "$tag" ]]; then
        tag="$LLAMA_TAG_FALLBACK"
    fi
    echo "$tag"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          UI_PORT="${args[$((i+1))]:-}"; FLAG_SETTINGS=1; i=$((i+2)) ;;
            --whisper)       WHISPER_MODEL="${args[$((i+1))]:-}"; FLAG_SETTINGS=1; i=$((i+2)) ;;
            --lang)          WHISPER_LANG="${args[$((i+1))]:-}"; FLAG_SETTINGS=1; i=$((i+2)) ;;
            --gguf-url)      LLM_GGUF_URL="${args[$((i+1))]:-}"; FLAG_SETTINGS=1; i=$((i+2)) ;;
            --llm-name)      LLM_MODEL_NAME="${args[$((i+1))]:-}"; FLAG_SETTINGS=1; i=$((i+2)) ;;
            --llama-tag)     LLAMA_TAG="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Validierung – die Werte landen direkt in der Container-Konfiguration.
    if [[ -z "$HOST_ARCH" ]]; then
        die "Nicht unterstützte Host-Architektur: '$RAW_ARCH' (amd64/arm64 erwartet)."
    fi
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger UI-Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 8097)"
    fi
    if [[ "$UI_PORT" == "$LLM_PORT" ]]; then
        die "UI-Port ($UI_PORT) und LLM-Port ($LLM_PORT) dürfen nicht identisch sein."
    fi
    case "$WHISPER_MODEL" in
        tiny|base|small|medium|large-v3|large-v3-turbo) ;;
        *) die "Unbekanntes Whisper-Modell: '$WHISPER_MODEL' (tiny|base|small|medium|large-v3|large-v3-turbo)" ;;
    esac
    if [[ "$LLM_GGUF_URL" != http://* && "$LLM_GGUF_URL" != https://* ]]; then
        die "Ungültige GGUF-URL: '$LLM_GGUF_URL' (muss mit http(s):// beginnen)"
    fi
}

print_help() {
    cat <<EOF
🥣 Yogurt Private AI Meeting Server – Proxmox-Installer (lokal: Aufnehmen → Transkribieren → Zusammenfassen)

Installation:   bash -c "\$(wget -qLO - https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_REPO}/main/install/yogurt.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: yogurt)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 32 – Modelle + Audio-Daten)
  --cores N        vCPUs (Default: 4)
  --memory MB      RAM (Default: 6144 – llama + Whisper gleichzeitig)
  --swap MB        Swap (Default: 1024)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                   Empfehlenswert: feste IP (oder DHCP-Reservierung), damit die
                   Browser-Verbindung (HTTPS/Mikrofon) dauerhaft stimmt.
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Web-UI-Port im Container (Default: 8097, HTTPS selbstsigniert)
  --whisper NAME   Whisper-Modell: tiny|base|small|medium|large-v3|large-v3-turbo (Default: small)
  --lang CODE      Transkriptionssprache festlegen (Default: auto), z. B. "de"
  --gguf-url URL   GGUF-Modell für die Zusammenfassung (Default: offizielles
                   Qwen3-1.7B-Q8_0, ~1,7 GB von huggingface.co/Qwen)
  --llm-name NAME  Anzeigename des LLM (Default: Qwen3-1.7B-Q8_0)
  --llama-tag TAG  llama.cpp-Release pinnen (Default: neuestes b-Release)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         App im bestehenden Container aktualisieren (holt IMMER den
                   neuesten main-Tarball dieses Repos; Modelle/Binary bleiben)
  --uninstall      Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte kommen als Umgebungsvariablen via `pct exec -- env …` in den
# Container (keine Escaping-Gruben). Aufgerufene Funktionen stehen VOR ihrer
# ersten Verwendung.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Yogurt Private AI Meeting Server – In-Container-Setup (idempotent, safe für
# Update & Re-Run). Variablen via env: APP_DIR, APP_TARBALL_URL, UI_PORT,
# LLM_PORT, WHISPER_MODEL, WHISPER_LANG, LLM_GGUF_URL, LLM_MODEL_NAME,
# LLaMA_TAG_RESOLVED, LLaMA_URL, HOST_DNS, APPLY_SETTINGS, YM_VERSION
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo -e "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
info(){ echo "ℹ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${APP_TARBALL_URL:?APP_TARBALL_URL fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"
: "${LLM_PORT:?LLM_PORT fehlt (env)}"
: "${WHISPER_MODEL:?WHISPER_MODEL fehlt (env)}"
: "${LLM_GGUF_URL:?LLM_GGUF_URL fehlt (env)}"
: "${LLAMA_TAG_RESOLVED:?LLAMA_TAG_RESOLVED fehlt (env)}"
: "${LLAMA_URL:?LLAMA_URL fehlt (env)}"

VENV_DIR="${APP_DIR}/venv"
LLAMA_DIR="${APP_DIR}/llama/${LLAMA_TAG_RESOLVED}"
DATA_DIR="${APP_DIR}/data"
MODELS_DIR="${DATA_DIR}/models"
TLS_DIR="${APP_DIR}/tls"
GGUF_FILE="${MODELS_DIR}/$(basename "${LLM_GGUF_URL%%\?*}")"
APPLY_SETTINGS="${APPLY_SETTINGS:-1}"

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Yogurt: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Basis-Pakete (ffmpeg, Python venv) ..."
apt-get update -qq
apt-get install -y -qq ffmpeg python3-venv python3-pip openssl >/dev/null
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg konnte nicht installiert werden – apt-Quellen prüfen (apt-get install ffmpeg)."

# ── dotenv-Helfer (idempotent; Nutzer-Änderungen bleiben erhalten) ──────────
dotenv_get() {
    local key=$1 line
    [[ -f "${APP_DIR}/app.env" ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "${APP_DIR}/app.env"
    return 0
}
dotenv_set() {
    local key=$1 value=$2 tmp="${APP_DIR}/.app.env.tmp.$$" line updated=false
    touch "${APP_DIR}/app.env"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "${APP_DIR}/app.env" > "$tmp"
    if [[ "$updated" != "true" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv -f "$tmp" "${APP_DIR}/app.env"
}

echo ">>> Neuesten App-Code ziehen (${APP_TARBALL_URL}) ..."
# "Immer das aktuelle Repo": bei Install UND Update den main-Tarball frisch
# laden. Swap-Muster mit Rollback (GNU-mv würde sonst INTO verschieben):
mkdir -p "$APP_DIR"
curl -fsSL --retry 3 "${APP_TARBALL_URL}" -o /tmp/yogurt-app.tar.gz
rm -rf /tmp/yogurt-app-src
mkdir -p /tmp/yogurt-app-src
tar -xzf /tmp/yogurt-app.tar.gz -C /tmp/yogurt-app-src
SRC_APP=$(find /tmp/yogurt-app-src -maxdepth 2 -type d -name app | head -1)
[[ -n "$SRC_APP" ]] || die "Tarball ohne app/-Verzeichnis – Repo-Struktur prüfen (${APP_TARBALL_URL})."
systemctl stop yogurt-meet >/dev/null 2>&1 || true
rm -rf "${APP_DIR}/app.old"
if [[ -d "${APP_DIR}/app" ]]; then
    mv "${APP_DIR}/app" "${APP_DIR}/app.old"
fi
mv "$SRC_APP" "${APP_DIR}/app"
rm -rf "${APP_DIR}/app.old" /tmp/yogurt-app-src /tmp/yogurt-app.tar.gz
ok "App-Code aktualisiert (Branch ${REPO_BRANCH:-main}, Stand $(date +%Y-%m-%d\ %H:%M))"
[[ -f "${APP_DIR}/app/backend/server.py" ]] || die "server.py fehlt im entpackten App-Verzeichnis."
[[ -d "${APP_DIR}/app/frontend/dist" ]] || die "frontend/dist fehlt – Repo enthält kein gebautes Frontend."

echo ">>> Python-venv + Abhängigkeiten ..."
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR" || die "venv-Erstellung fehlgeschlagen (python3-venv installiert?)."
fi
for attempt in 1 2 3; do
    if "$VENV_DIR/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 \
       && "$VENV_DIR/bin/pip" install --quiet -r "${APP_DIR}/app/backend/requirements.txt" >/dev/null 2>&1; then
        ok "Python-Abhängigkeiten installiert (Versuch $attempt)"
        break
    fi
    if [[ "$attempt" == 3 ]]; then
        "$VENV_DIR/bin/pip" install -r "${APP_DIR}/app/backend/requirements.txt" \
            || die "pip-Installation fehlgeschlagen (3 Versuche) – Fehler oben vollständig lesen."
    fi
    sleep 5
done

echo ">>> llama.cpp (${LLAMA_TAG_RESOLVED}) ..."
if [[ -x "${LLAMA_DIR}/llama-server" ]]; then
    ok "llama.cpp bereits vorhanden: ${LLAMA_DIR}/llama-server"
else
    mkdir -p "$LLAMA_DIR"
    curl -fsSL --retry 3 "${LLAMA_URL}" -o /tmp/llama.tar.gz
    tar -xzf /tmp/llama.tar.gz -C "$LLAMA_DIR" --strip-components=1
    rm -f /tmp/llama.tar.gz
    chmod +x "${LLAMA_DIR}/llama-server"
    [[ -x "${LLAMA_DIR}/llama-server" ]] || die "llama-server nach Entpacken nicht ausführbar (${LLAMA_DIR})."
    ok "llama.cpp installiert"
fi

echo ">>> GGUF-Modell (${LLM_MODEL_NAME}) ..."
mkdir -p "$MODELS_DIR"
if [[ -f "$GGUF_FILE" && $(stat -c%s "$GGUF_FILE") -gt 100000000 ]]; then
    ok "GGUF bereits vorhanden: $GGUF_FILE ($(du -h "$GGUF_FILE" | cut -f1))"
else
    info "Lade ${GGUF_FILE} ($(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1) bisher) ..."
    curl -fL --retry 3 --progress-bar "${LLM_GGUF_URL}" -o "${GGUF_FILE}.part"
    mv -f "${GGUF_FILE}.part" "$GGUF_FILE"
    ok "GGUF geladen ($(du -h "$GGUF_FILE" | cut -f1))"
fi

echo ">>> Whisper-Modell '${WHISPER_MODEL}' vorladen (einmalig, danach offline nutzbar) ..."
if "${VENV_DIR}/bin/python" -c "
import sys
from pathlib import Path
cache = Path('${MODELS_DIR}')
if any(cache.glob('*faster-whisper-${WHISPER_MODEL}*')):
    sys.exit(0)
sys.exit(1)
" >/dev/null 2>&1; then
    ok "Whisper-Modell bereits im Cache"
else
    YM_APP_DIR="$APP_DIR" YM_DATA_DIR="$DATA_DIR" YM_WHISPER_MODEL="$WHISPER_MODEL" YM_WHISPER_COMPUTE="int8" \
    "$VENV_DIR"/bin/python - <<'PYDL'
import os
from faster_whisper import WhisperModel
model = os.environ.get("YM_WHISPER_MODEL", "small")
WhisperModel(model, device="cpu", compute_type=os.environ.get("YM_WHISPER_COMPUTE", "int8"),
             download_root=os.path.join(os.environ["YM_DATA_DIR"], "models"))
print(f"Whisper-Modell '{model}' heruntergeladen")
PYDL
    ok "Whisper-Modell heruntergeladen"
fi

echo ">>> Selbstsigniertes TLS-Zertifikat (Browser-Mikrofon braucht HTTPS) ..."
mkdir -p "$TLS_DIR"
if [[ ! -f "${TLS_DIR}/cert.pem" || ! -f "${TLS_DIR}/key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/cert.pem" \
        -subj "/CN=yogurt" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1
    chmod 600 "${TLS_DIR}/key.pem"
    ok "TLS-Zertifikat erzeugt (${TLS_DIR})"
else
    ok "TLS-Zertifikat vorhanden"
fi

echo ">>> app.env schreiben (bestehende Werte bleiben erhalten) ..."
mkdir -p "$APP_DIR" "$DATA_DIR"
if [[ "$APPLY_SETTINGS" == "1" ]]; then
    dotenv_set YM_PORT "$UI_PORT"
    dotenv_set YM_LLM_PORT "$LLM_PORT"
    dotenv_set YM_WHISPER_MODEL "$WHISPER_MODEL"
    dotenv_set YM_WHISPER_LANG "$WHISPER_LANG"
    dotenv_set YM_LLM_MODEL_NAME "$LLM_MODEL_NAME"
else
    [[ -n "$(dotenv_get YM_PORT)" ]]             || dotenv_set YM_PORT "$UI_PORT"
    [[ -n "$(dotenv_get YM_LLM_PORT)" ]]         || dotenv_set YM_LLM_PORT "$LLM_PORT"
    [[ -n "$(dotenv_get YM_WHISPER_MODEL)" ]]    || dotenv_set YM_WHISPER_MODEL "$WHISPER_MODEL"
    [[ -n "$(dotenv_get YM_WHISPER_LANG)" ]]     || dotenv_set YM_WHISPER_LANG "$WHISPER_LANG"
    [[ -n "$(dotenv_get YM_LLM_MODEL_NAME)" ]]   || dotenv_set YM_LLM_MODEL_NAME "$LLM_MODEL_NAME"
fi
dotenv_set YM_APP_DIR "$APP_DIR"
dotenv_set YM_DATA_DIR "$DATA_DIR"
dotenv_set YM_VERSION "${YM_VERSION}"
dotenv_set YM_TLS_CERT "${TLS_DIR}/cert.pem"
dotenv_set YM_TLS_KEY "${TLS_DIR}/key.pem"
dotenv_set YM_WHISPER_COMPUTE "int8"
chmod 600 "${APP_DIR}/app.env"

echo ">>> systemd-Units schreiben ..."
cat > /etc/systemd/system/yogurt-meet-llama.service <<UNITEOF
[Unit]
Description=Yogurt Meetings – llama.cpp (lokale Zusammenfassung)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${LLAMA_DIR}
# Release-Binary linkt gegen .so-Dateien im eigenen Verzeichnis
Environment=LD_LIBRARY_PATH=${LLAMA_DIR}
ExecStart=${LLAMA_DIR}/llama-server --host 127.0.0.1 --port ${LLM_PORT} -m ${GGUF_FILE} --ctx-size 8192
Restart=always
RestartSec=5
# llama-server lädt das Modell beim Start (~10-30 s); Abfragen laufen über
# 127.0.0.1 – bewusst KEIN Expose in Richtung LAN.

[Install]
WantedBy=multi-user.target
UNITEOF
cat > /etc/systemd/system/yogurt-meet.service <<UNITEOF
[Unit]
Description=Yogurt Private AI Meeting Server (FastAPI, HTTPS :${UI_PORT})
Wants=network-online.target yogurt-meet-llama.service
After=network-online.target yogurt-meet-llama.service
EnvironmentFile=${APP_DIR}/app.env

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/app/backend
ExecStart=${VENV_DIR}/bin/python server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable yogurt-meet-llama yogurt-meet >/dev/null 2>&1 || true

echo ">>> Services (neu) starten ..."
systemctl restart yogurt-meet-llama
systemctl restart yogurt-meet

echo ">>> Warte auf llama-server (http://127.0.0.1:${LLM_PORT}/health, Modell-Ladezeit) ..."
LLM_OK=""
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${LLM_PORT}/health" || true)
    if [[ "$code" == "200" ]]; then LLM_OK=1; break; fi
    sleep 3
done
if [[ -z "$LLM_OK" ]]; then
    die "llama-server antwortet nicht mit 200 auf /health (letzter Code: ${code:-keiner}).\n  Debug: journalctl -u yogurt-meet-llama -e\n  Prüfe GGUF: ls -lh ${GGUF_FILE}"
fi
ok "llama-server gesund (Modell geladen)"

echo ">>> Warte auf Web-UI (https://127.0.0.1:${UI_PORT}/api/health, selbstsigniert → -k) ..."
UI_OK=""
for _ in $(seq 1 40); do
    code=$(curl -sk -o /dev/null --max-time 3 -w '%{http_code}' "https://127.0.0.1:${UI_PORT}/api/health" || true)
    if [[ "$code" == "200" ]]; then UI_OK=1; break; fi
    sleep 3
done
if [[ -z "$UI_OK" ]]; then
    echo ">>> Diagnose (Web-UI-API 000) – automatische Ausgabe:"
    echo "--- app.env (YM_*) ---"
    /bin/grep -E '^YM_(PORT|LLM_PORT|TLS_CERT|TLS_KEY)=' "${APP_DIR}/app.env" 2>/dev/null || echo "(app.env fehlt/leer)"
    echo "--- TLS-Dateien ---"
    ls -la "${TLS_DIR}/" 2>/dev/null || echo "(${TLS_DIR} fehlt)"
    echo "--- Unit yogurt-meet.service ---"
    systemctl cat yogurt-meet 2>/dev/null | /bin/grep -E 'EnvironmentFile|ExecStart|WorkingDirectory' || true
    echo "--- HTTP-Test (ohne TLS, muss 200 zeigen wenn uvicorn auf HTTP läuft) ---"
    curl -s -o /dev/null -w 'HTTP : %{http_code}\n' --max-time 3 "http://127.0.0.1:${UI_PORT}/api/health" || true
    echo "--- HTTPS-Test ---"
    curl -sk -o /dev/null -w 'HTTPS: %{http_code}\n' --max-time 3 "https://127.0.0.1:${UI_PORT}/api/health" || true
    echo "--- journalctl yogurt-meet (letzte 15) ---"
    journalctl -u yogurt-meet -n 15 --no-pager 2>/dev/null || true
    die "Web-UI-API antwortet nicht mit 200 (letzter Code: ${code:-keiner}).\n  Debug: journalctl -u yogurt-meet -e\n  curl -sk https://127.0.0.1:${UI_PORT}/api/health"
fi
ok "API gesund (HTTP 200)"
code=$(curl -sk -o /dev/null --max-time 3 -w '%{http_code}' "https://127.0.0.1:${UI_PORT}/" || true)
if [[ "$code" == "200" ]]; then
    ok "Frontend ausgeliefert (HTTP 200)"
else
    die "Frontend (/) liefert nicht 200 (Code: ${code:-keiner}).\n  Debug: ls ${APP_DIR}/app/frontend/dist"
fi

echo ">>> Aufräumen ..."
rm -f /tmp/yogurt-app.tar.gz

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Yogurt Meetings im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert)
    local host_dns
    host_dns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    local llama_tag llama_url
    llama_tag=$(resolve_llama_tag)
    llama_url="https://github.com/ggml-org/llama.cpp/releases/download/${llama_tag}/llama-${llama_tag}-bin-ubuntu-${LLAMA_ARCH}.tar.gz"
    info "llama.cpp-Release: ${llama_tag}"
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # APPLY_SETTINGS: bei Installation immer 1; bei Update nur 1, wenn die
    # zugehörigen Flags explizit genutzt wurden (Nutzer-Änderungen bleiben sonst).
    local apply=0
    if [[ "$MODE" == "install" || "${FLAG_SETTINGS:-0}" == "1" ]]; then
        apply=1
    fi
    # set -o pipefail: ein Crash im Inner-Script darf nicht durch `tee` maskiert werden.
    pct exec "$ct_id" -- env APP_DIR="$APP_DIR" APP_TARBALL_URL="$APP_TARBALL_URL" \
        UI_PORT="$UI_PORT" LLM_PORT="$LLM_PORT" \
        WHISPER_MODEL="$WHISPER_MODEL" WHISPER_LANG="$WHISPER_LANG" \
        LLM_GGUF_URL="$LLM_GGUF_URL" LLM_MODEL_NAME="$LLM_MODEL_NAME" \
        LLAMA_TAG_RESOLVED="$llama_tag" LLAMA_URL="$llama_url" \
        HOST_DNS="${host_dns:-1.1.1.1}" APPLY_SETTINGS="$apply" \
        YM_VERSION="$INSTALLER_VERSION" REPO_BRANCH="$REPO_BRANCH" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/yogurt-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Services aktiv?
    for svc in yogurt-meet-llama yogurt-meet; do
        tries=0
        while true; do
            if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
                ok "Service $svc läuft (systemctl is-active)"
                break
            fi
            tries=$((tries + 1))
            if [[ $tries -ge 30 ]]; then
                die "Service $svc läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u $svc -e"
            fi
            sleep 1
        done
    done

    # API + Frontend antworten? (HTTPS im CT; -k wegen selbstsigniertem Zert.
    # Grube: curl -w gibt bei Verbindungsfehler bereits 000 aus – NIEMALS
    # zusätzlich || echo 000 anhängen.)
    tries=0; code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -sk -o /dev/null --max-time 3 -w '%{http_code}' \
               "https://127.0.0.1:${UI_PORT}/api/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "API gesund (HTTP 200 auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "API antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- journalctl -u yogurt-meet -e"
        fi
        sleep 2
    done

    tries=0; code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -sk -o /dev/null --max-time 3 -w '%{http_code}' \
               "https://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI antwortet (HTTP 200 auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- ls /opt/yogurt/app/frontend/dist"
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                    "https://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: https://${ct_ip}:${UI_PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über https://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🥣 Yogurt Meetings ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:   https://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🐚 Terminal: pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:  ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer: v${INSTALLER_VERSION} (App: ${REPO_OWNER}/${REPO_REPO}@${REPO_BRANCH} – immer aktuell)${NC}"
    echo -e "  ${GREEN}  🧠 Modelle:  Whisper ${WHISPER_MODEL} + ${LLM_MODEL_NAME} (lokal, keine Cloud)${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. https://${ct_ip}:${UI_PORT} öffnen – der Browser zeigt eine"
    echo "     Zertifikats-WARUNG (selbstsigniert): „Erweitert → Weiter zu …“"
    echo "     bestätigen. Danach ist das Mikrofon frei (HTTPS = Secure Context)."
    echo "  2. „＋ Neues Meeting“ → 🎙️ Aufnahme starten (oder Datei/Text)"
    echo "  3. Nach dem Stopp: Transkript + Meeting-Notizen erscheinen automatisch."
    echo ""
    echo -e "  ${CYAN}Hinweise:${NC}"
    echo "  • Zusammenfassung läuft über llama.cpp NUR im Container (127.0.0.1:${LLM_PORT})."
    echo "  • Dauerhaftes Desktop-Mitschneiden wie die Yogurt-Desktop-App geht im"
    echo "    Browser nur als Tab-Audio (Option im Aufnahme-Tab) – oder Audio-Datei upload."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u yogurt-meet -u yogurt-meet-llama -e"
    echo ""
    warn "Daten (SQLite, Audio, Modelle) liegen unter /opt/yogurt/data im CT –"
    warn "ein --update erhält sie, pct destroy löscht sie. Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – empfohlen: DHCP-Reservierung im Router (oder --ip beim Install),"
        warn "damit die Browser-URL (und das Zertifikat-Zuhause) stabil bleibt."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    MODE="install"
    header "🥣 Installiere Yogurt Private AI Meeting Server (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen – IMMER in der Host-Architektur!
    # (13 bevorzugt für Python 3.13; rV-Sortierung nimmt 13 vor 12, Fallback bleibt.)
    # Live-Fund 2026-11-19: ohne Arch-Filter gewann debian-13.6-arm64 auf einem
    # amd64-Host → lxc_start "Failed to spawn". Deshalb: _${HOST_ARCH} erzwingen.
    header "🧱 Container-Template (${HOST_ARCH})"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' \
               | grep -oE "debian-1[23]-standard[^ ]*_${HOST_ARCH}[^ ]*" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-Template (${HOST_ARCH}) vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null \
                   | grep -oE "debian-1[23]-standard[^ ]*_${HOST_ARCH}[^ ]*" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard-Template für ${HOST_ARCH} gefunden.\n  Prüfe: pveam available --section system | grep ${HOST_ARCH}\n  und: uname -m (Host-Architektur: ${RAW_ARCH})"
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="yg-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID angelegt"

    # pct create meldet trotz FEHLGESCHLAGENEM Start Exit 0 (Live-Fund 2026-11-19,
    # ProxSmartHome: arm64-Template auf amd64-Host → lxc_start-Fehler, aber
    # "✔ erstellt und gestartet"). Laufenden CT daher explizit verifizieren:
    local running=false
    for _ in $(seq 1 15); do
        if pct status "$CT_ID" 2>/dev/null | grep -q "running"; then
            running=true
            break
        fi
        sleep 1
    done
    if ! $running; then
        warn "Container startete nicht automatisch – versuche pct start ..."
        pct start "$CT_ID" 2>&1 | tail -2 || true
        for _ in $(seq 1 20); do
            if pct status "$CT_ID" 2>/dev/null | grep -q "running"; then
                running=true
                break
            fi
            sleep 1
        done
    fi
    if ! $running; then
        die "Container $CT_ID startet NICHT (Template: ${template}, Host: ${RAW_ARCH}/${HOST_ARCH}).\n  Häufigste Ursache: Template-Architektur passt nicht zum Host (hier automatisch gefiltert) ODER Storage/Kapazität.\n  Debug: pct status $CT_ID; journalctl -u lxc@${CT_ID} -e | tail -30\n  Aufräumen: pct destroy $CT_ID --purge"
    fi
    ok "Container $CT_ID läuft"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    MODE="update"
    header "🔄 Update Yogurt Meetings (holt IMMER den neuesten App-Code aus dem Repo)"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        die "Kein Yogurt-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer).\n  Erst installieren:  ${ONE_LINER}\n  CT-ID explizit angeben:  ${ONE_LINER} --update --id 210"
    fi
    local ct_id="$CT_ID"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Daten (/opt/yogurt/data) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    MODE="uninstall"
    header "🗑️  Deinstalliere Yogurt Meetings"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        warn "Kein Yogurt-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer) – nichts zu tun."
        return 0
    fi
    local ct_id="$CT_ID"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Meetings, Transkripte, Audio, Modelle."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    MODE="status"
    header "📊 Status Yogurt Meetings"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        warn "Kein Yogurt-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer)."
        info "Installieren:  ${ONE_LINER}"
        info "CT-ID explizit:  ${ONE_LINER} --status --id 210"
        return 0
    fi
    local ct_id="$CT_ID"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Services/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    local svc
    for svc in yogurt-meet-llama yogurt-meet; do
        if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "Service:   $svc läuft (systemctl is-active)"
        else
            err "Service:   $svc läuft NICHT"
            info "Logs:      pct exec $ct_id -- journalctl -u $svc -e"
        fi
    done

    local whisper gguf ip code=""
    whisper=$(pct exec "$ct_id" -- sed -n 's/^YM_WHISPER_MODEL=//p' "${APP_DIR}/app.env" 2>/dev/null | head -1 || true)
    [[ -n "$whisper" ]] && info "Whisper:   $whisper"
    gguf=$(pct exec "$ct_id" -- sh -c 'ls -1 /opt/yogurt/data/models/*.gguf 2>/dev/null | head -1' 2>/dev/null || true)
    if [[ -n "$gguf" ]]; then
        info "LLM:       $(basename "$gguf") ($(pct exec "$ct_id" -- du -h "$gguf" 2>/dev/null | cut -f1 || true))"
    fi

    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${ip}:${UI_PORT}/api/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    https://${ip}:${UI_PORT}  (API HTTP 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von https://${ip}:${UI_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
# Modus + APPLY_SETTINGS-Marker VOR parse_args initialisieren (die Optionen
# dürfen FLAG_SETTINGS=1 setzen: bei --update überschreiben explizite Flags
# die app.env, ohne Flags bleiben Nutzer-Änderungen erhalten).
MODE="install"
FLAG_SETTINGS=0
parse_args "$@"

if $UPDATE; then
    MODE="update"
fi

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
