// Aufnahme-Logik: Mikrofon (+ optional System-/Tab-Audio) → MediaRecorder → Blob
const MIME_CANDIDATES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']

export function pickMimeType() {
  if (typeof MediaRecorder === 'undefined') return ''
  for (const t of MIME_CANDIDATES) {
    try {
      if (MediaRecorder.isTypeSupported(t)) return t
    } catch { /* weiterprobieren */ }
  }
  return ''
}

export function fmtClock(totalSec) {
  const s = Math.floor(totalSec)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  return (h ? `${h}:${String(m).padStart(2, '0')}` : `${m}`) + `:${String(sec).padStart(2, '0')}`
}

// Kombiniert Mikrofon-Audio mit dem Audio-Track eines Display/Tab-Streams
// (Chrome: Tab-Audio, Firefox/Edge je nach Plattform System-Audio).
async function buildStream(includeSystem) {
  const mic = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true },
    video: false,
  })
  if (!includeSystem) return { stream: mic, tracks: mic.getAudioTracks(), systemNote: '' }

  let display
  try {
    display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true })
  } catch (err) {
    mic.getTracks().forEach((t) => t.stop())
    throw new Error(`System-Audio konnte nicht gewählt werden (${err.name}: ${err.message}). ` +
      'Beim Teilen die Option „Tab-Audio teilen“ aktivieren. Aufnahme abgebrochen.')
  }
  const sysTracks = display.getAudioTracks()
  display.getVideoTracks().forEach((t) => t.stop()) // Video nicht nötig
  if (!sysTracks.length) {
    mic.getTracks().forEach((t) => t.stop())
    throw new Error('Der gewählte Tab enthält keinen Audiotrack. ' +
      'Beim Teilen unbedingt „Tab-Audio teilen“ ankreuzen – oder nur Mikrofon aufnehmen.')
  }
  const ctx = new AudioContext()
  const dest = ctx.createMediaStreamDestination()
  const srcMic = ctx.createMediaStreamSource(new MediaStream([mic.getAudioTracks()[0]]))
  const srcSys = ctx.createMediaStreamSource(new MediaStream([sysTracks[0]]))
  srcMic.connect(dest)
  srcSys.connect(dest)
  // Mikrofon und System-Audio mischen; beide Quellen live weiterlaufen lassen
  const mixed = dest.stream
  return { stream: mixed, tracks: mixed.getAudioTracks(), systemNote: ' Mikrofon + System-Audio (gemischt)' }
}

// Startet die Aufnahme und gibt Stop-/Cancel-Funktionen zurück.
export async function startRecording({ includeSystem }) {
  if (!window.isSecureContext) {
    throw new Error('Kein Secure Context: Das Mikrofon funktioniert nur über HTTPS (oder localhost). ' +
      'Der Server nutzt ein selbstsigniertes Zertifikat – die Browser-Warnung mit „Erweitert → Weiter zu …“ bestätigen.')
  }
  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error('Dieser Browser unterstützt keine Mikrofon-Aufnahme (mediaDevices fehlt).')
  }
  const { stream, tracks, systemNote } = await buildStream(includeSystem)
  const mimeType = pickMimeType()
  let rec
  try {
    rec = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
  } catch (err) {
    tracks.forEach((t) => t.stop())
    throw new Error(`MediaRecorder konnte nicht starten (${err.message}).`)
  }
  const chunks = []
  rec.ondataavailable = (e) => { if (e.data && e.data.size > 0) chunks.push(e.data) }

  const finished = new Promise((resolve) => {
    rec.onstop = () => {
      tracks.forEach((t) => t.stop())
      resolve(new Blob(chunks, { type: mimeType || 'audio/webm' }))
    }
  })
  rec.onerror = (e) => console.error('MediaRecorder-Fehler:', e.error || e)
  rec.start(1000) // 1-s-Chunks → keine riesigen Speicherblöcke

  return {
    systemNote,
    mimeType: mimeType || 'audio/webm',
    stop: () => new Promise((resolve) => {
      if (rec.state === 'inactive') { resolve(new Blob(chunks, { type: mimeType || 'audio/webm' })); return }
      rec.stop()
      finished.then(resolve)
    }),
    cancel: () => {
      try { if (rec.state !== 'inactive') rec.stop() } catch { /* ignorieren */ }
      tracks.forEach((t) => t.stop())
    },
  }
}
