#!/usr/bin/env bash
# =============================================================================
#  🧪 Yogurt-PrivateAI-MeetingServer – Mock-Harness
#  Testet install/yogurt.sh End-to-End gegen gemockte Proxmox-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/sleep als Host-Mocks (Fakebin), python3/pip/systemctl/
#     apt-get/ffmpeg/hostname/getent/ip als Inner-Mocks
#   - Inner-Script läuft ECHT (nur Pfade auf Mock-Root umgeschrieben): Tarball-
#     Download, App-Swap, venv, llama.cpp, GGUF, Whisper-Preload, TLS, Units
#   - Fixtures: echte Tarballs (app + llama.cpp) und Sparse-GGUF (101 MB)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/yogurt.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/yogurt-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
FIX="$MK/fixtures"                   # Fixture-Tarballs (bleiben über Cases)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" "$FIX" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.42"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
# Fortsetzungsblöcke (ohne eigenen Installer-Lauf) prüfen gegen das Haupt-Log:
assert_main_out() {
    if [[ -n "${INSTALL_OUT:-}" ]] && /bin/grep -qF -- "$1" "$INSTALL_OUT" 2>/dev/null; then
        pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
# shellcheck disable=SC2329  # bewusst gehaltene Utility-Funktion
assert_main_no() {
    if [[ -n "${INSTALL_OUT:-}" ]] && /bin/grep -qF -- "$1" "$INSTALL_OUT" 2>/dev/null; then
        fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
# shellcheck disable=SC2329  # bewusst gehaltene Utility-Funktion
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    # -e statt -f: auch Verzeichnisse (z. B. Whisper-Cache-Marker) zulässig
    if [[ -e "$1" ]]; then pass "existiert: ${1#"$MK"/}"
    else fail "fehlt: ${1#"$MK"/}"; fi
}
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): ${1#"$MK"/}"
    else pass "Datei fehlt (korrekt): ${1#"$MK"/}"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "${1#"$MK"/} enthält: $2"
    else fail "${1#"$MK"/} enthält NICHT: $2"; fi
}
# shellcheck disable=SC2329  # bewusst gehaltene Utility-Funktion
assert_fnocontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then fail "${1#"$MK"/} enthält (sollte nicht): $2"
    else pass "${1#"$MK"/} enthält nicht: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "${1#"$MK"/} matcht: $2"
    else fail "${1#"$MK"/} matcht NICHT: $2"; fi
}
assert_calls() { # ≥COUNT needle im Mock-Calls-Log
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_calls_eq() { # ==COUNT needle
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" == "$want" ]]; then pass "Calls ==$want: $needle"
    else fail "Calls ==$want erwartet, ist $got: $needle"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
# shellcheck disable=SC2329  # Debug-Helfer für HARNESS_KEEP-Läufe
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 40 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 25 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id du find tar hostname
ln -sf "$MK/mock-uname" "$HOSTBIN/uname"
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN python3-Mock venv)
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln du find tar xargs gzip gunzip date
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-python3"   "$INNERBIN/python3"
ln -sf "$MK/mock-python3"   "$MK/mock-python3.bin" 2>/dev/null || true
# pip/python erscheinen erst durch den venv-Mock in bin/ – symlink dort aufs Mock

seed_inner_tools() { # simuliert bereits installierte Tools (Update-Pfad)
    ln -sf "$MK/mock-curl"    "$INNERBIN/curl"
    ln -sf "$MK/mock-python3" "$INNERBIN/python3"
    ln -sf "$MK/mock-ffmpeg"  "$INNERBIN/ffmpeg"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/python3" "$INNERBIN/ffmpeg"
}

# ══════════════════════════ Fixtures (echte Tarballs) ══════════════════════
mk_fixtures() {
    local appsrc="$MK/fixture-app-src/app"
    rm -rf "$MK/fixture-app-src"
    mkdir -p "$appsrc/backend" "$appsrc/frontend/dist"
    printf '#!/usr/bin/env python3\nprint("fixture")\n' > "$appsrc/backend/server.py"
    printf 'fastapi>=0.115\nfaster-whisper==1.2.1\n' > "$appsrc/backend/requirements.txt"
    printf '<!doctype html><html><body>fixture-dist</body></html>\n' > "$appsrc/frontend/dist/index.html"
    # --owner=0 --group=0: uid-1000-Dateien im User-Namespace nicht entpackbar
    tar --owner=0 --group=0 -czf "$FIX/app.tar.gz" -C "$MK/fixture-app-src" app

    local llsrc="$MK/fixture-llama-src/llama-b12541"
    rm -rf "$MK/fixture-llama-src"
    mkdir -p "$llsrc"
    printf '#!/usr/bin/env bash\necho "mock llama-server $*"\nexit 0\n' > "$llsrc/llama-server"
    chmod +x "$llsrc/llama-server"
    tar --owner=0 --group=0 -czf "$FIX/llama.tar.gz" -C "$MK/fixture-llama-src" "llama-b12541"
}
mk_fixtures

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
# uname-Mock: Host-Arch via Lever $HS/host_arch steuerbar (x86_64 | aarch64)
set -u
HS="${HARNESS_STATE:?}"
arch="x86_64"
[[ -f "$HS/host_arch" ]] && arch=$(/bin/sed -n 's/^//p' "$HS/host_arch")
if [[ "${1:-}" == "-m" ]]; then echo "$arch"; exit 0; fi
echo "Linux harness 6.8.0 mock ${arch} GNU/Linux"
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        echo "pct create $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$hostname" > "$HS/ct_${id}.hostname"
        if [[ -f "$HS/create_start_fail" ]]; then
            # Live-Fund 2026-11-19: pct create meldet Exit 0, Start schlug fehl
            echo "$id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${id}.status"
            exit 0
        fi
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        if [[ -f "$HS/start_fail" ]]; then echo "mock: Start fehlgeschlagen" >&2; exit 255; fi
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}.hostname"
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: /tmp/- und /etc/-Pfade auf Mock-Root umschreiben.
        # Reihenfolge WICHTIG: /tmp zuerst – die /etc-Ersetzung injiziert selbst
        # ein /tmp/ (Mock-Root liegt unter /tmp) und würde doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        # Quoted-Heredoc: INNERBIN erst zur LAUFZEIT ableiten ($MK = dirname($HS))
        # KEINE /tmp-Regel hier: MK liegt selbst unter /tmp – eine /tmp-Ersetzung
        # würde bereits umgeschriebene Pfade ($MK/root/…) doppelt umschreiben.
        # /tmp kommt ausschließlich im PUSH-Rewrite vor (Script-Inhalt, vor MK-Präfixen).
        INNERBIN="$MK/bin-inner"
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/yogurt/$MK/opt/yogurt}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    config)
        if [[ ! -f "$HS/ct_${id}.hostname" ]]; then
            echo "mock: CT $id unbekannt" >&2
            exit 2
        fi
        printf 'arch: amd64\ncores: 4\nhostname: %s\nonboot: 1\nunprivileged: 1\nfeatures: nesting=1,keyctl=1\n' "$(cat "$HS/ct_${id}.hostname")"
        exit 0 ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL="local:vztmpl/debian-13-standard_13.2-1_amd64.tar.zst"
TMPL_ARM="local:vztmpl/debian-13-standard_13.6-1_arm64.tar.zst"
have_arm() { [[ -f "$HS/arm64_only" || -f "$HS/arm64_too" ]]; }
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "$TMPL_ARM  999"; else echo "$TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "$TMPL_ARM  999"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "system          $TMPL_ARM  999"; else echo "system          $TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "system          $TMPL_ARM  999"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        # pveam download local <template> → Template ist $3!
        mkdir -p "$HS/templates"
        if [[ "${3:-}" == *arm64* ]]; then
            touch "$HS/templates/debian-13-standard_13.6-1_arm64.tar.zst"
        else
            touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
        fi
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: GitHub-API → Release-JSON; Tarball-URLs → Fixtures; GGUF → Sparse;
# Health-Checks → 200/000 je nach Lever (fail_api/fail_ui/fail_llm/host_curl_fail)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
FIX="$MK/fixtures"
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    *api.github.com/repos/ggml-org/llama.cpp/releases*)
        printf '{\n  "tag_name": "b12541",\n  "assets": [{"name": "llama-b12541-bin-ubuntu-x64.tar.gz"}]\n}\n'
        exit 0 ;;
    *codeload.github.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer*)
        [[ -n "$outfile" ]] || { echo "curl mock: tarball ohne -o" >&2; exit 1; }
        cp "$FIX/app.tar.gz" "$outfile"
        exit 0 ;;
    *releases/download/b*/llama-*-bin-ubuntu-*.tar.gz*)
        [[ -n "$outfile" ]] || { echo "curl mock: llama-tarball ohne -o" >&2; exit 1; }
        cp "$FIX/llama.tar.gz" "$outfile"
        exit 0 ;;
    *huggingface.co/*.gguf*)
        [[ -n "$outfile" ]] || { echo "curl mock: gguf ohne -o" >&2; exit 1; }
        /bin/truncate -s 104857601 "$outfile"
        exit 0 ;;
esac

# Health-/HTTP-Checks – host_curl_fail gilt NUR auf Host-Ebene (inner erkennt
# man an MKROOT)
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
case "$url" in
    */api/health*)  [[ -f "$HS/fail_api" ]] && code="000" ;;
    http://127.0.0.1:8081/health) [[ -f "$HS/fail_llm" ]] && code="000" ;;
esac
echo "$code"
[[ "$code" == "200" ]] && exit 0 || exit 7
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl-Mock (inner): zwei Yogurt-Services mit Active-Markern
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
unitdir="$MK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable) mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start)
        if [[ "${2:-}" == "yogurt-meet" ]]; then
            [[ -f "$unitdir/yogurt-meet.service" ]] || { echo "mock: unit fehlt" >&2; exit 1; }
            touch "$HS/yogurt_meet_active"
        elif [[ "${2:-}" == "yogurt-meet-llama" ]]; then
            [[ -f "$unitdir/yogurt-meet-llama.service" ]] || { echo "mock: unit fehlt" >&2; exit 1; }
            touch "$HS/yogurt_llama_active"
        fi
        exit 0 ;;
    stop)
        if [[ "${2:-}" == "yogurt-meet" ]]; then rm -f "$HS/yogurt_meet_active"; fi
        if [[ "${2:-}" == "yogurt-meet-llama" ]]; then rm -f "$HS/yogurt_llama_active"; fi
        exit 0 ;;
    restart)
        if [[ "${2:-}" == "yogurt-meet" ]]; then
            [[ -f "$unitdir/yogurt-meet.service" ]] || { echo "mock: unit yogurt-meet.service fehlt" >&2; exit 1; }
            touch "$HS/yogurt_meet_active"
        elif [[ "${2:-}" == "yogurt-meet-llama" ]]; then
            [[ -f "$unitdir/yogurt-meet-llama.service" ]] || { echo "mock: unit yogurt-meet-llama.service fehlt" >&2; exit 1; }
            touch "$HS/yogurt_llama_active"
        fi
        exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "yogurt-meet" && -f "$HS/yogurt_meet_active" ]]; then exit 0; fi
        if [[ "$svc" == "yogurt-meet-llama" && -f "$HS/yogurt_llama_active" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl/ffmpeg real in die Inner-Fakebin (Bootstrap-Reihenfolge)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
        if [[ "$a" == "ffmpeg" && ! -e "$INNERBIN_DIR/ffmpeg" ]]; then
            ln -sf "$MK/mock-ffmpeg" "$INNERBIN_DIR/ffmpeg"
        fi
        if [[ "$a" == "python3-venv" && ! -e "$INNERBIN_DIR/python3" ]]; then
            ln -sf "$MK/mock-python3" "$INNERBIN_DIR/python3"
        fi
    done
fi
exit 0
EOF

cat > "$MK/mock-ffmpeg" <<'EOF'
#!/usr/bin/env bash
echo "mock ffmpeg $*"; exit 0
EOF

cat > "$MK/mock-python3" <<'EOF'
#!/usr/bin/env bash
# python3-Mock: -m venv DIR erzeugt venv mit pip/python-Mocks;
# bin/python-Modus: -c = Whisper-Cache-Check (glob), stdin = "Download" (Marker)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
SELF="$MK/mock-python3"

if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    dir="${3:-}"
    [[ -n "$dir" ]] || exit 1
    mkdir -p "$dir/bin"
    ln -sf "$MK/mock-pip"    "$dir/bin/pip"
    ln -sf "$MK/mock-python3" "$dir/bin/python"
    exit 0
fi

# Von hier unter venv/bin/python aufgerufen?
case "${0##*/}" in
    python)
        if [[ "${1:-}" == "-c" ]]; then
            # Whisper-Cache-Check: Pfad aus dem -c-String extrahieren (…/models)
            p="${*: -1}"
            models_dir=$(printf '%s' "$p" | /bin/grep -oE "[^\"']*/models" | head -1)
            [[ -z "$models_dir" ]] && exit 1
            if /usr/bin/find "$models_dir" -maxdepth 1 -type d -name '*faster-whisper-*' 2>/dev/null | /bin/grep -q .; then
                exit 0
            fi
            exit 1
        fi
        # stdin-Modus (PYDL-Heredoc): "Modell herunterladen" → Cache-Verzeichnis anlegen
        data_dir="${YM_DATA_DIR:-}"
        model="${YM_WHISPER_MODEL:-small}"
        [[ -n "$data_dir" ]] || exit 1
        mkdir -p "$data_dir/models/models--Systran--faster-whisper-$model"
        echo "Whisper-Modell '$model' heruntergeladen (mock)"
        exit 0 ;;
esac

# Direkt als python3 aufgerufen (kein venv-Kontext): -c-Check genauso behandeln
if [[ "${1:-}" == "-c" ]]; then
    p="${*: -1}"
    models_dir=$(printf '%s' "$p" | /bin/grep -oE "[^\"']*/models" | head -1)
    [[ -z "$models_dir" ]] && exit 1
    if /usr/bin/find "$models_dir" -maxdepth 1 -type d -name '*faster-whisper-*' 2>/dev/null | /bin/grep -q .; then
        exit 0
    fi
    exit 1
fi
echo "mock python3: $*"; exit 0
EOF

cat > "$MK/mock-pip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pip $*" >> "$HS/calls.log"
# -r requirements-Pfad merken (Datei muss existieren – Repo-Tarball geprüft)
for a in "$@"; do
    if [[ -f "$a" ]]; then echo "pip: requirements gefunden: $a"; fi
done
exit 0
EOF

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" || -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "yogurt"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky (jeder 3. failt – nie 3 Erfolge in Folge) |
# fail_then_ok (9x fail, dann ok). Nach Fallback (resolv.conf enthält 1.1.1.1)
# antwortet der Mock immer ok.
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
if [[ -f "$MK/etc/resolv.conf" ]] && /bin/grep -q 'nameserver 1.1.1.1' "$MK/etc/resolv.conf"; then
    exit 0
fi
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 3)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    # AUCH das Mock-Root wipen (Oink-Grube): sonst leaken Dateien aus seed_ct
    # in die nächsten Install-Cases und Assertionen matchen alte Reste.
    rm -rf "$HS" "${MK:?}/opt" "${MK:?}/etc" "${MK:?}/root" "${MK:?}/var/log" "${MK:?}/tmp"
    mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    unseed_inner_tools
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
    # State-Snapshot für Post-Mortem (reset_state wipt zwischen Cases)
    cp -a "$MK/opt/yogurt" "$CUR_DIR/snap-opt" 2>/dev/null || true
    cp -a "$MK/etc/systemd/system" "$CUR_DIR/snap-units" 2>/dev/null || true
}
run_installer_as_arg0() { # Produktions-Pattern: bash -c "$(…)" --flag → $0 ist die Flag
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash -c "$(cat "$SCRIPT")" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_nonroot() {
    # OHNE unshare: Prozess läuft als uid 1000 (setpriv kann im -rm-Namespace
    # nicht auf 1000 mappen – nur uid 0 ist gemappt). Die EUID-Prüfung des
    # Installers greift VOR allem anderen, es wird nichts angefasst.
    ( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem Yogurt-Stack
    reset_state
    echo "200 running yogurt" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "yogurt" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/yogurt/app/backend" "$MK/opt/yogurt/app/frontend/dist" \
        "$MK/opt/yogurt/venv/bin" "$MK/opt/yogurt/llama/b12541" \
        "$MK/opt/yogurt/data/models" "$MK/opt/yogurt/data/audio" "$MK/opt/yogurt/tls" \
        "$MK/etc/systemd/system" "$MK/etc/dhcp" "$MK/var/log"
    printf 'fixture-server' > "$MK/opt/yogurt/app/backend/server.py"
    printf '<html>alt</html>' > "$MK/opt/yogurt/app/frontend/dist/index.html"
    printf 'fastapi>=0.115\n' > "$MK/opt/yogurt/app/backend/requirements.txt"
    ln -sf "$MK/mock-python3" "$MK/opt/yogurt/venv/bin/python"
    ln -sf "$MK/mock-pip"     "$MK/opt/yogurt/venv/bin/pip"
    printf '#!/usr/bin/env bash\necho mock-llama "$@"\n' > "$MK/opt/yogurt/llama/b12541/llama-server"
    chmod +x "$MK/opt/yogurt/llama/b12541/llama-server"
    /bin/truncate -s 104857601 "$MK/opt/yogurt/data/models/Qwen3-1.7B-Q8_0.gguf"
    mkdir -p "$MK/opt/yogurt/data/models/models--Systran--faster-whisper-small"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -keyout "$MK/opt/yogurt/tls/key.pem" -out "$MK/opt/yogurt/tls/cert.pem" \
        -subj "/CN=yogurt" >/dev/null 2>&1
    cat > "$MK/opt/yogurt/app.env" <<ENVF
YM_PORT=8097
YM_LLM_PORT=8081
YM_WHISPER_MODEL=tiny
YM_WHISPER_LANG=de
YM_LLM_MODEL_NAME=Qwen3-1.7B-Q8_0
YM_APP_DIR=$MK/opt/yogurt
YM_DATA_DIR=$MK/opt/yogurt/data
YM_TLS_CERT=$MK/opt/yogurt/tls/cert.pem
YM_TLS_KEY=$MK/opt/yogurt/tls/key.pem
ENVF
    touch "$MK/etc/systemd/system/yogurt-meet.service" "$MK/etc/systemd/system/yogurt-meet-llama.service"
    touch "$HS/yogurt_meet_active" "$HS/yogurt_llama_active" "$HS/template_downloaded"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    seed_inner_tools
}

# ══════════════════════════ Cases ═════════════════════════════════════════
echo "🧪 Yogurt-Installer-Harness gegen $SCRIPT"
echo

# ── Argumente & Modi ───────────────────────────────────────────────────────
t "root-check schlägt fehl (EUID≠0)"
ec=$(run_installer_nonroot "$@")
assert_exit 1 "$ec"
assert_out "Bitte als root ausführen"

t "--help zeigt Optionen und Einzeiler"
ec=$(run_installer --help)
assert_exit 0 "$ec"
assert_out "--id"
assert_out "Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh"
assert_out "--whisper"

t "unbekannte Option → die()"
ec=$(run_installer --falsch)
assert_exit 1 "$ec"
assert_out "Unbekannte Option: --falsch"

t "ungültiger Port → die()"
ec=$(run_installer --port abc)
assert_exit 1 "$ec"
assert_out "Ungültiger UI-Port"

t "UI-Port == LLM-Port → die()"
ec=$(run_installer --port 8081)
assert_exit 1 "$ec"
assert_out "dürfen nicht identisch sein"

t "unbekanntes Whisper-Modell → die()"
ec=$(run_installer --whisper xl)
assert_exit 1 "$ec"
assert_out "Unbekanntes Whisper-Modell"

t "ungültige GGUF-URL → die()"
ec=$(run_installer --gguf-url ftp://x)
assert_exit 1 "$ec"
assert_out "Ungültige GGUF-URL"

t "\$0-Fallback: bash -c \"…\" --status schlägt nicht still fehl"
ec=$(run_installer_as_arg0 --status)
assert_exit 0 "$ec"
assert_out "Kein Yogurt-Container gefunden"

# ── Status-Pfade ───────────────────────────────────────────────────────────
t "--status ohne CT → Hinweis, exit 0"
reset_state
ec=$(run_installer --status)
assert_exit 0 "$ec"
assert_out "Installieren:"
assert_out "raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh"

t "--status mit gestopptem CT → Hinweis, exit 0"
reset_state
echo "200 stopped yogurt" > "$HS/ct_list"
echo "stopped" > "$HS/ct_200.status"
echo "yogurt" > "$HS/ct_200.hostname"
ec=$(run_installer --status)
assert_exit 0 "$ec"
assert_out "nicht gestartet"
assert_out "pct start 200"

t "--status mit laufendem CT → Services + URL"
seed_ct
ec=$(run_installer --status)
assert_exit 0 "$ec"
assert_out "yogurt-meet läuft"
assert_out "yogurt-meet-llama läuft"
assert_out "Whisper:   tiny"
assert_out "https://$CT_IP:8097"
assert_out "Qwen3-1.7B-Q8_0.gguf"

# ── Install (Happy Path) ───────────────────────────────────────────────────
t "Install Happy Path: CT 200, Hostname, Boot-Flags"
reset_state
ec=$(run_installer)
INSTALL_OUT="$CUR_DIR/out.log"   # Fortsetzungsblöcke prüfen gegen dieses Log
assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 200"
assert_out "Container-IP: $CT_IP"
assert_fregex "$HS/ct_200.create" '--hostname yogurt'
assert_fregex "$HS/ct_200.create" '--onboot 1'
assert_fregex "$HS/ct_200.create" '--unprivileged 1'
assert_fregex "$HS/ct_200.create" '--features nesting=1,keyctl=1'
assert_fregex "$HS/ct_200.create" '--memory 6144'
assert_fregex "$HS/ct_200.create" '--rootfs local-lvm:32'

t "Install: Template-Fallback pveam download"
reset_state
ec=$(run_installer)
assert_exit 0 "$ec"
assert_calls 1 "pveam download local"
assert_calls 1 "pveam update"

t "Install: Bootstrap-Reihenfolge – apt installiert curl (nacktes Debian)"
reset_state
ec=$(run_installer)
assert_exit 0 "$ec"
assert_calls 1 "apt-get install -y -qq curl ca-certificates"
assert_calls 1 "apt-get install -y -qq ffmpeg python3-venv python3-pip openssl"

t "Install: App-Code aus Tarball entpackt (Backend + dist)"
assert_file "$MK/opt/yogurt/app/backend/server.py"
assert_file "$MK/opt/yogurt/app/backend/requirements.txt"
assert_file "$MK/opt/yogurt/app/frontend/dist/index.html"
assert_no_file "$MK/opt/yogurt/app.old"
assert_calls 1 "codeload.github.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer"

t "Install: venv + pip + Whisper-Preload-Marker"
assert_file "$MK/opt/yogurt/venv/bin/pip"
assert_file "$MK/opt/yogurt/venv/bin/python"
assert_calls 1 "pip install --quiet --upgrade pip"
assert_file "$MK/opt/yogurt/data/models/models--Systran--faster-whisper-small"

t "Install: llama.cpp-Release b12541 entpackt + ausführbar"
assert_file "$MK/opt/yogurt/llama/b12541/llama-server"
if [[ -x "$MK/opt/yogurt/llama/b12541/llama-server" ]]; then pass "llama-server ausführbar"; else fail "llama-server nicht ausführbar"; fi

t "Install: GGUF heruntergeladen (101 MB Sparse)"
assert_file "$MK/opt/yogurt/data/models/Qwen3-1.7B-Q8_0.gguf"
size=$(stat -c%s "$MK/opt/yogurt/data/models/Qwen3-1.7B-Q8_0.gguf" 2>/dev/null || echo 0)
if [[ "$size" -ge 104857600 ]]; then pass "GGUF-Größe ≥100 MB ($size)"; else fail "GGUF zu klein: $size"; fi

t "Install: TLS-Zertifikat erzeugt"
assert_file "$MK/opt/yogurt/tls/cert.pem"
assert_file "$MK/opt/yogurt/tls/key.pem"

t "Install: app.env korrekt gefüllt"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_PORT=8097"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_MODEL=small"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_LLM_PORT=8081"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_TLS_CERT="

t "Install: systemd-Units (llama nur localhost, FastAPI mit EnvironmentFile)"
assert_file "$MK/etc/systemd/system/yogurt-meet-llama.service"
assert_file "$MK/etc/systemd/system/yogurt-meet.service"
assert_fcontains "$MK/etc/systemd/system/yogurt-meet-llama.service" "--host 127.0.0.1 --port 8081"
assert_fregex "$MK/etc/systemd/system/yogurt-meet-llama.service" "-m .*Qwen3-1\.7B-Q8_0\.gguf"
assert_fregex "$MK/etc/systemd/system/yogurt-meet.service" "EnvironmentFile=.*app\.env"
assert_fcontains "$MK/etc/systemd/system/yogurt-meet.service" "Restart=always"
assert_fcontains "$MK/etc/systemd/system/yogurt-meet.service" "After=network-online.target yogurt-meet-llama.service"
assert_calls 1 "systemctl enable yogurt-meet-llama yogurt-meet"
if [[ -f "$HS/yogurt_meet_active" ]]; then pass "yogurt-meet aktiv"; else fail "yogurt-meet nicht aktiv"; fi
if [[ -f "$HS/yogurt_llama_active" ]]; then pass "yogurt-meet-llama aktiv"; else fail "yogurt-meet-llama nicht aktiv"; fi

t "Install: DNS-Hook gegen DHCP-Überschreiben"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"
assert_fcontains "$MK/etc/resolv.conf" "nameserver"

t "Install: Inner-Script mit pipefail-Wrapper ausgeführt (tee maskiert nicht)"
assert_calls 1 "set -o pipefail; bash /root/setup-inner.sh"

t "Install: Verifikation + Summary-Box mit URL & Einzeiler"
assert_main_out "Service yogurt-meet-llama läuft"
assert_main_out "Service yogurt-meet läuft"
assert_main_out "Container 200 läuft"
assert_main_out "API gesund (HTTP 200"
assert_main_out "Vom Host erreichbar: https://$CT_IP:8097"
assert_main_out "Web-UI:   https://$CT_IP:8097"
assert_main_out "Erweitert → Weiter zu"
assert_main_out "--update"
assert_main_out "Whisper small + Qwen3-1.7B-Q8_0"

t "Install mit Optionen: --id 210 --whisper medium --lang de --port 8099"
reset_state
ec=$(run_installer --id 210 --whisper medium --lang de --port 8099)
assert_exit 0 "$ec"
assert_fregex "$HS/ct_210.create" '--hostname yogurt'
assert_fcontains "$MK/opt/yogurt/app.env" "YM_PORT=8099"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_MODEL=medium"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_LANG=de"
assert_fregex "$MK/etc/systemd/system/yogurt-meet.service" "HTTPS :8099"
assert_file "$MK/opt/yogurt/data/models/models--Systran--faster-whisper-medium"

t "Install: bereits vorhandener CT → die mit Update-Hinweis"
seed_ct
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "Install --force: löscht vorhandenen CT und legt neu an"
seed_ct
ec=$(run_installer --force)
assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_fregex "$HS/ct_200.create" '--hostname yogurt'

t "Install: pct create schlägt fehl → on_error mit Fehlerkette + bash -x-Hinweis"
reset_state
touch "$HS/create_fail"
ec=$(run_installer)
assert_exit 255 "$ec"
assert_out "Installationsfehler – Exit-Code 255"
assert_out "Fehlgeschlagener Befehl"
assert_out "--debug"

t "Install: pct create Exit 0, aber Start gescheitert → Retry + die() mit Diagnose (Live-Fund arm64)"
reset_state
touch "$HS/create_start_fail" "$HS/start_fail"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "Container startete nicht automatisch"
assert_out "startet NICHT"
assert_out "journalctl -u lxc@200"
assert_calls 1 "pct start 200"

t "Install: nur arm64-Template vorhanden, amd64-Host → die() mit Arch-Hinweis"
reset_state
touch "$HS/arm64_only"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "Kein debian-12/13-standard-Template für amd64 gefunden"
assert_out "uname -m"

t "Install: arm64-Host → wählt arm64-Template und arm64-llama-Binary"
reset_state
printf 'aarch64\n' > "$HS/host_arch"
touch "$HS/arm64_too"
ec=$(run_installer)
assert_exit 0 "$ec"
assert_fregex "$HS/ct_200.create" 'TEMPLATE=local:vztmpl/debian-13-standard_13\.6-1_arm64'
assert_calls 1 "llama-b12541-bin-ubuntu-arm64.tar.gz"
assert_out "Container-Template (arm64)"

t "Install: kein Template verfügbar → die()"
reset_state
touch "$HS/pveam_empty"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "Kein debian-12/13-standard-Template für amd64 gefunden"

t "Install: Netzwerk-Poll schlägt fehl → die() mit Diagnose"
reset_state
touch "$HS/no_ip"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "keine IP bekommen"

t "Install: DNS komplett tot → Fallback-Nameserver + dhclient-Hook, dann Erfolg"
reset_state
echo "getent_mode=fail_then_ok" > "$HS/getent_mode"
ec=$(run_installer)
assert_exit 0 "$ec"
assert_out "DNS im Container defekt – schreibe Fallback-Nameserver"
assert_fcontains "$MK/etc/resolv.conf" "nameserver 1.1.1.1"

t "Install: flaky DNS (nie 3 Erfolge) → ebenfalls Fallback"
reset_state
echo "getent_mode=flaky" > "$HS/getent_mode"
ec=$(run_installer)
assert_exit 0 "$ec"
assert_out "Fallback-Nameserver"

t "Install: API-Health bleibt 000 → die() mit journalctl-Hinweis"
reset_state
touch "$HS/fail_api"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "Web-UI-API antwortet nicht"
assert_out "journalctl -u yogurt-meet"

t "Install: llama-Health bleibt 000 → die() mit Debug-Hinweis"
reset_state
touch "$HS/fail_llm"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "llama-server antwortet nicht"
assert_out "journalctl -u yogurt-meet-llama"

t "Install: Host-Check schlägt fehl → warn, aber Installation bleibt grün"
reset_state
touch "$HS/host_curl_fail"
ec=$(run_installer)
assert_exit 0 "$ec"
assert_out "vom Proxmox-Host nicht erreichbar"

t "Install: pct exec stirbt beim Netz-Poll → die() mit Diagnose (kein stiller Abbruch)"
reset_state
touch "$HS/exec_fail"
ec=$(run_installer)
assert_exit 1 "$ec"
assert_out "keine IP bekommen"
assert_out "ip a"

# ── Update-Pfade ───────────────────────────────────────────────────────────
t "Update Happy Path: zieht IMMER aktuellen Tarball, Modelle bleiben"
seed_ct
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_calls 1 "codeload.github.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer"
assert_calls_eq 0 "progress-bar https://huggingface.co"                     # GGUF nicht neu geladen
assert_calls_eq 0 "curl -fsSL --retry 3 https://github.com/ggml-org"       # llama.cpp nicht neu geladen
assert_file "$MK/opt/yogurt/app/backend/server.py"
assert_no_file "$MK/opt/yogurt/app.old"
assert_out "Update abgeschlossen – Daten"

t "Update: Nutzer-Änderungen in app.env bleiben ohne Flags erhalten"
seed_ct
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_MODEL=tiny"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_LANG=de"

t "Update mit Flags: Einstellungen werden übernommen"
seed_ct
ec=$(run_installer --update --whisper base --port 8100)
assert_exit 0 "$ec"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_WHISPER_MODEL=base"
assert_fcontains "$MK/opt/yogurt/app.env" "YM_PORT=8100"

t "Update: gestoppter CT wird selbst gestartet"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s|^200 .*|200 stopped yogurt|" "$HS/ct_list"
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped)"

t "Update: Whisper-Cache-Check spart Download (Marker vorhanden)"
seed_ct
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_calls_eq 0 "Whisper-Modell heruntergeladen"

t "Update ohne CT → die() mit Install-Hinweis"
reset_state
ec=$(run_installer --update)
assert_exit 1 "$ec"
assert_out "Kein Yogurt-Container gefunden"
assert_out "Erst installieren"

# ── Uninstall ──────────────────────────────────────────────────────────────
t "Uninstall --yes: CT gestoppt + gelöscht"
seed_ct
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_calls 1 "pct stop 200"
assert_calls 1 "pct destroy 200 --purge"
if [[ ! -f "$HS/ct_200.status" ]]; then pass "CT-Status entfernt"; else fail "CT 200 noch vorhanden"; fi

t "Uninstall ohne Bestätigung (nicht-interaktiv) → nichts gelöscht"
seed_ct
ec=$(run_installer_devnull --uninstall)
assert_exit 1 "$ec"
assert_out "nichts gelöscht"
assert_no_calls "pct destroy"

t "Uninstall ohne CT → Hinweis, exit 0"
reset_state
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_out "nichts zu tun"

# ══════════════════════════ Ergebnis ══════════════════════════════════════
echo
echo "════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
    echo "✅ ALLE CASES GRÜN: $PASSED Assertions bestanden"
    exit 0
else
    echo "❌ $FAILED Assertions FEHLGESCHLAGEN ($PASSED bestanden)"
    echo "   (HARNESS_KEEP=1 bash harness/run.sh behält Mock-Root: $MK)"
    exit 1
fi
