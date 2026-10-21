// Click → frame in a real browser, through the whole stack: web client, signaling, WebRTC, host
// peer, simstream. Taps go through the browser's own input (Playwright or WebDriver), so the
// numbers are what the overlay shows a user.
//
//   node bench/latency.mjs --browser chrome --video dataChannel --taps 40
//   node bench/latency.mjs --browser safari --webdriver http://localhost:4444   # safaridriver -p 4444
//   node bench/latency.mjs --browser firefox --webdriver http://localhost:4444  # geckodriver -p 4444
//   node bench/latency.mjs --browser chromium --steps shot:a,home,shot:b,rotate:landscapeLeft,type:hi,lock
//
// chrome = /Applications/Google Chrome.app, chromium = Playwright's headless shell. Needs a
// control plane at --url (the dev mock: `npm run dev`) with a host peer serving it.

import { writeFileSync } from 'node:fs'
import { parseArgs } from 'node:util'

const { values: o } = parseArgs({ options: {
  browser: { type: 'string', default: 'chromium' },
  video: { type: 'string', default: 'dataChannel' },
  taps: { type: 'string', default: '40' },
  url: { type: 'string', default: 'http://localhost:5173/' },
  webdriver: { type: 'string', default: 'http://localhost:4444' },
  steps: { type: 'string', default: '' },
  hold: { type: 'string', default: '60' },
  headed: { type: 'boolean', default: false },
} })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function playwright() {
  const { chromium } = await import('playwright-core')
  const launch = o.browser === 'chrome'
    ? { channel: 'chrome', headless: !o.headed }
    : { executablePath: process.env.CHROMIUM ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-mac-arm64/chrome-headless-shell` }
  const browser = await chromium.launch(launch)
  const page = await browser.newPage({ viewport: { width: 900, height: 1000 } })
  page.on('pageerror', (e) => console.log('pageerror:', e.message))
  return {
    open: (url) => page.goto(url),
    eval: (js) => page.evaluate(js),
    tap: async (x, y, hold) => { await page.mouse.move(x, y); await page.mouse.down(); await sleep(hold); await page.mouse.up() },
    type: async (text) => { await page.focus('.screen'); await page.keyboard.type(text, { delay: 50 }) },
    upload: (path) => page.setInputFiles('input[type=file]', path),
    shot: (path) => page.screenshot({ path }),
    close: () => browser.close(),
  }
}

async function webdriver() {
  async function wd(method, path, body) {
    const r = await fetch(o.webdriver + path, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
    const j = await r.json()
    if (!r.ok) throw new Error(`${method} ${path}: ${JSON.stringify(j.value).slice(0, 300)}`)
    return j.value
  }
  const { sessionId } = await wd('POST', '/session', { capabilities: { alwaysMatch: { browserName: o.browser } } })
  const s = `/session/${sessionId}`
  await wd('POST', `${s}/window/rect`, { width: 900, height: 1100 })
  const pointer = (actions) => wd('POST', `${s}/actions`, { actions: [{ type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions }] })
  return {
    open: (url) => wd('POST', `${s}/url`, { url }),
    eval: (js) => wd('POST', `${s}/execute/sync`, { script: `return (${js})`, args: [] }),
    tap: (x, y, hold) => pointer([
      { type: 'pointerMove', origin: 'viewport', x: Math.round(x), y: Math.round(y), duration: 0 },
      { type: 'pointerDown', button: 0 }, { type: 'pause', duration: hold }, { type: 'pointerUp', button: 0 },
    ]),
    type: (text) => wd('POST', `${s}/actions`, { actions: [{ type: 'key', id: 'keyboard', actions: [...text].flatMap((c) => [{ type: 'keyDown', value: c }, { type: 'keyUp', value: c }]) }] }),
    shot: async (path) => writeFileSync(path, Buffer.from(await wd('GET', `${s}/screenshot`), 'base64')),
    close: () => wd('DELETE', s),
  }
}

const b = o.browser === 'chrome' || o.browser === 'chromium' ? await playwright() : await webdriver()
async function waitFor(js, timeout = 60000) {
  const end = Date.now() + timeout
  while (Date.now() < end) { if (await b.eval(js)) return; await sleep(200) }
  throw new Error(`timed out: ${js}`)
}

try {
  const url = `${o.url}?video=${o.video}&invite=bench`
  await b.open(url)
  await b.eval(`localStorage.removeItem('maccheri.token')`)
  await b.open(url)
  await waitFor(`!!document.querySelector('form')`)
  await b.eval(`(() => { document.querySelector('input[name=name]').value = ${JSON.stringify(o.browser)}; document.querySelector('form button[type=submit]').click() })()`)
  await waitFor(`[...document.querySelectorAll('button')].some((b) => b.textContent === 'Новая сессия')`)
  await b.eval(`[...document.querySelectorAll('button')].find((b) => b.textContent === 'Новая сессия').click()`)
  await waitFor(`!!document.querySelector('.screen .video') && /fps/.test(document.querySelector('.overlay')?.textContent ?? '')`)
  await sleep(2500)
  const center = await b.eval(`(() => { const r = document.querySelector('.screen').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()`)

  for (const step of o.steps.split(',').filter(Boolean)) {
    const [name, arg] = step.split(':')
    if (name === 'shot') { await sleep(1500); await b.shot(`${arg}.png`); console.log(`saved ${arg}.png`) }
    else if (name === 'home' || name === 'lock') await b.eval(`maccheri.session.press('${name}')`)
    else if (name === 'rotate') await b.eval(`maccheri.session.rotate('${arg}')`)
    else if (name === 'type') await b.type(arg)
    else if (name === 'tap') await b.tap(center[0], center[1], 60)
    else if (name === 'install') {
      // install:<path to a zipped .app>, through the toolbar's file picker; waits for the outcome.
      await b.upload(arg)
      await waitFor(`/Запущено|Ошибка/.test(document.querySelector('.status')?.textContent ?? '')`, 120000)
      console.log(await b.eval(`document.querySelector('.status').textContent`))
    }
    else if (name === 'wait') await sleep(Number(arg))
    else if (name === 'drag') {
      // drag:x1 y1 x2 y2, normalised; sent as touches directly, the way a pointer drag would.
      const [x1, y1, x2, y2] = arg.split(' ').map(Number)
      await b.eval(`(async () => { const t = maccheri.session; t.touch('began', ${x1}, ${y1}); for (let i = 1; i <= 12; i++) { await new Promise((r) => setTimeout(r, 20)); t.touch('moved', ${x1} + (${x2} - ${x1}) * i / 12, ${y1} + (${y2} - ${y1}) * i / 12) } t.touch('ended', ${x2}, ${y2}) })()`)
    }
    else if (name === 'button') await b.eval(`document.querySelector('button[title="${arg}"]').click()`)
  }

  const taps = o.steps ? 0 : Number(o.taps)
  for (let i = 0; i < taps; i++) {
    await b.tap(center[0], center[1], Number(o.hold))
    await sleep(250 + Math.random() * 150)
  }
  await sleep(1000)
  console.log(await b.eval(`document.querySelector('.overlay').textContent`))
  if (taps > 0) {
    const samples = await b.eval(`maccheri.session.samples`)
    const sorted = [...samples].sort((a, c) => a - c)
    const p = (q) => sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * q))]?.toFixed(1)
    console.log(`RESULT ${o.browser} ${o.video}: n=${samples.length}/${taps} p50 ${p(0.5)} p95 ${p(0.95)} ms`)
  }
  await b.eval(`[...document.querySelectorAll('button')].find((b) => b.textContent === 'Завершить').click()`)
  await sleep(500)
} finally {
  await b.close()
}
