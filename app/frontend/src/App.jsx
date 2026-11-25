import React, { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { api, uploadWithProgress } from './api.js'
import { renderMarkdown } from './md.js'
import { startRecording, fmtClock } from './recorder.js'
import './styles.css'

// ── Hash-Routing (#/, #/new, #/meeting/5) ────────────────────────────────────
function useHash() {
  const [hash, setHash] = useState(window.location.hash || '#/')
  useEffect(() => {
    const onChange = () => setHash(window.location.hash || '#/')
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  const go = (h) => { window.location.hash = h }
  return [hash, go]
}

const STATUS_LABEL = {
  queued: 'In Warteschlange',
  transcribing: 'Transkribiere …',
  summarizing: 'Fasse zusammen …',
  done: 'Fertig',
  error: 'Fehler',
}
const ACTIVE = new Set(['queued', 'transcribing', 'summarizing'])

function StatusBadge({ status }) {
  return <span className={`badge st-${status}`}>{STATUS_LABEL[status] || status}</span>
}

function fmtDate(iso) {
  if (!iso) return ''
  return iso.slice(0, 16).replace('T', ' ')
}

function fmtDuration(sec) {
  if (!sec) return ''
  const s = Math.floor(sec)
  if (s < 60) return `${s} s`
  const m = Math.floor(s / 60), r = s % 60
  if (m < 60) return `${m}:${String(r).padStart(2, '0')} min`
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')} h`
}

function stripMd(s, n = 140) {
  const plain = (s || '').replace(/[#*`>\-]/g, ' ').replace(/\s+/g, ' ').trim()
  return plain.length > n ? plain.slice(0, n) + '…' : plain
}

// ── Dashboard ────────────────────────────────────────────────────────────────
function Dashboard({ go }) {
  const [meetings, setMeetings] = useState(null)
  const [health, setHealth] = useState(null)
  const [query, setQuery] = useState('')
  const [error, setError] = useState('')

  const load = async () => {
    try {
      const [ms, h] = await Promise.all([api.meetings(), api.health()])
      setMeetings(ms); setHealth(h); setError('')
      return ms
    } catch (err) {
      setError(String(err.message || err))
      return null
    }
  }
  useEffect(() => { load() }, [])
  // Solange etwas verarbeitet wird, Liste regelmäßig auffrischen
  useEffect(() => {
    if (!meetings || !meetings.some((m) => ACTIVE.has(m.status))) return
    const t = setInterval(load, 4000)
    return () => clearInterval(t)
  }, [meetings])

  const remove = async (m) => {
    if (!window.confirm(`Meeting „${m.title || `#${m.id}`}“ wirklich löschen?`)) return
    try { await api.remove(m.id); await load() } catch (err) { setError(String(err.message || err)) }
  }

  const filtered = (meetings || []).filter((m) => {
    if (!query.trim()) return true
    const q = query.toLowerCase()
    return (m.title || '').toLowerCase().includes(q)
      || (m.created_at || '').includes(q)
  })
  const totalMin = Math.round((meetings || []).reduce((a, m) => a + (m.duration_s || 0), 0) / 60)
  const doneCount = (meetings || []).filter((m) => m.status === 'done').length

  return (
    <div className="page">
      <header className="topbar">
        <div className="brand" onClick={() => go('#/')}>
          <span className="logo">🥣</span>
          <div>
            <h1>Yogurt Meetings</h1>
            <p className="sub">Private AI Meeting-Notizen · komplett lokal</p>
          </div>
        </div>
        {health && (
          <div className="health">
            <span className={`dot ${health.llm_ready ? 'ok' : 'warn'}`} title={health.llm_ready ? 'LLM bereit' : 'LLM nicht erreichbar'}></span>
            Whisper: {health.whisper_model} · LLM {health.llm_ready ? 'bereit' : 'aus'} · v{health.version}
          </div>
        )}
        <button className="btn primary" onClick={() => go('#/new')}>＋ Neues Meeting</button>
        <button className="btn ghost" onClick={() => go('#/settings')} title="Einstellungen">⚙</button>
      </header>

      {error && <div className="alert error">⚠ {error}</div>}

      <div className="stats">
        <div className="stat"><b>{meetings ? meetings.length : '…'}</b><span>Meetings</span></div>
        <div className="stat"><b>{doneCount}</b><span>verarbeitet</span></div>
        <div className="stat"><b>{totalMin}</b><span>Minuten Audio</span></div>
      </div>

      <input className="search" placeholder="🔍 Meetings durchsuchen (Titel/Datum) …"
             value={query} onChange={(e) => setQuery(e.target.value)} />

      {!meetings && !error && <div className="empty">Lade Meetings …</div>}
      {meetings && meetings.length === 0 && (
        <div className="empty card">
          <h3>Noch keine Meetings</h3>
          <p>Nimm dein erstes Meeting auf, lade eine Audio-Datei hoch oder füge Text ein –<br />
             alles wird hier lokal transkribiert und zusammengefasst.</p>
          <button className="btn primary" onClick={() => go('#/new')}>Jetzt starten</button>
        </div>
      )}

      <div className="grid">
        {filtered.map((m) => (
          <div className="card meeting" key={m.id} onClick={() => go(`#/meeting/${m.id}`)}>
            <div className="card-head">
              <StatusBadge status={m.status} />
              <span className="meta">{fmtDate(m.created_at)}</span>
            </div>
            <h3 className="m-title">{m.title || `Meeting #${m.id}`}</h3>
            <p className="preview">
              {m.status === 'error'
                ? '⚠ Fehler bei der Verarbeitung – Details im Meeting'
                : (m.preview || (ACTIVE.has(m.status) ? 'wird verarbeitet …' : (m.source === 'text' ? 'Text-Notiz' : 'keine Zusammenfassung')))}
            </p>
            <div className="card-foot">
              <span className="meta">{m.source === 'audio' ? '🎙️' : '📝'} {m.source === 'audio' ? fmtDuration(m.duration_s) : 'Text'}</span>
              <button className="icon danger" title="Löschen" onClick={(e) => { e.stopPropagation(); remove(m) }}>🗑</button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

// ── Neues Meeting ────────────────────────────────────────────────────────────
function NewMeeting({ go }) {
  const [tab, setTab] = useState('rec')
  const [title, setTitle] = useState('')

  return (
    <div className="page">
      <div className="row">
        <button className="btn ghost" onClick={() => go('#/')}>← Zurück</button>
        <h2 className="viewtitle">Neues Meeting</h2>
      </div>
      <div className="card formcard">
        <label className="lbl">Titel (optional – wird sonst per KI vorgeschlagen)</label>
        <input className="txt" placeholder="z. B. Wochenmeeting Produktion"
               value={title} onChange={(e) => setTitle(e.target.value)} />
      </div>
      <div className="tabs">
        <button className={`tab ${tab === 'rec' ? 'on' : ''}`} onClick={() => setTab('rec')}>🎙️ Aufnehmen</button>
        <button className={`tab ${tab === 'file' ? 'on' : ''}`} onClick={() => setTab('file')}>📁 Datei hochladen</button>
        <button className={`tab ${tab === 'text' ? 'on' : ''}`} onClick={() => setTab('text')}>📝 Text einfügen</button>
      </div>
      {tab === 'rec' && <RecordPanel title={title} go={go} />}
      {tab === 'file' && <FilePanel title={title} go={go} />}
      {tab === 'text' && <TextPanel title={title} go={go} />}
    </div>
  )
}

function RecordPanel({ title, go }) {
  const [includeSystem, setIncludeSystem] = useState(false)
  const [rec, setRec] = useState(null)        // Recorder-Objekt
  const [seconds, setSeconds] = useState(0)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')

  useEffect(() => {
    if (!rec) return
    const t = setInterval(() => setSeconds((s) => s + 1), 1000)
    return () => clearInterval(t)
  }, [rec])
  useEffect(() => () => { if (rec) rec.cancel() }, []) // Aufräumen beim Verlassen

  const start = async () => {
    setError(''); setNote('')
    try {
      const r = await startRecording({ includeSystem })
      setNote(`Aufnahme läuft – ${r.systemNote || 'nur Mikrofon'}`)
      setSeconds(0)
      setRec(r)
    } catch (err) {
      setError(String(err.message || err))
    }
  }
  const stop = async () => {
    if (!rec) return
    setBusy('Verarbeite Aufnahme …')
    try {
      const blob = await rec.stop()
      setRec(null)
      if (!blob.size) throw new Error('Aufnahme ist leer.')
      const ext = blob.type.includes('mp4') ? '.mp4' : '.webm'
      const file = new File([blob], `aufnahme${ext}`, { type: blob.type })
      const res = await uploadWithProgress(file, title, (p) => setBusy(`Lade hoch … ${p}%`))
      go(`#/meeting/${res.id}`)
    } catch (err) {
      setError(String(err.message || err)); setBusy('')
    }
  }

  return (
    <div className="card recpanel">
      {error && <div className="alert error">⚠ {error}</div>}
      {!rec && (
        <div className="center">
          <p className="hint">Mikrofon erlauben → Aufnahme starten → Stopp → automatisch transkribieren &amp; zusammenfassen.</p>
          <label className="check">
            <input type="checkbox" checked={includeSystem} onChange={(e) => setIncludeSystem(e.target.checked)} />
            Zusätzlich System-/Tab-Audio aufnehmen (Online-Meeting im Browser mitschneiden)
          </label>
          <button className="btn big primary" onClick={start}>⏺ Aufnahme starten</button>
          <p className="tiny">Dauerhaftes Mitschneiden anderer Apps (wie Yogurt am Desktop) ist im Browser nur als Tab-Audio möglich.</p>
        </div>
      )}
      {rec && (
        <div className="center">
          <div className="rec-ind"><span className="pulse"></span> REC {fmtClock(seconds)}</div>
          <button className="btn big stop" onClick={stop}>⏹ Stopp &amp; verarbeiten</button>
        </div>
      )}
      {note && <p className="tiny center">{note}</p>}
      {busy && <div className="alert info">… {busy}</div>}
    </div>
  )
}

function FilePanel({ title, go }) {
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [drag, setDrag] = useState(false)

  const doUpload = async () => {
    if (!file) { setError('Bitte eine Audio-/Video-Datei wählen.'); return }
    setError(''); setBusy('Lade hoch … 0%')
    try {
      const res = await uploadWithProgress(file, title, (p) => setBusy(`Lade hoch … ${p}%`))
      go(`#/meeting/${res.id}`)
    } catch (err) {
      setError(String(err.message || err)); setBusy('')
    }
  }
  return (
    <div className="card">
      {error && <div className="alert error">⚠ {error}</div>}
      {busy && <div className="alert info">… {busy}</div>}
      <div className={`dropzone ${drag ? 'drag' : ''}`}
           onDragOver={(e) => { e.preventDefault(); setDrag(true) }}
           onDragLeave={() => setDrag(false)}
           onDrop={(e) => { e.preventDefault(); setDrag(false); if (e.dataTransfer.files[0]) setFile(e.dataTransfer.files[0]) }}>
        {file ? <p>📁 <b>{file.name}</b> ({Math.round(file.size / 1024 / 1024 * 10) / 10} MB)</p>
              : <p>Datei hierher ziehen oder auswählen<br /><span className="tiny">(WebM, MP3, M4A, OGG, WAV, MP4 …)</span></p>}
        <input type="file" accept="audio/*,video/*,.webm,.ogg,.mp3,.m4a,.wav,.mp4,.opus,.flac"
               onChange={(e) => setFile(e.target.files[0] || null)} />
      </div>
      <button className="btn primary" onClick={doUpload} disabled={!!busy}>
        {busy ? 'Hochladen …' : 'Hochladen & verarbeiten'}
      </button>
    </div>
  )
}

function TextPanel({ title, go }) {
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const submit = async () => {
    if (!text.trim()) { setError('Bitte Text einfügen.'); return }
    setError(''); setBusy(true)
    try {
      const res = await api.textMeeting(title, text)
      go(`#/meeting/${res.id}`)
    } catch (err) {
      setError(String(err.message || err)); setBusy(false)
    }
  }
  return (
    <div className="card">
      {error && <div className="alert error">⚠ {error}</div>}
      <label className="lbl">Notizen / Protokoll / Transkript einfügen – daraus werden Meeting-Notizen erstellt:</label>
      <textarea className="txt tall" value={text} onChange={(e) => setText(e.target.value)}
                placeholder="Hier einfügen …"></textarea>
      <div className="row"><span className="tiny">{text.length} Zeichen</span>
        <button className="btn primary" onClick={submit} disabled={busy}>{busy ? 'Wird angelegt …' : 'Notizen erstellen'}</button></div>
    </div>
  )
}

// ── Meeting-Detail ───────────────────────────────────────────────────────────
function MeetingDetail({ id, go }) {
  const [m, setM] = useState(null)
  const [error, setError] = useState('')
  const [msg, setMsg] = useState('')
  const [notesDraft, setNotesDraft] = useState(null)
  const [titleDraft, setTitleDraft] = useState(null)

  const load = async () => {
    try {
      const d = await api.meeting(id)
      setM(d); setError('')
      return d
    } catch (err) { setError(String(err.message || err)); return null }
  }
  useEffect(() => { load() }, [id])
  useEffect(() => {
    if (!m || !ACTIVE.has(m.status)) return
    const t = setInterval(load, 2500)
    return () => clearInterval(t)
  }, [m])

  const saveNotes = async () => {
    try { const d = await api.patch(id, { notes: notesDraft ?? '' }); setM(d); setNotesDraft(null); setMsg('Notizen gespeichert.') }
    catch (err) { setError(String(err.message || err)) }
  }
  const saveTitle = async () => {
    if (titleDraft === null) return
    try { const d = await api.patch(id, { title: titleDraft }); setM(d); setTitleDraft(null) }
    catch (err) { setError(String(err.message || err)) }
  }
  const resummarize = async () => {
    try { await api.resummarize(id); setMsg('Erneute Zusammenfassung gestartet …'); await load() }
    catch (err) { setError(String(err.message || err)) }
  }
  const remove = async () => {
    if (!window.confirm('Dieses Meeting wirklich löschen?')) return
    try { await api.remove(id); go('#/') } catch (err) { setError(String(err.message || err)) }
  }
  const copyAll = async () => {
    const parts = [`# ${m.title || `Meeting #${m.id}`}`]
    if (m.summary) parts.push(m.summary)
    if ((notesDraft ?? m.notes)) parts.push('## Eigene Notizen\n' + (notesDraft ?? m.notes))
    if (m.transcript) parts.push('## Transkript\n' + m.transcript)
    try {
      await navigator.clipboard.writeText(parts.join('\n\n'))
      setMsg('In die Zwischenablage kopiert.')
    } catch {
      setMsg('Kopieren nicht möglich (Browser-Blockierung) – bitte Export nutzen.')
    }
  }

  if (error && !m) return <div className="page"><div className="alert error">⚠ {error}</div></div>
  if (!m) return <div className="page"><div className="empty">Lade Meeting …</div></div>

  const processing = ACTIVE.has(m.status)
  return (
    <div className="page wide">
      <div className="row spread">
        <button className="btn ghost" onClick={() => go('#/')}>← Alle Meetings</button>
        <div className="actions">
          <a className="btn ghost" href={api.exportUrl(id)} download>⬇ Export (Markdown)</a>
          <button className="btn ghost" onClick={copyAll}>📋 Kopieren</button>
          <button className="btn ghost" onClick={resummarize} disabled={processing}>🔄 Neu zusammenfassen</button>
          <button className="btn danger" onClick={remove}>🗑 Löschen</button>
        </div>
      </div>

      {m.status === 'error' && m.error && <div className="alert error">⚠ Fehler: {m.error} <button className="btn ghost sm" onClick={resummarize}>Erneut versuchen</button></div>}
      {processing && <div className="alert info"><span className="spin">◌</span> {STATUS_LABEL[m.status]} – diese Seite aktualisiert sich automatisch.</div>}
      {msg && <div className="alert info">✔ {msg}</div>}

      <div className="title-row">
        {titleDraft === null
          ? <h2 className="editable" onClick={() => setTitleDraft(m.title || '')} title="Klicken zum Bearbeiten">{m.title || `Meeting #${m.id}`}</h2>
          : <div className="row grow">
              <input className="txt" value={titleDraft} autoFocus
                     onChange={(e) => setTitleDraft(e.target.value)}
                     onKeyDown={(e) => { if (e.key === 'Enter') saveTitle() }} />
              <button className="btn primary sm" onClick={saveTitle}>✔</button>
              <button className="btn ghost sm" onClick={() => setTitleDraft(null)}>✕</button>
            </div>}
        <span className="meta">
          {fmtDate(m.created_at)} · {m.source === 'audio' ? `🎙️ ${fmtDuration(m.duration_s)}` : '📝 Text'}
          {m.language ? ` · ${m.language}` : ''}
        </span>
      </div>

      {m.summary && (
        <div className="card">
          <h3>🧠 Meeting-Notizen</h3>
          <div className="md" dangerouslySetInnerHTML={{ __html: renderMarkdown(m.summary) }} />
        </div>
      )}

      <div className="card">
        <h3>✍️ Eigene Notizen</h3>
        {notesDraft === null
          ? (<div className="md muted"
                 onClick={() => setNotesDraft(m.notes || '')}
                 title="Klicken zum Bearbeiten">
              {m.notes ? <div dangerouslySetInnerHTML={{ __html: renderMarkdown(m.notes) }} />
                        : <p className="tiny">Klicken, um eigene Notizen zu ergänzen …</p>}
             </div>)
          : (<>
              <textarea className="txt tall" value={notesDraft} onChange={(e) => setNotesDraft(e.target.value)} />
              <div className="row">
                <button className="btn primary sm" onClick={saveNotes}>Notizen speichern</button>
                <button className="btn ghost sm" onClick={() => setNotesDraft(null)}>Abbrechen</button>
              </div>
             </>)}
      </div>

      {m.has_audio && (
        <div className="card">
          <h3>🔊 Aufnahme</h3>
          <audio controls src={api.audioUrl(id)} style={{ width: '100%' }} />
        </div>
      )}

      {m.transcript && (
        <div className="card">
          <h3>📜 Transkript</h3>
          <pre className="transcript">{m.transcript}</pre>
        </div>
      )}
    </div>
  )
}

// ── Einstellungen ─────────────────────────────────────────────────────────────
function SettingsPage({ go }) {
  const [s, setS] = useState(null)
  const [saving, setSaving] = useState(false)
  const [msg, setMsg] = useState('')
  const [err, setErr] = useState('')

  useEffect(() => {
    api.settings().then(setS).catch(e => setErr(String(e.message || e)))
  }, [])

  const save = async (patch) => {
    setSaving(true); setMsg(''); setErr('')
    try {
      const updated = await api.updateSettings(patch)
      setS(updated)
      setMsg('Gespeichert.')
    } catch (e) {
      setErr(String(e.message || e))
    } finally {
      setSaving(false)
    }
  }

  if (err && !s) return <div className="page"><div className="alert error">⚠ {err}</div></div>
  if (!s) return <div className="page"><div className="empty">Lade Einstellungen …</div></div>

  return (
    <div className="page">
      <div className="row">
        <button className="btn ghost" onClick={() => go('#/')}>← Zurück</button>
        <h2 className="viewtitle">⚙ Einstellungen</h2>
      </div>
      {msg && <div className="alert info">✔ {msg}</div>}
      {err && <div className="alert error">⚠ {err}</div>}

      <div className="card">
        <h3>🧠 LLM-Provider (Zusammenfassung)</h3>
        <p className="hint">Lokal (llama.cpp im Container), Ollama (eigene Instanz) oder OpenRouter (Cloud, API-Key nötig).</p>
        <label className="lbl">Provider</label>
        <div className="row">
          {s.available_providers.map(p => (
            <button key={p}
              className={`tab ${s.llm_provider === p ? 'on' : ''}`}
              onClick={() => save({ llm_provider: p })}
              disabled={saving}>
              {p === 'local' ? '🏠 Lokal (llama.cpp)' : p === 'ollama' ? '🦙 Ollama' : '🌐 OpenRouter'}
            </button>
          ))}
        </div>

        {s.llm_provider === 'ollama' && (
          <>
            <label className="lbl" style={{marginTop: 16}}>Ollama-URL</label>
            <input className="txt" defaultValue={s.ollama_url}
                   onBlur={e => save({ ollama_url: e.target.value })} />
            <label className="lbl" style={{marginTop: 12}}>Modell</label>
            <input className="txt" defaultValue={s.ollama_model}
                   onBlur={e => save({ ollama_model: e.target.value })}
                   placeholder="z. B. llama3.2, qwen2.5, mistral" />
            <p className="tiny">Ollama muss von außen erreichbar sein (z. B. <code>OLLAMA_HOST=0.0.0.0:11434</code>).</p>
          </>
        )}

        {s.llm_provider === 'openrouter' && (
          <>
            <label className="lbl" style={{marginTop: 16}}>OpenRouter API-Key</label>
            <input className="txt" type="password" defaultValue={s.openrouter_api_key}
                   onBlur={e => save({ openrouter_api_key: e.target.value })}
                   placeholder="sk-or-…" />
            <label className="lbl" style={{marginTop: 12}}>Modell</label>
            <input className="txt" defaultValue={s.openrouter_model}
                   onBlur={e => save({ openrouter_model: e.target.value })}
                   placeholder="z. B. openai/gpt-4o-mini, anthropic/claude-3.5-sonnet" />
            <p className="tiny">API-Key auf <a href="https://openrouter.ai/keys" target="_blank" rel="noopener">openrouter.ai/keys</a> erstellen.</p>
          </>
        )}

        {s.llm_provider === 'local' && (
          <div className="alert info" style={{marginTop: 12}}>
            🏠 Lokales llama.cpp (Qwen3-1.7B) läuft im Container auf 127.0.0.1:8081.
            Für längere Meetings kann das dauern – oder du nutzt Ollama/OpenRouter.
          </div>
        )}
      </div>

      <div className="card">
        <h3>🎙️ Whisper (Transkription)</h3>
        <label className="lbl">Modell</label>
        <div className="row">
          {['tiny', 'base', 'small', 'medium', 'large-v3', 'large-v3-turbo'].map(m => (
            <button key={m}
              className={`tab ${s.whisper_model === m ? 'on' : ''}`}
              onClick={() => save({ whisper_model: m })}
              disabled={saving}>
              {m}
            </button>
          ))}
        </div>
        <p className="tiny">Größer = genauer, aber langsamer. <b>small</b> ist ein guter Kompromiss.</p>
        <label className="lbl" style={{marginTop: 12}}>Sprache</label>
        <div className="row">
          <button className={`tab ${s.whisper_lang === 'auto' ? 'on' : ''}`}
            onClick={() => save({ whisper_lang: 'auto' })} disabled={saving}>Auto</button>
          <button className={`tab ${s.whisper_lang === 'de' ? 'on' : ''}`}
            onClick={() => save({ whisper_lang: 'de' })} disabled={saving}>Deutsch</button>
          <button className={`tab ${s.whisper_lang === 'en' ? 'on' : ''}`}
            onClick={() => save({ whisper_lang: 'en' })} disabled={saving}>Englisch</button>
        </div>
      </div>

      <div className="card">
        <h3>📊 Status</h3>
        <p className="tiny">LLM-Provider: <b>{s.llm_provider}</b> · Modell: <b>{s.llm_model_active}</b> · Erreichbar: {s.llm_ready ? '✅' : '❌'}</p>
      </div>
    </div>
  )
}

function App() {
  const [hash, go] = useHash()
  const meetingMatch = hash.match(/^#\/meeting\/(\d+)/)
  if (hash.startsWith('#/new')) return <NewMeeting go={go} />
  if (hash.startsWith('#/settings')) return <SettingsPage go={go} />
  if (meetingMatch) return <MeetingDetail id={Number(meetingMatch[1])} go={go} />
  return <Dashboard go={go} />
}

export default App

createRoot(document.getElementById('root')).render(<App />)
