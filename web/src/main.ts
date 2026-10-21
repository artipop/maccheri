// Maccheri web client: sign in with an invite, pick a Mac and a device, work with the simulator.
// Self-contained (one page, one bundle, no server rendering) so it can later live in a VS Code
// webview or a native wrapper.

import './style.css'
import { API, APIError, deviceName, iPhone17Pro, type DeviceSpec, type HostInfo, type SessionInfo } from './api'
import { hidUsage } from './keyboard'
import { percentile } from './latency'
import type { Hello, Orientation, VideoTransport } from './protocol'
import { SimSession, type Stats } from './session'
import { CanvasRenderer, type Renderer } from './video'

// `?api=http://host:port` points the client at another control plane (dev); it is remembered.
const params = new URLSearchParams(location.search)
const apiOverride = params.get('api')
if (apiOverride !== null) localStorage.setItem('maccheri.api', apiOverride)
const api = new API(localStorage.getItem('maccheri.api') ?? '')
const app = document.getElementById('app')!

function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string> = {}, ...children: (Node | string)[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v)
  el.append(...children)
  return el
}

function show(...nodes: Node[]) {
  app.replaceChildren(...nodes)
}

function errorText(e: unknown): string {
  if (e instanceof APIError) return `${e.message} (${e.status})`
  return e instanceof Error ? e.message : String(e)
}

const preferredTransport = (): VideoTransport => {
  const saved = params.get('video') ?? localStorage.getItem('maccheri.video')
  if (saved === 'track' || saved === 'dataChannel') return saved
  // WebCodecs everywhere it exists: no jitter buffer at all (see simstream/README.md).
  return CanvasRenderer.supported ? 'dataChannel' : 'track'
}

// MARK: - Sign in

function signIn(message = '') {
  const code = h('input', { name: 'code', placeholder: 'Код приглашения', required: '', autocomplete: 'off', value: params.get('invite') ?? '' })
  const name = h('input', { name: 'name', placeholder: 'Ваше имя', required: '', value: localStorage.getItem('maccheri.name') ?? '' })
  const error = h('p', { class: 'error' }, message)
  const form = h('form', { class: 'card narrow' }, h('h1', {}, 'Maccheri'), h('p', { class: 'muted' }, 'Вход по приглашению команды'), code, name, h('button', { type: 'submit' }, 'Войти'), error)
  form.onsubmit = async (e) => {
    e.preventDefault()
    error.textContent = ''
    try {
      localStorage.setItem('maccheri.name', name.value)
      await api.redeem({ code: code.value.trim(), name: name.value.trim() })
      history.replaceState(null, '', location.pathname)
      void home()
    } catch (err) {
      error.textContent = errorText(err)
    }
  }
  show(form)
}

// MARK: - Hosts

async function home() {
  let me, hosts: HostInfo[]
  try {
    ;[me, hosts] = await Promise.all([api.me(), api.hosts()])
  } catch (e) {
    if (e instanceof APIError && e.status === 401) { api.token = null; return signIn('Сессия входа истекла, войдите снова') }
    return show(h('div', { class: 'card narrow' }, h('p', { class: 'error' }, errorText(e)), retryButton(home)))
  }

  const online = hosts.filter((x) => x.online)
  const devices = new Map<string, { device: DeviceSpec; hostID?: string }>()
  devices.set('any', { device: iPhone17Pro })
  for (const host of online) for (const d of host.capacity?.devices ?? []) devices.set(`${host.id}|${d.deviceType}|${d.runtime}`, { device: d, hostID: host.id })

  const select = h('select', { name: 'device' })
  select.append(h('option', { value: 'any' }, `Любой Mac · ${deviceName(iPhone17Pro)}`))
  for (const [key, { device, hostID }] of devices) {
    if (key === 'any') continue
    select.append(h('option', { value: key }, `${online.find((x) => x.id === hostID)?.name ?? '?'} · ${deviceName(device)}`))
  }
  const transport = h('select', { name: 'video', title: 'Как везти видео' },
    h('option', { value: 'dataChannel' }, 'Видео: канал данных + WebCodecs'),
    h('option', { value: 'track' }, 'Видео: WebRTC-дорожка'))
  transport.value = preferredTransport()
  if (!CanvasRenderer.supported) transport.querySelector<HTMLOptionElement>('option[value=dataChannel]')!.disabled = true

  const start = h('button', { type: 'button' }, 'Новая сессия')
  const error = h('p', { class: 'error' })
  start.onclick = async () => {
    start.disabled = true
    error.textContent = ''
    localStorage.setItem('maccheri.video', transport.value)
    try {
      const choice = devices.get(select.value)!
      const session = await api.createSession({ device: select.value === 'any' ? null : choice.device, hostID: choice.hostID ?? null })
      void waitForSession(session, transport.value as VideoTransport)
    } catch (e) {
      error.textContent = errorText(e)
      start.disabled = false
    }
  }

  const list = h('ul', { class: 'hosts' })
  for (const host of hosts) {
    const capacity = host.capacity
    list.append(h('li', { class: host.online ? '' : 'offline' },
      h('strong', {}, host.name), ` · ${host.ownerName} · ${host.hardware.chip}, ${Math.round(host.hardware.memoryBytes / 2 ** 30)} ГБ`,
      h('span', { class: 'muted' }, host.online ? ` · свободно ${capacity?.freeSlots ?? 0}, прогрето ${capacity?.warmVMs ?? 0}` : ' · не в сети')))
  }
  if (hosts.length === 0) list.append(h('li', { class: 'muted' }, 'Пока ни одного Mac в команде'))

  const signOut = h('button', { type: 'button', class: 'link' }, 'Выйти')
  signOut.onclick = () => { api.token = null; signIn() }
  show(h('div', { class: 'card' },
    h('header', {}, h('h1', {}, 'Maccheri'), h('span', { class: 'muted' }, me.name, ' · '), signOut),
    h('h2', {}, 'Маки команды'), list,
    h('div', { class: 'row' }, select, transport, start), error))
}

function retryButton(action: () => void) {
  const b = h('button', { type: 'button' }, 'Повторить')
  b.onclick = action
  return b
}

// MARK: - Session

const stateText: Record<string, string> = {
  queued: 'Ищем свободный Mac…',
  starting: 'Готовим виртуальную машину и симулятор…',
  ready: 'Подключаемся…',
}

async function waitForSession(initial: SessionInfo, transport: VideoTransport) {
  let session = initial
  let cancelled = false
  const status = h('p', {}, stateText[session.state] ?? session.state)
  const cancel = h('button', { type: 'button', class: 'secondary' }, 'Отменить')
  cancel.onclick = () => { cancelled = true; void api.endSession(session.id).finally(home) }
  const started = Date.now()
  const elapsed = h('span', { class: 'muted' })
  show(h('div', { class: 'card narrow' }, h('h2', {}, 'Новая сессия'), status, elapsed, cancel))
  const endOnUnload = () => void api.endSession(session.id, true)
  window.addEventListener('pagehide', endOnUnload)
  while (!cancelled && (session.state === 'queued' || session.state === 'starting')) {
    await new Promise((r) => setTimeout(r, 1000))
    elapsed.textContent = `${Math.round((Date.now() - started) / 1000)} с`
    try {
      session = await api.session(session.id)
      status.textContent = stateText[session.state] ?? session.state
    } catch (e) {
      status.textContent = errorText(e)
    }
  }
  window.removeEventListener('pagehide', endOnUnload)
  if (cancelled) return
  if (session.state !== 'ready' || !session.signaling) {
    return show(h('div', { class: 'card narrow' }, h('h2', {}, 'Сессия не началась'), h('p', { class: 'error' }, session.message ?? session.state), retryButton(home)))
  }
  runSession(session, transport)
}

function runSession(info: SessionInfo, transport: VideoTransport) {
  const screen = h('div', { class: 'screen', tabindex: '0' })
  const stage = h('div', { class: 'stage' }, screen)
  const overlay = h('pre', { class: 'overlay' })
  const status = h('div', { class: 'status' }, 'Подключаемся…')
  const drop = h('div', { class: 'drop' }, 'Отпустите .zip с .app, чтобы установить')
  const toolbar = h('div', { class: 'toolbar' })
  show(h('div', { class: 'session' }, toolbar, stage, overlay, status, drop))

  let hello: Hello | null = null
  let renderer: Renderer | null = null
  let videoSize = { width: 9, height: 19.5 }
  // Rotation is shown by the client: the simulator's framebuffer stays in portrait.
  let orientation: Orientation = 'portrait'

  const session = new SimSession(info.signaling!, transport, {
    onState(state, detail) {
      if (state === 'connected') status.textContent = ''
      else if (state === 'reconnecting') status.textContent = 'Связь пропала, восстанавливаем…'
      else if (state === 'ended') finish(detail)
    },
    onHello(h) {
      hello = h
      videoSize = { width: h.videoWidth, height: h.videoHeight }
      document.title = `${h.deviceName} · Maccheri`
      layout()
    },
    onRenderer(r) {
      renderer = r
      r.element.classList.add('video')
      r.onSize = (width, height) => { videoSize = { width, height }; layout() }
      screen.replaceChildren(r.element)
    },
    onStats: (s) => { overlay.textContent = statsText(s) },
    onInstall(state, message) {
      const text = { receiving: 'Загружаем', installing: 'Устанавливаем', launched: 'Запущено', failed: 'Ошибка' }[state]
      status.textContent = `${text}: ${message}`
      if (state === 'launched') setTimeout(() => { if (status.textContent?.startsWith(text)) status.textContent = '' }, 4000)
    },
  })

  // Layout: fit the (possibly rotated) screen into the stage.
  const rotation = (): number => ({ portrait: 0, landscapeLeft: -90, portraitUpsideDown: 180, landscapeRight: 90 })[orientation]
  function layout() {
    const quarter = Math.abs(rotation()) === 90
    const w = quarter ? videoSize.height : videoSize.width
    const h = quarter ? videoSize.width : videoSize.height
    const box = stage.getBoundingClientRect()
    const scale = Math.min(box.width / w, box.height / h)
    const dw = Math.floor(videoSize.width * scale), dh = Math.floor(videoSize.height * scale)
    screen.style.width = `${dw}px`
    screen.style.height = `${dh}px`
    screen.style.transform = `rotate(${rotation()}deg)`
  }
  new ResizeObserver(layout).observe(stage)

  // Input: pointer events in the screen's own (unrotated) coordinates.
  function point(e: PointerEvent): [number, number] {
    const r = screen.getBoundingClientRect()
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2
    const dx = e.clientX - cx, dy = e.clientY - cy
    const a = (-rotation() * Math.PI) / 180
    const x = dx * Math.cos(a) - dy * Math.sin(a), y = dx * Math.sin(a) + dy * Math.cos(a)
    return [x / screen.offsetWidth + 0.5, y / screen.offsetHeight + 0.5]
  }
  let pressed: number | null = null
  screen.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || pressed !== null) return
    pressed = e.pointerId
    screen.setPointerCapture(e.pointerId)
    screen.focus()
    if (renderer?.element instanceof HTMLVideoElement) void renderer.element.play().catch(() => {})
    session.touch('began', ...point(e))
    e.preventDefault()
  })
  screen.addEventListener('pointermove', (e) => {
    if (e.pointerId !== pressed) return
    session.touch('moved', ...point(e))
  })
  const release = (e: PointerEvent) => {
    if (e.pointerId !== pressed) return
    pressed = null
    session.touch('ended', ...point(e))
  }
  screen.addEventListener('pointerup', release)
  screen.addEventListener('pointercancel', release)
  screen.addEventListener('contextmenu', (e) => e.preventDefault())

  const keysDown = new Set<number>()
  screen.addEventListener('keydown', (e) => {
    const usage = hidUsage(e.code)
    if (usage === null) return
    e.preventDefault()
    if (e.repeat) return
    keysDown.add(usage)
    session.key(usage, true)
  })
  screen.addEventListener('keyup', (e) => {
    const usage = hidUsage(e.code)
    if (usage === null) return
    e.preventDefault()
    keysDown.delete(usage)
    session.key(usage, false)
  })
  screen.addEventListener('blur', () => { for (const k of keysDown) session.key(k, false); keysDown.clear() })

  // Toolbar.
  const button = (label: string, title: string, action: () => void) => {
    const b = h('button', { type: 'button', title }, label)
    b.onclick = () => { action(); screen.focus() }
    toolbar.append(b)
    return b
  }
  const order: Orientation[] = ['portrait', 'landscapeLeft', 'portraitUpsideDown', 'landscapeRight']
  const turn = (step: number) => {
    orientation = order[(order.indexOf(orientation) + step + 4) % 4]
    session.rotate(orientation)
    layout()
  }
  button('⌂', 'Домой', () => session.press('home'))
  button('⏻', 'Блокировка экрана', () => session.press('lock'))
  button('⟲', 'Повернуть влево', () => turn(1))
  button('⟳', 'Повернуть вправо', () => turn(-1))
  const picker = h('input', { type: 'file', accept: '.zip,application/zip', hidden: '' })
  picker.onchange = () => { if (picker.files?.[0]) void install(picker.files[0]) }
  toolbar.append(picker)
  button('Установить .app', 'Загрузить .app в zip-архиве', () => picker.click())
  toolbar.append(h('span', { class: 'spacer' }))
  const deviceLabel = h('span', { class: 'muted' }, info.hostName ?? '')
  toolbar.append(deviceLabel)
  const endButton = button('Завершить', 'Завершить сессию и удалить VM', () => end())
  endButton.classList.add('danger')

  async function install(file: File) {
    status.textContent = `Загружаем ${file.name}…`
    try {
      await session.install(file, (f) => { status.textContent = `Загружаем ${file.name}: ${Math.round(f * 100)}%` })
    } catch (e) {
      status.textContent = `Не удалось загрузить: ${errorText(e)}`
    }
  }
  let dragDepth = 0
  const dragging = (on: boolean) => drop.classList.toggle('visible', on)
  window.ondragenter = (e) => { e.preventDefault(); dragDepth++; dragging(true) }
  window.ondragleave = () => { if (--dragDepth <= 0) { dragDepth = 0; dragging(false) } }
  window.ondragover = (e) => e.preventDefault()
  window.ondrop = (e) => {
    e.preventDefault()
    dragDepth = 0
    dragging(false)
    const file = e.dataTransfer?.files[0]
    if (file) void install(file)
  }

  // Ending: the button, the host, or the tab going away.
  let finished = false
  const onUnload = () => {
    session.end('the viewer closed the tab')
    void api.endSession(info.id, true)
  }
  window.addEventListener('pagehide', onUnload)
  function end() {
    session.end('the viewer ended the session')
    void api.endSession(info.id).catch(() => {})
  }
  function finish(reason?: string) {
    if (finished) return
    finished = true
    window.removeEventListener('pagehide', onUnload)
    window.ondragenter = window.ondragleave = window.ondragover = window.ondrop = null
    const samples = session.samples
    const summary = samples.length ? `Клик → кадр: p50 ${percentile(samples, 0.5)!.toFixed(1)} мс, p95 ${percentile(samples, 0.95)!.toFixed(1)} мс, ${samples.length} замеров` : ''
    show(h('div', { class: 'card narrow' }, h('h2', {}, 'Сессия завершена'), h('p', { class: 'muted' }, reason ?? ''), h('p', {}, summary), retryButton(home)))
  }

  // Dev tooling: `window.maccheri.session` in the console, e.g. for scripted latency runs.
  ;(window as unknown as { maccheri: unknown }).maccheri = { session, get hello() { return hello } }
  session.start()
  screen.focus()
}

function statsText(s: Stats): string {
  const ms = (v: number | null) => (v === null ? '—' : `${v.toFixed(1)} мс`)
  const path = s.path === null ? 'соединяемся' : s.path === 'relay' ? 'через TURN' : 'напрямую'
  return [
    `${path} (${s.pathDetail || '…'})`,
    `RTT ${ms(s.rttMs)}, до симулятора ${ms(s.pingMs)}`,
    `${s.fps.toFixed(0)} fps, ${s.mbps.toFixed(2)} Мбит/с${s.lostFrames ? `, потеряно кадров ${s.lostFrames}` : ''}`,
    `клик → кадр ${ms(s.lastClickMs)} (p50 ${ms(s.clickP50Ms)}, p95 ${ms(s.clickP95Ms)}, n=${s.clicks})`,
    `  из них сервер p50 ${ms(s.serverP50Ms)}`,
    `видео: ${s.transport === 'track' ? 'WebRTC-дорожка' : 'канал данных + WebCodecs'}`,
  ].join('\n')
}

if (api.token) void home()
else signIn()
