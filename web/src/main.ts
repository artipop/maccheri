// Maccheri web client: sign in (GitHub and teams, or v1's invite/shared token), pick a Mac and a
// device, work with the simulator.
// Self-contained (one page, one bundle, no server rendering) so it can later live in a VS Code
// webview or a native wrapper.

import './style.css'
import { API, APIError, atLeast, deviceName, iPhone17Pro, type DeviceSpec, type GitHubInstallation, type HostInfo, type SessionInfo, type Team, type TeamMember, type TeamRole, type UserInfo } from './api'
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

/**
 * The standard path, the RTP track (with loss recovery), unless `?video=dataChannel` asks for the
 * other one for measurements. The default is decided by measurements over the internet
 * (bench/simstream/RESULTS.md), not per browser. WebCodecs needs a secure context.
 */
const preferredTransport = (): VideoTransport =>
  params.get('video') === 'dataChannel' && CanvasRenderer.supported ? 'dataChannel' : 'track'

// MARK: - Start

/**
 * Which accounts the control plane has decides the first screen. A v1 token in `localStorage` means
 * v1. Otherwise a cookie session answers `/v1/me` with `teams` (v2, signed in); without one, v2
 * offers GitHub sign-in, and v1 (`/auth/github/login` is 404) the token form.
 */
async function home(): Promise<void> {
  if (api.token) return v1Home()
  try {
    const me = await api.me()
    if (me.teams) return teamsHome(me)
  } catch (e) {
    if (!(e instanceof APIError) || (e.status !== 401 && e.status !== 404)) {
      return show(h('div', { class: 'card narrow' }, h('p', { class: 'error' }, errorText(e)), retryButton(home)))
    }
  }
  const v2 = await api.hasGitHubSignIn().catch(() => false)
  if (v2) githubSignIn()
  else signIn()
}

/** An invite to accept: `/invite/<code>` (the link in `Invite.url`) or `?invite=<code>`. */
function pendingInvite(): string | null {
  const m = location.pathname.match(/\/invite\/([^/]+)\/?$/)
  return m ? decodeURIComponent(m[1]) : params.get('invite')
}

function forgetInvite() {
  params.delete('invite')
  const query = params.toString()
  history.replaceState(null, '', location.pathname.replace(/invite\/[^/]+\/?$/, '') + (query ? `?${query}` : ''))
}

// MARK: - Sign in, v2

function githubSignIn() {
  const invited = pendingInvite() !== null
  const login = h('a', { class: 'button', href: api.githubLoginURL(location.pathname + location.search) }, 'Войти через GitHub')
  show(h('div', { class: 'card narrow' },
    h('h1', {}, 'Maccheri'),
    h('p', { class: 'muted' }, invited ? 'Вас пригласили в команду. Войдите через GitHub, чтобы присоединиться.' : 'Симуляторы iOS на маках вашей команды'),
    login))
}

// MARK: - Sign in, v1

function signIn(message = '') {
  const code = h('input', { name: 'code', placeholder: 'Код приглашения или токен команды', required: '', autocomplete: 'off', value: params.get('invite') ?? params.get('token') ?? '' })
  const name = h('input', { name: 'name', placeholder: 'Ваше имя', value: localStorage.getItem('maccheri.name') ?? '' })
  const error = h('p', { class: 'error' }, message)
  const form = h('form', { class: 'card narrow' }, h('h1', {}, 'Maccheri'), h('p', { class: 'muted' }, 'Вход по приглашению или общему токену команды'), code, name, h('button', { type: 'submit' }, 'Войти'), error)
  form.onsubmit = async (e) => {
    e.preventDefault()
    error.textContent = ''
    const value = code.value.trim()
    localStorage.setItem('maccheri.name', name.value)
    try {
      try {
        await api.redeem({ code: value, name: name.value.trim() || 'Без имени' })
      } catch (err) {
        // A control plane without users (docs/contracts.md, «Доступ в мини-проде») has no redeem:
        // what was typed is the shared token itself.
        if (!(err instanceof APIError) || (err.status !== 404 && err.status !== 405)) throw err
        api.token = value
        await api.hosts().catch((e) => { api.token = null; throw e instanceof APIError && e.status === 401 ? new Error('Неверный токен') : e })
      }
      history.replaceState(null, '', location.pathname)
      void home()
    } catch (err) {
      error.textContent = errorText(err)
    }
  }
  show(form)
}

// MARK: - Hosts, v1

async function v1Home(): Promise<void> {
  let me: { name: string }, hosts: HostInfo[]
  try {
    // Without users there is no /v1/me; the name typed at sign-in stands in.
    const anonymous = { name: localStorage.getItem('maccheri.name') || 'команда' }
    ;[me, hosts] = await Promise.all([api.me().catch((e) => { if (e instanceof APIError && e.status === 404) return anonymous; throw e }), api.hosts()])
  } catch (e) {
    if (e instanceof APIError && e.status === 401) { api.token = null; return signIn('Сессия входа истекла, войдите снова') }
    return show(h('div', { class: 'card narrow' }, h('p', { class: 'error' }, errorText(e)), retryButton(home)))
  }

  const signOut = h('button', { type: 'button', class: 'link' }, 'Выйти')
  signOut.onclick = () => { api.token = null; signIn() }
  show(h('div', { class: 'card' },
    h('header', {}, h('h1', {}, 'Maccheri'), h('span', { class: 'muted' }, me.name, ' · '), signOut),
    h('h2', {}, 'Маки команды'), hostList(hosts),
    ...sessionStarter(hosts)))
}

// MARK: - Teams, v2

const roleText: Record<TeamRole, string> = { member: 'участник', admin: 'админ', owner: 'владелец' }
const teamKey = 'maccheri.team'

async function teamsHome(me: UserInfo): Promise<void> {
  let teams = me.teams ?? []
  let notice = ''
  const invite = pendingInvite()
  if (invite !== null) {
    forgetInvite()
    try {
      const joined = await api.acceptInvite(invite)
      localStorage.setItem(teamKey, joined.id)
      teams = [...teams.filter((t) => t.id !== joined.id), joined]
      notice = `Вы в команде «${joined.name}»`
    } catch (e) {
      notice = `Приглашение не принято: ${errorText(e)}`
    }
  }

  const header = h('header', {}, h('h1', {}, 'Maccheri'))
  if (me.avatarURL) header.append(h('img', { class: 'avatar', src: me.avatarURL, alt: '' }))
  header.append(h('span', { class: 'muted' }, me.login ?? me.name, ' · '), signOutButton())

  if (teams.length === 0) return show(createTeamCard(header, notice, true))

  const team = teams.find((t) => t.id === localStorage.getItem(teamKey)) ?? teams[0]
  const admin = atLeast(team.role, 'admin')
  let hosts: HostInfo[], members: TeamMember[], installations: GitHubInstallation[] | null
  try {
    ;[hosts, members, installations] = await Promise.all([
      api.teamHosts(team.id), api.members(team.id),
      admin ? api.githubInstallations(team.id).catch(() => null) : Promise.resolve(null),
    ])
  } catch (e) {
    if (e instanceof APIError && e.status === 401) return home()
    return show(h('div', { class: 'card narrow' }, h('p', { class: 'error' }, errorText(e)), retryButton(home)))
  }

  // Team switcher; its last option makes another team.
  const picker = h('select', { name: 'team', title: 'Команда' })
  for (const t of teams) picker.append(h('option', { value: t.id }, `${t.name} · ${roleText[t.role]}`))
  picker.append(h('option', { value: 'new' }, 'Новая команда…'))
  picker.value = team.id
  picker.onchange = () => {
    if (picker.value === 'new') return show(createTeamCard(header, '', false))
    localStorage.setItem(teamKey, picker.value)
    void home()
  }
  header.insertBefore(picker, header.children[1])

  const card = h('div', { class: 'card' }, header)
  if (notice) card.append(h('p', { class: 'notice' }, notice))
  card.append(h('h2', {}, 'Маки команды'), hostList(hosts), ...sessionStarter(hosts, team.id))
  if (admin) card.append(addHostPanel(team))

  card.append(h('h2', {}, 'Участники'), memberList(members))
  if (admin) card.append(invitePanel(team))

  if (admin) card.append(h('h2', {}, 'GitHub'), githubPanel(team, installations))
  show(card)
}

function signOutButton() {
  const b = h('button', { type: 'button', class: 'link' }, 'Выйти')
  b.onclick = async () => {
    await api.logout().catch(() => {})
    void home()
  }
  return b
}

function createTeamCard(header: HTMLElement, notice: string, first: boolean) {
  const name = h('input', { name: 'team', placeholder: 'Название команды', required: '' })
  const error = h('p', { class: 'error' })
  const form = h('form', { class: 'row' }, name, h('button', { type: 'submit' }, 'Создать команду'))
  form.onsubmit = async (e) => {
    e.preventDefault()
    try {
      const team = await api.createTeam({ name: name.value.trim() })
      localStorage.setItem(teamKey, team.id)
      void home()
    } catch (err) {
      error.textContent = errorText(err)
    }
  }
  const card = h('div', { class: 'card' }, header)
  if (notice) card.append(h('p', { class: 'notice' }, notice))
  card.append(h('h2', {}, first ? 'Вы пока не в команде' : 'Новая команда'),
    h('p', { class: 'muted' }, 'Создайте команду и подключите к ней свои маки. Чтобы попасть в чужую команду, откройте ссылку-приглашение от её админа.'),
    form, error)
  if (!first) card.append(retryButton(home, 'Назад'))
  return card
}

function memberList(members: TeamMember[]) {
  const list = h('ul', { class: 'members' })
  for (const m of members) {
    const li = h('li', {})
    if (m.avatarURL) li.append(h('img', { class: 'avatar', src: m.avatarURL, alt: '' }))
    li.append(h('strong', {}, m.name || m.login), h('span', { class: 'muted' }, ` @${m.login} · ${roleText[m.role]}`))
    list.append(li)
  }
  return list
}

/** Invite link with a role, for admins and owners. */
function invitePanel(team: Team) {
  const role = h('select', { name: 'role', title: 'Роль' }, h('option', { value: 'member' }, 'участником'), h('option', { value: 'admin' }, 'админом'))
  const create = h('button', { type: 'button', class: 'secondary' }, 'Пригласить')
  const result = h('div', { class: 'issued' })
  create.onclick = async () => {
    try {
      const invite = await api.createTeamInvite(team.id, { role: role.value as TeamRole })
      const url = invite.url ?? `${location.origin}${location.pathname}?invite=${encodeURIComponent(invite.code)}`
      result.replaceChildren(copyField(url), h('p', { class: 'muted' }, `Ссылка одноразовая, действует до ${dateText(invite.expiresAt)}. Откройте её под своим GitHub, чтобы вступить.`))
    } catch (e) {
      result.replaceChildren(h('p', { class: 'error' }, errorText(e)))
    }
  }
  return h('div', {}, h('div', { class: 'row' }, h('span', { class: 'label' }, 'Пригласить в команду'), role, create), result)
}

/** One-time enrollment code for Maccheri.app on a new Mac. */
function addHostPanel(team: Team) {
  const create = h('button', { type: 'button', class: 'secondary' }, 'Добавить мак')
  const result = h('div', { class: 'issued' })
  create.onclick = async () => {
    try {
      const code = await api.createHostCode(team.id)
      const server = api.base || location.origin
      result.replaceChildren(copyField(code.code), h('p', { class: 'muted' },
        `На маке, который отдаёте команде, откройте Maccheri.app → Settings: адрес сервера ${server}, этот код — в поле Token. `,
        `Код одноразовый, действует до ${dateText(code.expiresAt)}. Мак появится в списке выше, как только подключится.`))
    } catch (e) {
      result.replaceChildren(h('p', { class: 'error' }, errorText(e)))
    }
  }
  return h('div', {}, h('div', { class: 'row' }, create), result)
}

function githubPanel(team: Team, installations: GitHubInstallation[] | null) {
  const list = h('ul', { class: 'members' })
  for (const i of installations ?? []) {
    list.append(h('li', {}, h('strong', {}, i.account), h('span', { class: 'muted' }, i.repositorySelection === 'all' ? ' · все репозитории' : ' · выбранные репозитории')))
  }
  if (installations === null) list.append(h('li', { class: 'muted' }, 'Не удалось загрузить установки'))
  else if (installations.length === 0) list.append(h('li', { class: 'muted' }, 'GitHub App ещё не установлен: CI-задачи команды не запускаются'))
  const link = h('button', { type: 'button', class: 'secondary' }, 'Подключить GitHub')
  const error = h('p', { class: 'error' })
  link.onclick = async () => {
    try {
      location.href = (await api.linkGitHub(team.id)).url
    } catch (e) {
      error.textContent = errorText(e)
    }
  }
  return h('div', {}, list, h('div', { class: 'row' }, link), error)
}

function copyField(value: string) {
  const input = h('input', { readonly: '', value })
  input.onfocus = () => input.select()
  const copy = h('button', { type: 'button', class: 'secondary' }, 'Копировать')
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(value); copy.textContent = 'Скопировано' } catch { input.focus() }
  }
  return h('div', { class: 'row copy' }, input, copy)
}

const dateText = (iso: string) => new Date(iso).toLocaleString('ru', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })

// MARK: - Hosts and a new session, both

function hostList(hosts: HostInfo[]) {
  const list = h('ul', { class: 'hosts' })
  for (const host of hosts) {
    const capacity = host.capacity
    list.append(h('li', { class: host.online ? '' : 'offline' },
      h('strong', {}, host.name), ` · ${host.ownerName} · ${host.hardware.chip}, ${Math.round(host.hardware.memoryBytes / 2 ** 30)} ГБ`,
      h('span', { class: 'muted' }, host.online ? ` · свободно ${capacity?.freeSlots ?? 0}, прогрето ${capacity?.warmVMs ?? 0}` : ' · не в сети')))
  }
  if (hosts.length === 0) list.append(h('li', { class: 'muted' }, 'Пока ни одного Mac в команде'))
  return list
}

/** Device and video pickers and «Новая сессия»; `teamID` in v2. */
function sessionStarter(hosts: HostInfo[], teamID?: string): HTMLElement[] {
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
    try {
      const choice = devices.get(select.value)!
      const session = await api.createSession({ device: select.value === 'any' ? null : choice.device, hostID: choice.hostID ?? null, ...(teamID ? { teamID } : {}) })
      void waitForSession(session, CanvasRenderer.supported ? transport.value as VideoTransport : 'track')
    } catch (e) {
      error.textContent = errorText(e)
      start.disabled = false
    }
  }
  return [h('div', { class: 'row' }, select, transport, start), error]
}

function retryButton(action: () => void, label = 'Повторить') {
  const b = h('button', { type: 'button' }, label)
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
  }, params.get('relay') === '1')

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
  // Video path switch, for comparing both on the same connection (measurements).
  const videoLabel = (t: VideoTransport) => (t === 'track' ? 'Видео: дорожка' : 'Видео: канал данных')
  const videoButton = button(videoLabel(transport), 'Переключить, как везти видео (для замеров)', () => {
    try {
      session.setTransport(session.transport === 'track' ? 'dataChannel' : 'track')
      videoButton.textContent = videoLabel(session.transport)
    } catch (e) {
      status.textContent = errorText(e)
    }
  })
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

void home()
