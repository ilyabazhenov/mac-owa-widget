// Shared helpers for README mockups: language, icons, demo data, popover builder.
// Render with ?lang=en|ru&theme=dark|light (see scripts/render_mockups.sh).

const params = new URLSearchParams(location.search);
const LANG = params.get('lang') === 'ru' ? 'ru' : 'en';
const THEME = params.get('theme') === 'light' ? 'light' : 'dark';
document.documentElement.lang = LANG;
if (THEME === 'dark') document.documentElement.classList.add('dark');

const L = (ru, en) => (LANG === 'ru' ? ru : en);
const DARK = THEME === 'dark';

// ---------- Colors ----------
const C = {
  teams: '#6264A7', zoom: '#2D8CFF', webex: '#00BEF3', meet: '#00897B', ktalk: '#FF6B35', generic: '#5F6368',
  orange: DARK ? '#FF9F0A' : '#FF9500', red: DARK ? '#FF453A' : '#FF3B30', green: DARK ? '#32D74B' : '#28CD41',
  yellow: DARK ? '#FFD60A' : '#FFCC00', purple: DARK ? '#BF5AF2' : '#AF52DE', blue: DARK ? '#0A84FF' : '#007AFF',
  pink: DARK ? '#FF375F' : '#FF2D55', teal: DARK ? '#40C8E0' : '#30B0C7', indigo: DARK ? '#5E5CE6' : '#5856D6',
  accent: DARK ? '#0A84FF' : '#007AFF',
  free: '#73C78D', tentative: '#E6A977', busy: '#CC7683', away: '#9385CC',
};
const a = (hex, alpha) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${alpha})`;
};

// ---------- Icons (SF Symbols stand-ins) ----------
const P = {
  search: '<circle cx="11" cy="11" r="7"/><path d="m20.5 20.5-4.3-4.3"/>',
  refresh: '<path d="M20 12a8 8 0 1 1-2.35-5.65"/><path d="M20 4v5h-5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  gear: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
  power: '<path d="M12 2.5v9"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>',
  chevL: '<path d="m15 18-6-6 6-6"/>',
  chevR: '<path d="m9 18 6-6-6-6"/>',
  chevD: '<path d="m6 9 6 6 6-6"/>',
  chevU: '<path d="m6 15 6-6 6 6"/>',
  copy: '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M4 16V5a2 2 0 0 1 2-2h11"/>',
  question: '<circle cx="12" cy="12" r="9.5"/><path d="M9.2 9.2a2.9 2.9 0 0 1 5.6 1c0 1.9-2.8 2.6-2.8 2.6"/><path d="M12 17h.01"/>',
  globe: '<circle cx="12" cy="12" r="9.5"/><path d="M2.5 12h19M12 2.5a14 14 0 0 1 0 19M12 2.5a14 14 0 0 0 0 19"/>',
  envelope: '<rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
  people: '<circle cx="9" cy="8" r="3.6"/><path d="M2.5 20v-1a5 5 0 0 1 5-5h3a5 5 0 0 1 5 5v1"/><path d="M16 4.3a3.6 3.6 0 0 1 0 7.2M18.5 14.2a5 5 0 0 1 3 4.8v1"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  xmark: '<path d="M18 6 6 18M6 6l12 12"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  calendar: '<rect x="3" y="4.5" width="18" height="16.5" rx="2.5"/><path d="M3 9.5h18M8 2.5v4M16 2.5v4"/>',
  clock: '<circle cx="12" cy="12" r="9.5"/><path d="M12 6.5V12l3.5 2"/>',
  expand: '<path d="M14 3h7v7M10 21H3v-7M21 3l-7 7M3 21l7-7"/>',
  info: '<circle cx="12" cy="12" r="9.5"/><path d="M12 16v-4.5M12 8h.01"/>',
  pin: '<path d="M19 10c0 5.5-7 11.5-7 11.5S5 15.5 5 10a7 7 0 0 1 14 0Z"/><circle cx="12" cy="10" r="2.5"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>',
  sparkles: '<path d="M10 3.5 11.8 8.2 16.5 10l-4.7 1.8L10 16.5l-1.8-4.7L3.5 10l4.7-1.8Z"/><path d="M18 14.5l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9Z"/>',
  arrowR: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  grid: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 4v16M15 4v16"/>',
  list: '<path d="M9 6h12M9 12h12M9 18h12M4 6h.01M4 12h.01M4 18h.01"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  pencil: '<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  trash: '<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/>',
  tag: '<path d="M12.6 2.6H21v8.4l-9.4 9.4a2 2 0 0 1-2.8 0l-5.6-5.6a2 2 0 0 1 0-2.8Z"/><circle cx="16.5" cy="7.5" r="1.3"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.9 1.9 0 0 0 3.4 0"/>',
  keyboard: '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 13h.01M18 13h.01M9 13h6M7 16h10"/>',
  lock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  wifiOff: '<path d="M2 2l20 20M8.5 16.4a5 5 0 0 1 7 0M5 12.8a10 10 0 0 1 5.2-2.7M19 12.8a10 10 0 0 0-2-1.5M2 8.8a15 15 0 0 1 4.2-2.6M22 8.8A15 15 0 0 0 10.7 5M12 20h.01"/>',
};
const FILLED = {
  play: '<path d="M7 4.5v15l12.5-7.5Z"/>',
  sun: '<circle cx="12" cy="12" r="4.3"/><g stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 2v2.2M12 19.8V22M2 12h2.2M19.8 12H22M4.9 4.9l1.6 1.6M17.5 17.5l1.6 1.6M4.9 19.1l1.6-1.6M17.5 6.5l1.6-1.6"/></g>',
  joinCircle: '<circle cx="12" cy="12" r="10.5"/><path d="M7 12h9.5M12.5 7.5 17 12l-4.5 4.5" fill="none" stroke="var(--jc, #fff)" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>',
  video: '<rect x="1.5" y="6" width="14" height="12" rx="3"/><path d="M17 10.3 22.5 7v10L17 13.7Z"/>',
  videoCircle: '<circle cx="12" cy="12" r="10.5"/><rect x="6" y="8.6" width="8" height="6.8" rx="1.6" fill="var(--jc,#fff)"/><path d="M14.8 11 18 9v6l-3.2-2Z" fill="var(--jc,#fff)"/>',
  videoSquare: '<rect x="1.5" y="1.5" width="21" height="21" rx="5"/><rect x="5.5" y="8.3" width="8.5" height="7.4" rx="1.6" fill="var(--jc,#fff)"/><path d="M15 11l3.5-2.2v6.4L15 13Z" fill="var(--jc,#fff)"/>',
  videoBubble: '<path d="M4 3h16a2.5 2.5 0 0 1 2.5 2.5v10A2.5 2.5 0 0 1 20 18H9l-5 4v-4a2.5 2.5 0 0 1-2.5-2.5v-10A2.5 2.5 0 0 1 4 3Z"/><rect x="6" y="7.2" width="7.5" height="6.3" rx="1.4" fill="var(--jc,#fff)"/><path d="M14.3 9.6l3.2-2v6.1l-3.2-2Z" fill="var(--jc,#fff)"/>',
  checkCircle: '<circle cx="12" cy="12" r="10.5"/><path d="m7.5 12.3 3 3 6-6.3" fill="none" stroke="var(--jc,#fff)" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>',
  circle: '<circle cx="12" cy="12" r="10.5"/>',
  dlCircle: '<circle cx="12" cy="12" r="10.5"/><path d="M12 6.5v9M8 12l4 4 4-4" fill="none" stroke="var(--jc,#fff)" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>',
};

function icon(name, size = 13, color = 'currentColor', weight = 2) {
  if (FILLED[name]) {
    return `<svg class="ico" width="${size}" height="${size}" viewBox="0 0 24 24" fill="${color}" style="color:${color}">${FILLED[name]}</svg>`;
  }
  return `<svg class="ico" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="${weight}" stroke-linecap="round" stroke-linejoin="round">${P[name]}</svg>`;
}

const PLATFORM_ICON = { teams: 'video', zoom: 'videoCircle', webex: 'video', meet: 'videoBubble', ktalk: 'videoSquare', generic: null };
const platformIcon = (p, size, color) => (PLATFORM_ICON[p] ? icon(PLATFORM_ICON[p], size, color || C[p]) : '');

function avatar(name, size, color) {
  const initials = name.split(' ').slice(0, 2).map((w) => w[0]).join('');
  return `<span class="avatar" style="width:${size}px;height:${size}px;background:${a(color, 0.18)};color:${color};font-size:${Math.round(size * 0.38)}px">${initials}</span>`;
}

function ring(pct, size = 16) {
  const r = (size - 2) / 2, c = 2 * Math.PI * r;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" style="transform:rotate(-90deg)">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--fg2)" stroke-opacity=".4" stroke-width="2"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${C.accent}" stroke-width="2" stroke-linecap="round" stroke-dasharray="${c * pct} ${c}"/></svg>`;
}

// ---------- Demo data (fictional people and meetings) ----------
const PEOPLE = {
  maria: L('Мария Соколова', 'Emma Clarke'),
  alex: L('Алексей Петров', 'Liam Porter'),
  irina: L('Ирина Ковалёва', 'Olivia Hayes'),
  dmitry: L('Дмитрий Орлов', 'Noah Bennett'),
  anna: L('Анна Лебедева', 'Sophie Turner'),
  pavel: L('Павел Никитин', 'Jack Morrison'),
  olga: L('Ольга Васильева', 'Grace Miller'),
  sergey: L('Сергей Морозов', 'Ethan Brooks'),
  kate: L('Екатерина Белова', 'Chloe Adams'),
  nikita: L('Никита Фролов', 'Ryan Cooper'),
};

const hm = (s) => { const [h, m] = s.split(':').map(Number); return h * 60 + m; };
const fmt = (min) => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;

// Meetings for the demo day. Now = 10:48.
const NOW = hm('10:48');
const DAY_MEETINGS = [
  { s: '09:00', e: '09:30', t: L('Стендап команды', 'Team stand-up'), p: 'teams', org: PEOPLE.maria },
  { s: '09:30', e: '10:30', t: L('Планирование спринта', 'Sprint planning'), p: 'teams', org: PEOPLE.maria },
  { s: '10:00', e: '11:00', t: L('Архитектурный комитет', 'Architecture board'), p: 'webex', org: PEOPLE.dmitry, pending: true },
  { s: '11:00', e: '11:45', t: L('Дизайн-ревью: новый онбординг', 'Design review: new onboarding'), p: 'zoom', org: PEOPLE.irina },
  { s: '12:00', e: '12:30', t: L('Синк с мобильной командой', 'Mobile team sync'), p: 'meet', org: PEOPLE.alex },
  { s: '12:00', e: '13:00', t: L('Интервью: iOS-разработчик', 'Interview: iOS engineer'), p: 'teams', host: true },
  { s: '13:30', e: '14:30', t: L('Демо релиза 1.2', 'Release 1.2 demo'), p: 'ktalk', org: PEOPLE.pavel },
  { s: '14:30', e: '15:00', t: L('Кофе с Анной', 'Coffee with Sophie'), p: 'generic', org: PEOPLE.anna },
  { s: '15:30', e: '16:30', t: L('Разбор инцидента', 'Incident review'), p: 'zoom', org: PEOPLE.sergey },
];
const ALL_DAY = [
  { t: L('Дежурство по релизу', 'Release on-call'), c: C.orange },
  { t: L('Отпуск: Павел Никитин', 'Out of office: Jack'), c: C.green },
];

const COLLEAGUES = [
  { n: PEOPLE.maria, s: 'free', c: C.blue, st: L('Свободна до 12:00', 'Free until 12:00') },
  { n: PEOPLE.alex, s: 'busy', c: C.purple, st: L('Занят ещё 40 мин', 'Busy for 40 min more') },
  { n: PEOPLE.irina, s: 'tentative', c: C.pink, st: L('Под вопросом до 11:30', 'Tentative until 11:30') },
  { n: PEOPLE.dmitry, s: 'free', c: C.green, st: L('Свободен до 15:00', 'Free until 15:00') },
  { n: PEOPLE.pavel, s: 'away', c: C.orange, st: L('Нет на месте до пятницы', 'Away until Friday') },
  { n: PEOPLE.olga, s: 'free', c: C.teal, st: '' },
  { n: PEOPLE.sergey, s: 'busy', c: C.indigo, st: '' },
];

const TODAY_LABEL = L('Сегодня, 6 октября', 'Today, October 6');
const VERSION = 'v1.0.52';

// ---------- Popover pieces ----------
function popHeader() {
  return `<div class="row pop-header"><span>Mac Owa Widget</span><span class="spacer"></span>
    <span class="icons">${icon('search', 13, 'var(--search-ic, var(--fg))')}${icon('refresh')}${icon('plus')}${icon('gear')}${icon('power')}</span></div>`;
}

function dateNav(label = TODAY_LABEL) {
  return `<div class="row datenav"><span class="chip">${icon('chevL', 12, 'var(--fg)', 2.6)}</span>
    <span>${label}</span><span class="chip r">${icon('chevR', 12, 'var(--fg)', 2.6)}</span></div>`;
}

function invitationsRow(count = 2) {
  return `<div class="row inv-row">${icon('envelope', 11, C.accent, 2.6)}<span>${L('Новые приглашения', 'New invitations')}</span>
    <span class="count" style="background:${a(C.accent, 0.18)};color:${C.accent}">${count}</span><span class="spacer"></span>${icon('chevD', 9, 'var(--fg2)', 3)}</div>`;
}

function nextBanner(m, inText) {
  const col = C[m.p];
  return `<div class="banner" style="background:${a(col, 0.08)};box-shadow:inset 0 0 0 1px ${a(col, 0.25)}">
    <div class="row l1">${icon('play', 9, 'var(--fg2)')}<span>${inText}</span><span class="spacer"></span>${platformIcon(m.p, 12)}</div>
    <div class="l2">${m.t}</div>
    <div class="row l3"><span>${m.s}–${m.e} · ${m.org}</span><span class="spacer"></span>${icon('copy', 12, 'var(--fg2)')}
      <span class="join-btn" style="background:${col};--jc:${col}">${icon('joinCircle', 12, '#fff')}${L('Подключиться', 'Join')}</span></div></div>`;
}

// Greedy column assignment for overlapping clusters (TimelineMeetingLayout).
function layoutDay(meetings) {
  const items = meetings.map((m) => ({ ...m, s0: hm(m.s), e0: hm(m.e) })).sort((x, y) => x.s0 - y.s0 || y.e0 - x.e0);
  const clusters = [];
  let cur = null;
  for (const it of items) {
    if (!cur || it.s0 >= cur.end) { cur = { items: [], end: 0 }; clusters.push(cur); }
    cur.items.push(it); cur.end = Math.max(cur.end, it.e0);
  }
  for (const cl of clusters) {
    const colsEnd = [];
    for (const it of cl.items) {
      let c = colsEnd.findIndex((end) => end <= it.s0);
      if (c < 0) { c = colsEnd.length; colsEnd.push(0); }
      colsEnd[c] = it.e0; it.col = c;
    }
    cl.items.forEach((it) => { it.cols = colsEnd.length; });
  }
  return items;
}

function timeline(width, { meetings = DAY_MEETINGS, startMin = hm('08:30'), now = NOW, selected = null } = {}) {
  const left = 78, avail = width - left - 12;
  let html = `<div class="tl-inner" style="transform:translateY(${-startMin}px)">`;
  const slot = Math.floor(now / 30) * 30;
  html += `<div class="tl-now" style="top:${slot}px;background:${a(C.accent, 0.08)}"></div>`;
  for (let h = 0; h < 24; h++) {
    html += `<div class="tl-line" style="top:${h * 60}px"></div><div class="tl-hour" style="top:${h * 60 + 6}px">${fmt(h * 60)}</div>`;
  }
  for (const m of layoutDay(meetings)) {
    const col = C[m.p];
    const w = avail / m.cols, x = left + m.col * w, dur = m.e0 - m.s0;
    const compact = m.cols > 1, short = dur <= 30;
    const past = m.e0 <= now, live = m.s0 <= now && now < m.e0;
    const sel = selected === m.t;
    const showOrg = m.org && (m.cols === 1 || (m.col > 0 && dur >= 60));
    const cls = ['blk', compact && 'compact', short && 'short'].filter(Boolean).join(' ');
    const border = sel ? `inset 0 0 0 1.5px ${col}` : `inset 0 0 0 ${live ? 1.5 : 1}px ${a(col, 0.28)}`;
    html += `<div class="${cls}" style="--c:${col};left:${x}px;top:${m.s0}px;width:${w}px;height:${dur}px;background:${a(col, sel ? 0.2 : 0.13)};box-shadow:${border};opacity:${past ? 0.58 : 1}">
      <div class="t" style="padding-right:${compact ? 16 : 40}px">${m.t}</div>
      <div class="row m"><b>${m.s}–${m.e}</b>${m.pending ? icon('question', compact ? 8 : 9, 'var(--fg2)') : ''}${m.host ? `<span class="badge-org">${L('Орг.', 'Host')}</span>` : ''}${showOrg ? `<span>· ${m.org}</span>` : ''}</div>
      ${m.p !== 'generic' ? `<div class="acts">${compact ? '' : `<span style="margin-top:3px">${icon('copy', 11, 'var(--fg2)')}</span>`}<span style="margin-top:${compact ? 1 : 2}px;--jc:${DARK ? '#1e1e20' : '#fff'}">${icon('joinCircle', compact ? 13 : 14, col)}</span></div>` : ''}
    </div>`;
  }
  return html + '</div>';
}

function allDayRow(items = ALL_DAY) {
  return `<div class="row allday"><span class="gutter">${icon('sun', 11, 'var(--fg2)')}</span><span class="pills">${items
    .map((x) => `<span class="pill" style="background:${a(x.c, 0.18)};box-shadow:inset 0 0 0 1px ${a(x.c, 0.32)}">${x.t}</span>`).join('')}</span></div>`;
}

function colleaguesHeader(expanded = false) {
  const right = expanded
    ? `<span style="font-size:10px;font-weight:600;color:${C.free};background:${a(C.free, 0.18)};padding:2px 6px;border-radius:4px">${L('3 из 7 свободны', '3 of 7 free')}</span>`
    : `<span class="row" style="gap:3px">${COLLEAGUES.map((c) => `<span style="border-radius:50%;box-shadow:0 0 0 1.5px ${C[c.s]};opacity:${c.s === 'free' ? 1 : 0.55};display:inline-flex">${avatar(c.n, 18, c.c)}</span>`).join('')}</span>`;
  return `<div class="row coll-head">${icon('people', 11, 'var(--fg2)')}<span>${L('Коллеги', 'Colleagues')}</span><span class="spacer"></span>${right}
    <span style="margin-left:4px">${icon('plus', 11, 'var(--fg)')}</span>${icon(expanded ? 'chevU' : 'chevD', 10, 'var(--fg2)', 2.6)}</div>`;
}

function colleaguesList(n = 5) {
  return COLLEAGUES.slice(0, n).map((c) => {
    const [first, last] = c.n.split(' ');
    const short = LANG === 'ru' ? `${last} ${first[0]}.` : c.n;
    const joinable = c.s === 'free' || c.s === 'tentative';
    return `<div class="row coll-row">${avatar(c.n, 20, c.c)}<span>${short}</span><span class="spacer"></span>
      <span class="dot" style="width:7px;height:7px;background:${C[c.s]}"></span><span class="st">${c.st}</span>
      <span style="width:16px;display:inline-flex;justify-content:center;--jc:${DARK ? '#1e1e20' : '#fff'}">${icon('joinCircle', 15, joinable ? C.accent : 'var(--fg3)')}</span></div>`;
  }).join('');
}

function footer({ status = L('Синхронизировано только что', 'Synced just now') } = {}) {
  return `<div class="row footer"><span>${status}</span><span class="spacer"></span>
    <span class="row" style="gap:5px">${ring(0.73)}<b style="font-weight:600">73%</b></span>${icon('expand', 10, 'var(--fg2)')}<span>${VERSION}</span></div>`;
}

// Full popover. mode: 'day' | 'search'. overlay: extra HTML drawn over the popover (detail card).
function popover({ w = 480, h = 700, mode = 'day', banner = true, invitations = true, colleagues = 'collapsed', startMin, selected, searchBody = '', overlay = '' } = {}) {
  const dm = DAY_MEETINGS[3];
  let body = '';
  if (mode === 'search') {
    body = `<div class="divider"></div><div class="row search-field">${icon('search', 13, 'var(--fg3)')}<span>${L('ревью', 'review')}<i class="caret"></i></span><span class="spacer"></span><svg class="ico" width="13" height="13" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10.5" fill="var(--fg3)"/><path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="var(--win)" stroke-width="2.4" stroke-linecap="round"/></svg></div><div class="divider"></div>${searchBody}`;
  } else {
    body = `<div class="divider"></div>${dateNav()}<div class="divider"></div>
      ${invitations ? invitationsRow() + '<div class="divider"></div>' : ''}
      ${banner ? nextBanner(dm, L('через 12 мин', 'in 12 min')) + '<div class="divider" style="margin-top:8px"></div>' : ''}
      <div class="sticky-day">${TODAY_LABEL}</div>${allDayRow()}
      <div class="timeline">${timeline(w, { startMin, selected })}</div>`;
  }
  const coll = colleagues === 'none' ? '' : `<div class="divider"></div>${colleaguesHeader(colleagues === 'expanded')}${colleagues === 'expanded' ? colleaguesList() : ''}`;
  return `<div class="window" style="width:${w}px;height:${h}px;${mode === 'search' ? `--search-ic:${C.accent}` : ''}">
    ${popHeader()}${body}${coll}<div class="divider"></div>${footer()}${overlay}</div>`;
}

// ---------- Menu bar strip ----------
function menuBar({ width, items, highlight = true }) {
  return `<div class="menubar" style="width:${width}px">
    <span class="mb-left"><b>&#63743;</b><b>${L('Finder', 'Finder')}</b><span>${L('Файл', 'File')}</span><span>${L('Правка', 'Edit')}</span><span>${L('Вид', 'View')}</span></span>
    <span class="spacer"></span>${items}
    <span class="mb-ic">${icon('wifi', 14)}</span><span>${L('Вт 6 окт.', 'Tue Oct 6')}&nbsp;&nbsp;10:48</span></div>`;
}
