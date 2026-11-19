// Mini-Markdown-Renderer (ohne Abhängigkeit): Überschriften, Listen,
// Checklisten, Bold/Italic, Code-Spans. Eingabe wird zuerst escaped (XSS-safe).
const escapeHtml = (s) => s
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;')

const inline = (s) => s
  .replace(/`([^`]+)`/g, '<code>$1</code>')
  .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  .replace(/\*([^*]+)\*/g, '<em>$1</em>')

export function renderMarkdown(src) {
  if (!src) return ''
  const lines = escapeHtml(src).split(/\r?\n/)
  const out = []
  let inList = false       // ul
  let inChecklist = false  // ul.tasklist

  const closeLists = () => {
    if (inChecklist) { out.push('</ul>'); inChecklist = false }
    if (inList) { out.push('</ul>'); inList = false }
  }

  for (const raw of lines) {
    const line = raw.trimEnd()
    let m
    if ((m = line.match(/^(#{1,4})\s+(.*)$/))) {
      closeLists()
      const lvl = m[1].length + 1
      out.push(`<h${lvl}>${inline(m[2])}</h${lvl}>`)
    } else if ((m = line.match(/^[-*]\s+\[( |x|X)\]\s+(.*)$/))) {
      if (!inChecklist) { closeLists(); out.push('<ul class="tasklist">'); inChecklist = true }
      const done = m[1].toLowerCase() === 'x'
      out.push(`<li class="${done ? 'done' : 'todo'}"><span class="box">${done ? '☑' : '☐'}</span> ${inline(m[2])}</li>`)
    } else if ((m = line.match(/^[-*]\s+(.*)$/))) {
      if (inChecklist) { out.push('</ul>'); inChecklist = false }
      if (!inList) { out.push('<ul>'); inList = true }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if ((m = line.match(/^\d+\.\s+(.*)$/))) {
      if (!inList) { closeLists(); out.push('<ul class="ordered">'); inList = true }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if (line === '') {
      closeLists()
    } else {
      closeLists()
      out.push(`<p>${inline(line)}</p>`)
    }
  }
  closeLists()
  return out.join('\n')
}
