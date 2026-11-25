// Yogurt Meetings – API-Client
async function jfetch(url, opts = {}) {
  let res
  try {
    // 30s Default-Timeout; für Upload/Polling reicht das (Background-Tasks liefern sofort)
    res = await fetch(url, { ...opts, signal: opts.signal || AbortSignal.timeout(30000) })
  } catch (err) {
    throw new Error(`Netzwerkfehler bei ${url}: ${err.message}`)
  }
  let data = null
  try { data = await res.json() } catch { /* nicht-JSON Antwort */ }
  if (!res.ok) {
    const detail = data && (data.detail || data.error) ? ` – ${data.detail || data.error}` : ''
    throw new Error(`HTTP ${res.status}${detail}`)
  }
  return data
}

export const api = {
  health: () => jfetch('/api/health'),
  config: () => jfetch('/api/config'),
  meetings: () => jfetch('/api/meetings'),
  meeting: (id) => jfetch(`/api/meetings/${id}`),
  remove: (id) => jfetch(`/api/meetings/${id}`, { method: 'DELETE' }),
  patch: (id, body) => jfetch(`/api/meetings/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }),
  resummarize: (id) => jfetch(`/api/meetings/${id}/resummarize`, { method: 'POST' }),
  textMeeting: (title, text) => jfetch('/api/meetings/text', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, text }),
  }),
  upload: (file, title) => {
    const fd = new FormData()
    fd.append('file', file)
    if (title) fd.append('title', title)
    return jfetch('/api/meetings/upload', { method: 'POST', body: fd })
  },
  exportUrl: (id) => `/api/meetings/${id}/export`,
  audioUrl: (id) => `/api/meetings/${id}/audio`,
}

// Upload mit sichtbarem Fortschritt (XHR, da fetch keinen Upload-Progress hat)
export function uploadWithProgress(file, title, onProgress) {
  return new Promise((resolve, reject) => {
    const fd = new FormData()
    fd.append('file', file)
    if (title) fd.append('title', title)
    const xhr = new XMLHttpRequest()
    xhr.open('POST', '/api/meetings/upload')
    // Upload großer Dateien kann dauern – 10 min Timeout
    xhr.timeout = 600000
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) onProgress(Math.round((e.loaded / e.total) * 100))
    }
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try { resolve(JSON.parse(xhr.responseText)) } catch { resolve({}) }
      } else {
        reject(new Error(`Upload fehlgeschlagen: HTTP ${xhr.status} ${xhr.responseText.slice(0, 200)}`))
      }
    }
    xhr.ontimeout = () => reject(new Error('Upload-Timeout (10 min) – Datei evtl. zu groß oder Server überlastet.'))
    xhr.onerror = () => reject(new Error('Upload fehlgeschlagen (Netzwerkfehler)'))
    xhr.send(fd)
  })
}
