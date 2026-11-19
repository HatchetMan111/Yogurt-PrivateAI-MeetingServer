# 🥣 Yogurt Private AI Meeting Server

**Lokale Meeting-Notizen im Stil von [FrigadeHQ/yogurt](https://github.com/FrigadeHQ/yogurt) – als Server statt Desktop-App.**
Yogurt selbst ist eine Electron-Desktop-Anwendung (kein Server, kein Port) – dieser Installer überträgt die Idee
in einen Proxmox-LXC: **Meetings im Browser aufnehmen → lokal transkribieren → lokal zusammenfassen → Notizen verwalten.**

Komplett lokal: **keine Cloud, keine API-Keys, keine externen Dienste.** Whisper und das LLM laufen im Container.

---

## Einzeiler-Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)"
```

Mit Optionen (hinter dem schließenden Anführungszeichen anhängen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)" --id 210 --memory 8192
```

Das Script (Community-Scripts-Stil):

- erstellt einen **unprivilegierten LXC** (Debian 13, Standard: 4 vCPU, 6 GB RAM, 32 GB Disk, Hostname `yogurt`, onboot=1, nächste freie ID ab 200)
- lädt bei **jedem Install & Update den neuesten `main`-Tarball dieses Repos** – „immer das aktuelle Repo ziehen“
- installiert faster-whisper + llama.cpp (offizielles Release-Binary) + Modell (Qwen3-1.7B-Q8_0, ~1,7 GB) im Container
- richtet **systemd-Services** (`yogurt-meet-llama`, `yogurt-meet`) mit `Restart=always` ein
- verifiziert selbst: Service aktiv, API + Web-UI antworten, vom Host erreichbar
- gibt die finale URL aus; bei Fehlern die **komplette Fehlerkette** + `--debug`-Hinweis

## Web-UI

`https://<CT-IP>:8097` — modernes React/Vite-Frontend (dunkles Theme, mobiltauglich):

- **🎙️ Aufnehmen** – Mikrofon, optional zusätzlich **Tab-/System-Audio** (Online-Meeting im Browser mitschneiden)
- **📁 Datei hochladen** – bestehende Aufnahmen (WebM/MP3/M4A/OGG/WAV/MP4 …)
- **📝 Text einfügen** – Protokoll/Transkript ohne Audio zusammenfassen
- Meeting-Notizen als Markdown (**Zusammenfassung / Entscheidungen / Aufgaben / Offene Punkte**), Transkript mit Zeitstempel,
  eigene Notizen, Export (Markdown-Download), Neu-Zusammenfassen, Suche
- Titel-Vorschlag per KI, wenn kein Titel gesetzt ist

### ⚠️ Browser-Warnung ist normal (selbstsigniertes HTTPS)

Das **Browser-Mikrofon braucht einen Secure Context** – über `http://IP` blockiert Chrome/Firefox die Aufnahme komplett.
Deshalb served der Server HTTPS mit einem vom Installer erzeugten selbstsignierten Zertifikat:

> Browser-Warnung → **„Erweitert“ → „Weiter zu … (unsicher)“** bestätigen → Mikrofon-Berechtigung erteilen.

Danach funktioniert Aufnahme, Upload und UI normal. Wer möchte: eigenes Zertifikat in
`/opt/yogurt/tls/cert.pem` + `key.pem` legen und `systemctl restart yogurt-meet` – oder hinter einen Reverse-Proxy mit
echtem Zertifikat hängen.

## Was im Container läuft

| Service | Port | Zweck |
|---|---|---|
| `yogurt-meet` | **8097** (0.0.0.0, HTTPS) | FastAPI + Web-UI (React/Vite, `dist` committed) |
| `yogurt-meet-llama` | 8081 (**nur 127.0.0.1**) | llama.cpp `llama-server`, Qwen3-GGUF für die Zusammenfassung |

- **Transkription:** faster-whisper (`small`, int8, CPU; `tiny`…`large-v3-turbo` wählbar)
- **Zusammenfassung:** Qwen3-1.7B-Q8_0 (offizielles Qwen-GGUF von Hugging Face; eigene GGUF-URL per `--gguf-url`)
- **Daten:** `/opt/yogurt/data` (SQLite, Audio, Modelle) – bleibt bei `--update` erhalten

## Wichtige Optionen

```
--id ID            Container-ID (Default: nächste freie ab 200)
--hostname NAME    CT-Name (Default: yogurt)
--cores N          vCPUs (Default: 4)
--memory MB        RAM (Default: 6144)
--rootfs GB        Disk (Default: 32 – Modelle + Audio)
--port PORT        Web-UI-Port (Default: 8097)
--ip CIDR          feste IP statt DHCP (+ --gateway)
--whisper NAME     tiny|base|small|medium|large-v3|large-v3-turbo (Default: small)
--lang CODE        Transkriptionssprache (Default: auto), z. B. "de"
--gguf-url URL     eigenes LLM-GGUF (Default: Qwen3-1.7B-Q8_0)
--llama-tag TAG    llama.cpp-Release pinnen
--force            vorhandenen CT löschen und neu anlegen
--yes              Rückfragen überspringen
--debug            voller bash -x-Trace
```

## Update / Status / Deinstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)" --update     # holt IMMER neuesten App-Code; Daten & Modelle bleiben
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)" --status
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Yogurt-PrivateAI-MeetingServer/main/install/yogurt.sh)" --uninstall # ALLE Daten weg!
```

Backups: `pct backup <ID> / vzdump`. Logs: `pct exec <ID> -- journalctl -u yogurt-meet -u yogurt-meet-llama -e`.

## Reboot-Verhalten

CT startet automatisch (`onboot: 1`), beide Services laufen mit `Restart=always` +
`After=network-online.target` wieder hoch; llama-server lädt das Modell beim Start (~10–30 s).

## Lokale Entwicklung

```bash
# Frontend (Node 18+)
cd app/frontend && npm install && npm run build   # dist/ wird committed – kein Node im CT nötig

# Backend (Python 3.11+, für Tests ohne echte Modelle)
cd app/backend && python3 -m venv venv && venv/bin/pip install -r requirements.txt
YM_APP_DIR=$PWD/app YM_DATA_DIR=/tmp/ym-data venv/bin/python server.py
```

## Tests

```bash
bash harness/run.sh   # Mock-Harness (unshare-NS): 152 Assertions über alle Modi & Fehlerpfade
```

Getestet: Install (Happy Path + alle `die()`-Pfade), Update (Tarball-Refresh, app.env-Erhaltung, gestoppter CT),
Uninstall, Status, `$0`-Fallback, DNS-Fallback (tot/flaky), Fehlerketten.

## Lizenz

MIT – inspiriert von [FrigadeHQ/yogurt](https://github.com/FrigadeHQ/yogurt) (MIT).
