// Float bridge: checks in with Claude Float every 1.5 seconds. When this chat is idle,
// Float hands over any replies you typed for it, and the mod submits them as your own message.
// While Claude is working, Float's settings hooks deliver replies at the next step instead.

const URL_ = 'http://127.0.0.1:47821/'
let token = ''
// Turns running now; subagent turns start and end inside the main one.
const running = new Set()

export function register(on) {
  on('session.start', async ($, e, next) => {
    await loadToken($)
    $.clock.every(1500, () => poll($))
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    running.add(e.turnId)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    running.delete(e.turnId)
    return next(e)
  })
}

async function loadToken($) {
  try {
    const home = await $.env.get('HOME')
    const text = await $.fs.read(home + '/.claude/float/token')
    token = typeof text === 'string' ? text.trim() : ''
  } catch {
    token = ''
  }
}

async function poll($) {
  if (!token) await loadToken($)
  if (!token) return
  const idle = running.size === 0
  let r
  try {
    r = await $.http.fetch(URL_, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Float-Token': token },
      body: JSON.stringify({ hook_event_name: 'FloatModPoll', session_id: await $.session.id(), idle }),
    })
  } catch {
    return // Float isn't running
  }
  if (r.status === 403) token = ''
  if (!r.ok) return
  let texts = []
  try {
    texts = JSON.parse(r.text).texts || []
  } catch {}
  // Not awaited: it resolves only once the new turn starts.
  if (texts.length) void $.prompt.submit({ text: texts.join('\n\n'), asUser: true })
}
