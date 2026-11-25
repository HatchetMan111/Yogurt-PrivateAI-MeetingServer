#!/usr/bin/env python3
# =============================================================================
#  🎙️ Yogurt Private AI Meeting Server – Backend (FastAPI)
#  Lokale Meeting-Notizen im Stil von FrigadeHQ/yogurt – aber als Server:
#  Audio im Browser aufnehmen → lokal transkribieren (faster-whisper) →
#  lokal zusammenfassen (llama.cpp auf 127.0.0.1) → Notizen verwalten.
#  Keine Cloud, keine externen Dienste – alles läuft in diesem Container.
# =============================================================================
import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile, Request, BackgroundTasks
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
import httpx

# ── Konfiguration (per Environment, gesetzt vom Installer) ──────────────────
APP_DIR = Path(os.environ.get("YM_APP_DIR", "/opt/yogurt/app"))
DATA_DIR = Path(os.environ.get("YM_DATA_DIR", "/opt/yogurt/data"))
LLM_PORT = int(os.environ.get("YM_LLM_PORT", "8081"))
WHISPER_MODEL = os.environ.get("YM_WHISPER_MODEL", "small")
WHISPER_LANG = os.environ.get("YM_WHISPER_LANG", "").strip()  # leer = Auto-Erkennung
WHISPER_COMPUTE = os.environ.get("YM_WHISPER_COMPUTE", "int8")
LLM_MODEL_NAME = os.environ.get("YM_LLM_MODEL_NAME", "local")
VERSION = os.environ.get("YM_VERSION", "1.0.0")

DB_PATH = DATA_DIR / "meetings.db"
AUDIO_DIR = DATA_DIR / "audio"
FRONTEND_DIR = APP_DIR / "frontend" / "dist"
MODELS_DIR = DATA_DIR / "models"
MODEL_DIRS = {
    "tiny": "Systran/faster-whisper-tiny",
    "base": "Systran/faster-whisper-base",
    "small": "Systran/faster-whisper-small",
    "medium": "Systran/faster-whisper-medium",
    "large-v3": "Systran/faster-whisper-large-v3",
    "large-v3-turbo": "Systran/faster-whisper-large-v3-turbo",
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("yogurt-meet")

AUDIO_DIR.mkdir(parents=True, exist_ok=True)
MODELS_DIR.mkdir(parents=True, exist_ok=True)

# ── Datenbank ────────────────────────────────────────────────────────────────
SCHEMA = """
CREATE TABLE IF NOT EXISTS meetings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT DEFAULT '',
    status TEXT DEFAULT 'queued',
    source TEXT DEFAULT 'audio',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    duration_s REAL DEFAULT 0,
    audio_path TEXT DEFAULT '',
    text_input TEXT DEFAULT '',
    transcript TEXT DEFAULT '',
    summary TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    language TEXT DEFAULT '',
    whisper_model TEXT DEFAULT '',
    llm_model TEXT DEFAULT '',
    error TEXT DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_meetings_created ON meetings(created_at DESC);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT DEFAULT ''
);
"""

def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db() -> None:
    with db() as conn:
        conn.executescript(SCHEMA)

init_db()

def get_setting(key: str, default: str = "") -> str:
    with db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default

def set_setting(key: str, value: str) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")

def row_to_dict(row: sqlite3.Row, detail: bool = True) -> dict:
    d = {
        "id": row["id"],
        "title": row["title"],
        "status": row["status"],
        "source": row["source"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "duration_s": row["duration_s"],
        "language": row["language"],
        "whisper_model": row["whisper_model"],
        "llm_model": row["llm_model"],
        "has_summary": bool(row["summary"]),
        "has_notes": bool(row["notes"]),
        "has_transcript": bool(row["transcript"]),
        "has_audio": bool(row["audio_path"]),
    }
    if detail:
        d.update({
            "transcript": row["transcript"],
            "summary": row["summary"],
            "notes": row["notes"],
            "error": row["error"],
        })
    else:
        # kompakte Vorschau für Karten in der Listenansicht
        src_text = row["summary"] or row["transcript"] or row["text_input"] or ""
        d["preview"] = re.sub(r"\s+", " ", src_text).strip()[:140]
    return d

# ── Whisper (lazy geladen, einmal pro Prozess) ───────────────────────────────
_whisper = None
_whisper_loaded_name = None
_whisper_lock = threading.Lock()
_transcribe_semaphore = threading.Semaphore(1)  # eine Transkription gleichzeitig (CPU)

def get_whisper():
    global _whisper, _whisper_loaded_name
    with _whisper_lock:
        if _whisper is None:
            from faster_whisper import WhisperModel  # schwerer Import erst bei Bedarf
            log.info("Lade Whisper-Modell '%s' (compute=%s) ...", WHISPER_MODEL, WHISPER_COMPUTE)
            _whisper = WhisperModel(
                WHISPER_MODEL, device="cpu", compute_type=WHISPER_COMPUTE,
                download_root=str(MODELS_DIR),
            )
            _whisper_loaded_name = WHISPER_MODEL
            log.info("Whisper-Modell geladen.")
        return _whisper

def whisper_model_cached() -> bool:
    # Installer pre-lädt das Modell (HF-Cache-Layout: models--Systran--faster-whisper-*)
    return any(MODELS_DIR.glob(f"*faster-whisper-{WHISPER_MODEL}*"))

# ── llama.cpp (OpenAI-kompatible API auf 127.0.0.1) ──────────────────────────
_llm_ready_cache = {"ok": False, "checked": 0.0}

def llm_ready(force: bool = False) -> bool:
    # Ergebnis 10 s cachen – Health-Endpoint wird oft gepollt
    if not force and (time.time() - _llm_ready_cache["checked"]) < 10:
        return _llm_ready_cache["ok"]
    ok = False
    try:
        base = llm_base_url()
        r = httpx.get(f"{base}/models", timeout=3)
        ok = r.status_code == 200
    except Exception:
        ok = False
    _llm_ready_cache["ok"] = ok
    _llm_ready_cache["checked"] = time.time()
    return ok

def llm_base_url() -> str:
    """LLM-Base-URL aus Settings oder Env."""
    provider = get_setting("llm_provider", "local")
    if provider == "openrouter":
        return "https://openrouter.ai/api/v1"
    elif provider == "ollama":
        return get_setting("ollama_url", "http://127.0.0.1:11434").rstrip("/") + "/v1"
    return f"http://127.0.0.1:{LLM_PORT}"

def llm_api_key() -> str:
    """API-Key für OpenRouter (leer = kein Key nötig)."""
    return get_setting("openrouter_api_key", "")

def llm_model_name() -> str:
    """Modellname aus Settings oder Env."""
    provider = get_setting("llm_provider", "local")
    if provider == "openrouter":
        return get_setting("openrouter_model", "openai/gpt-4o-mini")
    elif provider == "ollama":
        return get_setting("ollama_model", "llama3.2")
    return LLM_MODEL_NAME

def llm_chat(system: str, user: str, max_tokens: int = 1400) -> str:
    payload = {
        "model": llm_model_name(),
        "temperature": 0.2,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    headers = {}
    key = llm_api_key()
    if key:
        headers["Authorization"] = f"Bearer {key}"
    base = llm_base_url()
    r = httpx.post(f"{base}/chat/completions",
                   json=payload, timeout=600, headers=headers)
    r.raise_for_status()
    data = r.json()
    content = data["choices"][0]["message"]["content"]
    # manche Modelle packen <think>…</think> um die Antwort (Qwen3) – entfernen
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    return content

def summarize_transcript(transcript: str, source: str) -> str:
    system = (
        "Du bist ein präziser Assistent für Meeting-Notizen. Antworte immer auf "
        "Deutsch im Markdown-Format mit genau diesen Abschnitten:\n"
        "## Zusammenfassung\n(kurz, 3–6 Sätze)\n"
        "## Entscheidungen\n(Stichpunkte; „keine“ wenn keine erkennbar)\n"
        "## Aufgaben\n(Checkliste `- [ ] …` mit Verantworlichem, falls erkennbar; sonst „keine“)\n"
        "## Offene Punkte\n(Stichpunkte, was unklar/unklärt ist; sonst „keine“)"
    )
    hint = "Audiotranskript" if source == "audio" else "Notiztext"
    user = f"Erstelle die Meeting-Notizen aus dem folgenden {hint}:\n\n{transcript[:60000]}"
    return llm_chat(system, user, max_tokens=1400)

def generate_title(transcript: str) -> str:
    system = "Du vergibst prägnante Meeting-Titel. Antworte NUR mit dem Titel, max. 6 Wörter, ohne Anführungszeichen."
    return llm_chat(system, transcript[:4000], max_tokens=40).strip().strip('"„“').strip()[:80]

# ── Audio-/Text-Pipeline (Hintergrundthreads) ────────────────────────────────
executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="ym-pipeline")

def fmt_ts(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"

def update(conn: sqlite3.Connection, meeting_id: int, **fields) -> None:
    fields["updated_at"] = now_iso()
    sets = ", ".join(f"{k} = ?" for k in fields)
    conn.execute(f"UPDATE meetings SET {sets} WHERE id = ?", (*fields.values(), meeting_id))

def run_pipeline(meeting_id: int, skip_transcribe: bool = False) -> None:
    conn = db()
    try:
        row = conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
        if row is None:
            return
        # ── Stufe 1: Transkript beschaffen ──
        if row["source"] == "audio" and skip_transcribe and (row["transcript"] or "").strip():
            # Re-Summarize: vorhandenes Transkript wiederverwenden (kein Re-Transkribieren)
            transcript = row["transcript"]
        elif row["source"] == "audio":
            conn.execute("UPDATE meetings SET status = 'transcribing', updated_at = ? WHERE id = ?",
                         (now_iso(), meeting_id))
            conn.commit()
            wav = AUDIO_DIR / f"meeting-{meeting_id}.wav"
            src = Path(row["audio_path"])
            if not shutil.which("ffmpeg"):
                raise RuntimeError("ffmpeg nicht gefunden – Installation prüfen (apt: ffmpeg).")
            conv = subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                 "-ar", "16000", "-ac", "1", str(wav)],
                capture_output=True, text=True, timeout=7200,
            )
            if conv.returncode != 0:
                raise RuntimeError(f"ffmpeg-Konvertierung fehlgeschlagen: {conv.stderr[-800:]}")
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", str(wav)],
                capture_output=True, text=True, timeout=60,
            )
            duration = float(probe.stdout.strip()) if probe.stdout.strip() else 0.0
            with _transcribe_semaphore:
                model = get_whisper()
                kwargs = {"vad_filter": True, "beam_size": 3}
                if WHISPER_LANG:
                    kwargs["language"] = WHISPER_LANG
                segments, info = model.transcribe(str(wav), **kwargs)
                parts, detected = [], ""
                for seg in segments:
                    detected = info.language or ""
                    parts.append(f"[{fmt_ts(seg.start)}] {seg.text.strip()}")
            transcript = "\n\n".join(parts) if parts else "(leere Aufnahme – kein Spracherkennungsergebnis)"
            update(conn, meeting_id, transcript=transcript, duration_s=round(duration, 1),
                   language=detected)
            conn.commit()
        elif row["source"] == "text":
            transcript = row["text_input"].strip()
            if not transcript:
                raise RuntimeError("Kein Text übergeben.")
            update(conn, meeting_id, transcript=transcript)
            conn.commit()
        else:
            transcript = (row["transcript"] or "").strip()
            if not transcript:
                raise RuntimeError("Weder Transkript noch Audio/Text vorhanden.")

        # ── Stufe 2: Zusammenfassen (llama.cpp) ──
        if not llm_ready(force=True):
            update(conn, meeting_id, status="done",
                   error="Hinweis: llama-server nicht erreichbar – nur Transkript gespeichert.")
            conn.commit()
            return
        conn.execute("UPDATE meetings SET status = 'summarizing', updated_at = ? WHERE id = ?",
                     (now_iso(), meeting_id))
        conn.commit()
        summary = summarize_transcript(transcript, row["source"])
        fields = {"summary": summary, "llm_model": LLM_MODEL_NAME, "error": ""}
        if not (row["title"] or "").strip():
            try:
                fields["title"] = generate_title(transcript)
            except Exception as te:
                log.warning("Titel-Generierung fehlgeschlagen: %s", te)
        update(conn, meeting_id, status="done", **fields)
        conn.commit()
        log.info("Meeting %d fertig verarbeitet.", meeting_id)
    except Exception as exc:  # noqa: BLE001 – komplette Fehlerkette in die DB
        log.exception("Pipeline für Meeting %d fehlgeschlagen", meeting_id)
        try:
            update(conn, meeting_id, status="error",
                   error=f"{type(exc).__name__}: {exc}")
            conn.commit()
        except Exception:
            log.exception("Konnte Fehlerstatus nicht schreiben")
    finally:
        conn.close()

# ── FastAPI ──────────────────────────────────────────────────────────────────
app = FastAPI(title="Yogurt Private AI Meeting Server", version=VERSION,
              docs_url="/api/docs", openapi_url="/api/openapi.json")

MAX_TEXT = 200_000

@app.get("/api/health")
def health():
    return JSONResponse({
        "ok": True,
        "version": VERSION,
        "whisper_model": WHISPER_MODEL,
        "whisper_loaded": _whisper is not None,
        "whisper_cached": whisper_model_cached(),
        "llm_port": LLM_PORT,
        "llm_ready": llm_ready(force=False),
        "lang": WHISPER_LANG or "auto",
    })

@app.get("/api/config")
def config():
    return JSONResponse({
        "whisper_model": WHISPER_MODEL,
        "whisper_lang": WHISPER_LANG or "auto",
        "llm_port": LLM_PORT,
        "llm_model": LLM_MODEL_NAME,
        "version": VERSION,
        "data_dir": str(DATA_DIR),
    })

# ── Einstellungen (LLM-Provider, Whisper-Modell, etc.) ───────────────────────
@app.get("/api/settings")
def get_settings():
    return JSONResponse({
        "llm_provider": get_setting("llm_provider", "local"),
        "ollama_url": get_setting("ollama_url", "http://127.0.0.1:11434"),
        "ollama_model": get_setting("ollama_model", "llama3.2"),
        "openrouter_api_key": get_setting("openrouter_api_key", ""),
        "openrouter_model": get_setting("openrouter_model", "openai/gpt-4o-mini"),
        "whisper_model": get_setting("whisper_model", WHISPER_MODEL),
        "whisper_lang": get_setting("whisper_lang", WHISPER_LANG or "auto"),
        "available_providers": ["local", "ollama", "openrouter"],
        "llm_ready": llm_ready(force=False),
        "llm_model_active": llm_model_name(),
    })

@app.put("/api/settings")
def put_settings(body: dict):
    allowed = {
        "llm_provider": None,
        "ollama_url": None,
        "ollama_model": None,
        "openrouter_api_key": None,
        "openrouter_model": None,
        "whisper_model": None,
        "whisper_lang": None,
    }
    for k, v in body.items():
        if k in allowed:
            set_setting(k, str(v))
    # Whisper-Modell-Wechsel: Cache leeren (nur beim nächsten Meeting neu geladen)
    if "whisper_model" in body:
        global _whisper, _whisper_loaded_name
        _whisper = None
        _whisper_loaded_name = None
    return get_settings()

@app.get("/api/meetings")
def list_meetings():
    with db() as conn:
        rows = conn.execute("SELECT * FROM meetings ORDER BY id DESC").fetchall()
    return JSONResponse([row_to_dict(r, detail=False) for r in rows])

@app.post("/api/meetings/upload")
async def upload_meeting(
    request: Request,
    file: UploadFile = File(...),
    title: str = Form(default=""),
):
    ext = Path(file.filename or "audio.webm").suffix.lower() or ".webm"
    if ext not in {".webm", ".ogg", ".mp3", ".m4a", ".wav", ".mp4", ".opus", ".flac", ".aac"}:
        ext = ".webm"
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO meetings (title, status, source, created_at, updated_at) VALUES (?,?,?,?,?)",
            ((title or "").strip(), "queued", "audio", now_iso(), now_iso()),
        )
        meeting_id = cur.lastrowid
    audio_path = AUDIO_DIR / f"meeting-{meeting_id}-src{ext}"
    with audio_path.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            out.write(chunk)
    if audio_path.stat().st_size == 0:
        audio_path.unlink(missing_ok=True)
        with db() as conn:
            conn.execute("DELETE FROM meetings WHERE id = ?", (meeting_id,))
        raise HTTPException(400, "Datei ist leer.")
    with db() as conn:
        conn.execute("UPDATE meetings SET audio_path = ?, updated_at = ? WHERE id = ?",
                     (str(audio_path), now_iso(), meeting_id))
    # Sofort antworten – Verarbeitung läuft im Hintergrund (BackgroundTasks).
    # Bei langen Audio-Dateien (50s+) dauert Whisper auf CPU mehrere Minuten;
    # ein synchroner Request würde Browser/Proxy-Timeouts auslösen.
    bg = BackgroundTasks()
    bg.add_task(run_pipeline, meeting_id)
    return JSONResponse({"id": meeting_id, "status": "queued"}, background=bg)

@app.post("/api/meetings/text")
def text_meeting(body: dict, background_tasks: BackgroundTasks):
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "Feld 'text' darf nicht leer sein.")
    if len(text) > MAX_TEXT:
        raise HTTPException(413, f"Text zu lang (>{MAX_TEXT} Zeichen).")
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO meetings (title, status, source, created_at, updated_at, text_input) "
            "VALUES (?,?,?,?,?,?)",
            ((body.get("title") or "").strip(), "queued", "text", now_iso(), now_iso(), text),
        )
        meeting_id = cur.lastrowid
    background_tasks.add_task(run_pipeline, meeting_id)
    return JSONResponse({"id": meeting_id, "status": "queued"})

@app.get("/api/meetings/{meeting_id}")
def get_meeting(meeting_id: int):
    with db() as conn:
        row = conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Meeting nicht gefunden.")
    return JSONResponse(row_to_dict(row))

@app.delete("/api/meetings/{meeting_id}")
def delete_meeting(meeting_id: int):
    with db() as conn:
        row = conn.execute("SELECT audio_path FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Meeting nicht gefunden.")
        conn.execute("DELETE FROM meetings WHERE id = ?", (meeting_id,))
    for p in [row["audio_path"], str(AUDIO_DIR / f"meeting-{meeting_id}.wav")]:
        if p:
            try:
                Path(p).unlink(missing_ok=True)
            except OSError:
                pass
    return JSONResponse({"deleted": meeting_id})

@app.patch("/api/meetings/{meeting_id}")
def patch_meeting(meeting_id: int, body: dict):
    fields = {}
    if "title" in body:
        fields["title"] = (body["title"] or "").strip()[:200]
    if "notes" in body:
        if len(body["notes"] or "") > MAX_TEXT:
            raise HTTPException(413, "Notizen zu lang.")
        fields["notes"] = body["notes"] or ""
    if not fields:
        raise HTTPException(400, "Nichts zu ändern (title/notes erwartet).")
    with db() as conn:
        cur = conn.execute(
            f"UPDATE meetings SET {', '.join(f'{k} = ?' for k in fields)}, updated_at = ? "
            "WHERE id = ?", (*fields.values(), now_iso(), meeting_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(404, "Meeting nicht gefunden.")
    return get_meeting(meeting_id)

@app.post("/api/meetings/{meeting_id}/resummarize")
def resummarize(meeting_id: int, background_tasks: BackgroundTasks):
    with db() as conn:
        row = conn.execute("SELECT transcript FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Meeting nicht gefunden.")
        if not (row["transcript"] or "").strip():
            raise HTTPException(409, "Kein Transkript vorhanden.")
    background_tasks.add_task(run_pipeline, meeting_id, True)
    return JSONResponse({"id": meeting_id, "status": "queued"})

@app.get("/api/meetings/{meeting_id}/audio")
def meeting_audio(meeting_id: int):
    with db() as conn:
        row = conn.execute("SELECT audio_path FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
    if row is None or not row["audio_path"]:
        raise HTTPException(404, "Kein Audio vorhanden.")
    p = Path(row["audio_path"])
    if not p.exists():
        raise HTTPException(404, "Audio-Datei fehlt auf der Platte.")
    return FileResponse(p, media_type="audio/webm", filename=p.name)

def meeting_to_markdown(row: sqlite3.Row) -> str:
    title = (row["title"] or "").strip() or f"Meeting #{row['id']}"
    meta = [
        f"- **Datum:** {row['created_at'][:19].replace('T', ' ')}",
        f"- **Dauer:** {fmt_ts(row['duration_s'])}",
        f"- **Quelle:** {'Audio' if row['source'] == 'audio' else 'Text'}"
        f" (Whisper: {row['whisper_model'] or WHISPER_MODEL}, LLM: {row['llm_model'] or LLM_MODEL_NAME})",
    ]
    lines = [f"# {title}", "", *meta, ""]
    if row["summary"]:
        lines += ["## Meeting-Notizen", "", row["summary"], ""]
    if row["notes"]:
        lines += ["## Eigene Notizen", "", row["notes"], ""]
    if row["transcript"]:
        lines += ["## Transkript", "", row["transcript"], ""]
    return "\n".join(lines)

@app.get("/api/meetings/{meeting_id}/export")
def export_meeting(meeting_id: int):
    with db() as conn:
        row = conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Meeting nicht gefunden.")
    md = meeting_to_markdown(row)
    fname = f"meeting-{meeting_id}.md"
    if (row["title"] or "").strip():
        slug = re.sub(r"[^a-zA-Z0-9-_]+", "-", row["title"]).strip("-").lower()[:60] or fname
        fname = f"{slug}.md"
    return PlainTextResponse(md, media_type="text/markdown; charset=utf-8",
                             headers={"Content-Disposition": f'attachment; filename="{fname}"'})

# ── Statische Frontend-Dateien (dist, committed im Repo) ─────────────────────
if FRONTEND_DIR.exists():
    app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="spa")
else:
    @app.get("/")
    def no_frontend():
        return PlainTextResponse("Frontend dist fehlt (" + str(FRONTEND_DIR) + ") – Installer prüfen.", status_code=500)

if __name__ == "__main__":
    import uvicorn

    # TLS: Env-Werte nutzen, sonst auf die Installer-Default-Pfade fallen.
    # (Live-2026-11-22: Env kam nicht durch → Default-Pfade als Fallback, damit
    #  das Mikrofon im Browser unabhängig von app.env/systemd sauber per HTTPS läuft.)
    tls_cert = os.environ.get("YM_TLS_CERT", "").strip() or "/opt/yogurt/tls/cert.pem"
    tls_key = os.environ.get("YM_TLS_KEY", "").strip() or "/opt/yogurt/tls/key.pem"
    ssl_args: dict = {}
    if os.path.isfile(tls_cert) and os.path.isfile(tls_key):
        ssl_args = {"ssl_certfile": tls_cert, "ssl_keyfile": tls_key}
        log.info("TLS aktiv (%s) – Mikrofon braucht den Secure Context", tls_cert)
    else:
        log.warning(
            "KEIN TLS: Zert-Dateien fehlen (%s / %s) – Server lauscht auf HTTP, "
            "das Browser-Mikrofon funktioniert dann NICHT. Installer liefert /opt/yogurt/tls/*.",
            tls_cert, tls_key,
        )
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("YM_PORT", "8097")),
        **ssl_args,
    )
