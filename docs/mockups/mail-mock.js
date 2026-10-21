// Mail design sketches: extra icons, fictional mail data and the mail window builder.
// Load after mock.js. Spec: docs/superpowers/specs/2026-10-17-mail-design.md

Object.assign(P, {
  clip: '<path d="m21 11-8.6 8.6a5.5 5.5 0 0 1-7.8-7.8l8.9-8.9a3.7 3.7 0 0 1 5.2 5.2l-8.9 8.9a1.8 1.8 0 0 1-2.6-2.6l8.1-8.1"/>',
  reply: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5A5.5 5.5 0 0 1 20 14.5V20"/>',
  replyAll: '<path d="M7 14 2 9l5-5"/><path d="M12 14 7 9l5-5"/><path d="M7 9h8.5A5.5 5.5 0 0 1 21 14.5V20"/>',
  forward: '<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5V20"/>',
  tray: '<path d="M3 13h5l1.5 3h5L16 13h5"/><path d="M5.5 5h13L21 13v6a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-6Z"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.5h8.5A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5Z"/>',
  doc: '<path d="M14 3H6.5A1.5 1.5 0 0 0 5 4.5v15A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V8Z"/><path d="M14 3v5h5"/>',
  send: '<path d="M21.5 2.5 11 13"/><path d="m21.5 2.5-7 19-3.5-8.5-8.5-3.5Z"/>',
  archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  envOpen: '<path d="M3 10 12 4l9 6v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/><path d="m3 10 9 6 9-6"/>',
  shield: '<path d="M12 3 4.5 6v5.5c0 4.6 3.2 8.4 7.5 9.5 4.3-1.1 7.5-4.9 7.5-9.5V6Z"/>',
  warn: '<path d="M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/>',
  ext: '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  compose: '<path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M17.5 2.5a2.1 2.1 0 0 1 3 3L12 14l-4 1 1-4Z"/>',
  eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
});

const ME = L('Андрей Кузнецов', 'Alex Morgan');
const PARTNER = 'Thomas Wright';
const MAIL = {
  olga: { n: PEOPLE.olga, e: L('o.vasilyeva', 'g.miller') + '@company.com', c: C.teal },
  dmitry: { n: PEOPLE.dmitry, e: L('d.orlov', 'n.bennett') + '@company.com', c: C.green },
  anna: { n: PEOPLE.anna, e: L('a.lebedeva', 's.turner') + '@company.com', c: C.pink },
  sergey: { n: PEOPLE.sergey, e: L('s.morozov', 'e.brooks') + '@company.com', c: C.indigo },
  partner: { n: PARTNER, e: 't.wright@partner-corp.com', c: C.orange, ext: true },
  me: { n: ME, e: L('a.kuznetsov', 'a.morgan') + '@company.com', c: C.blue },
};

const CAT = { green: { c: C.green, n: L('Зелёная категория', 'Green category') }, purple: { c: C.purple, n: L('Релиз', 'Release') } };

// Inbox, newest first. Fictional people, company.com / partner-corp.com.
const THREADS = [
  { id: 'release', from: PEOPLE.olga, s: L('Релиз 1.3: финальный чек-лист', 'Release 1.3: final checklist'), t: '10:42', n: 3, unread: true, att: true, cat: 'purple',
    p: L('Коллеги, собрала всё, что осталось до пятницы. Нужны ваши подтверждения по трём пунктам до 15:00.', 'Folks, here is everything left before Friday. I need your sign-off on three items by 3 pm.') },
  { id: 'jira', from: 'Jira', s: '[MOB-1824] ' + L('Краш при открытии профиля', 'Crash when opening the profile'), t: '10:15', n: 1, unread: true,
    p: L('Никита Фролов изменил статус: In Progress → Code Review. Комментарий: «Фикс в ветке mob-1824».', 'Ryan Cooper changed the status: In Progress → Code Review. Comment: “Fix is on mob-1824”.') },
  { id: 'arch', from: `${PEOPLE.dmitry}, ${PEOPLE.anna}`, s: L('Итоги ревью архитектуры платежей', 'Payments architecture review: outcome'), t: '09:58', n: 4, unread: true, imp: true, cat: 'green',
    p: L('Решили идти с очередью на стороне шлюза. Протокол и открытые вопросы во вложении.', 'We are going with the gateway-side queue. Notes and open questions are attached.') },
  { id: 'contract', from: PARTNER, s: L('Договор на поддержку — правки v2', 'Support contract — revision 2'), t: L('Вчера', 'Yesterday'), n: 2, att: true, ext: true,
    p: L('Hi, please find attached the updated draft. We accepted most of your comments except section 4.2.', 'Hi, please find attached the updated draft. We accepted most of your comments except section 4.2.') },
  { id: 'incident', from: PEOPLE.sergey, s: L('Разбор инцидента 14 октября', 'Incident review, October 14'), t: L('Вчера', 'Yesterday'), n: 1,
    p: L('Таймлайн и действия по итогам. Повторная проверка мониторинга — в четверг.', 'Timeline and follow-ups. Monitoring re-check is on Thursday.') },
  { id: 'hr', from: L('HR-команда', 'People team'), s: L('Опрос вовлечённости: осталось 3 дня', 'Engagement survey: 3 days left'), t: L('Пн', 'Mon'), n: 1,
    p: L('Спасибо всем, кто уже ответил! Опрос анонимный и займёт около 10 минут.', 'Thanks to everyone who has answered! The survey is anonymous and takes about 10 minutes.') },
  { id: 'build', from: 'Jenkins', s: L('Сборка #205: нестабильные тесты', 'Build #205: flaky tests'), t: L('Пн', 'Mon'), n: 1, att: true,
    p: L('3 теста упали и прошли при повторе: PaymentFlowTests, ProfileSnapshotTests…', '3 tests failed and then passed on retry: PaymentFlowTests, ProfileSnapshotTests…') },
];

const FOLDERS = [
  { i: 'tray', n: L('Входящие', 'Inbox'), u: 12, sel: true },
  { i: 'doc', n: L('Черновики', 'Drafts'), u: 1, muted: true },
  { i: 'send', n: L('Отправленные', 'Sent') },
  { i: 'archive', n: L('Архив', 'Archive') },
  { i: 'trash', n: L('Удалённые', 'Deleted') },
];
const PINNED = [
  { i: 'folder', n: 'Jira', u: 4 },
  { i: 'folder', n: L('Сборки', 'Builds'), u: 3 },
  { i: 'folder', n: L('Релизы', 'Releases') },
];

const fileType = (name) => {
  const ext = name.split('.').pop().toUpperCase();
  const col = { XLSX: '#1D6F42', PDF: '#D93025', DOCX: '#2B579A', PNG: C.purple }[ext] || '#8E8E93';
  return `<span class="ft" style="background:${col}">${ext}</span>`;
};
const attachment = (name, size) => `<span class="att">${fileType(name)}<span class="col"><span>${name}</span><span class="sz">${size}</span></span>
  <span style="margin-left:6px" class="row">${icon('eye', 13, 'var(--fg2)')}<span style="width:8px"></span>${icon('dlCircle', 15, 'var(--fg3)')}</span></span>`;

function threadRow(th, { sel = false, hl = null, folder = null } = {}) {
  const mark = (s) => (hl ? s.replace(new RegExp(`(${hl})`, 'gi'), '<span class="hl">$1</span>') : s);
  return `<div class="thr ${th.unread ? 'unread' : ''} ${sel ? 'sel' : ''}">${th.unread ? '<span class="dot"></span>' : ''}
    <div class="l1"><span class="from">${th.from}</span>${th.ext ? `<span class="tag ext">${L('внешний', 'external')}</span>` : ''}
      ${th.att ? icon('clip', 12, 'var(--fg2)') : ''}<span class="t">${th.t}</span></div>
    <div class="s">${th.imp ? `<b style="color:${C.red}">!</b>` : ''}${th.cat ? `<span class="cat" style="background:${CAT[th.cat].c}"></span>` : ''}
      <span class="nowrap" style="flex:1">${mark(th.s)}</span>${th.n > 1 ? `<span class="cnt">${th.n}</span>` : ''}</div>
    <div class="p">${folder ? `<span class="folder-badge">${folder}</span> ` : ''}${mark(th.p)}</div></div>`;
}

function sidebar() {
  const f = (x, sub) => `<div class="fold ${x.sel ? 'sel' : ''} ${sub ? 'sub' : ''}">${icon(x.i, 14, x.sel ? C.accent : 'var(--fg2)')}<span>${x.n}</span>${x.u ? `<span class="n" style="${x.muted ? 'font-weight:400' : ''}">${x.u}</span>` : ''}</div>`;
  return `<div class="mw-side">
    <div class="side-h">${L('Работа', 'Work')}</div>${FOLDERS.map((x) => f(x)).join('')}
    <div class="side-h">${L('Закреплённые', 'Pinned')}</div>${PINNED.map((x) => f(x)).join('')}
    <div class="side-h">${L('Все папки', 'All folders')}</div>
    <div class="fold">${icon('chevR', 10, 'var(--fg2)', 2.6)}<span class="sec">${L('Ещё 14 папок', '14 more folders')}</span></div>
    <div class="side-acc">${icon('refresh', 11, 'var(--fg2)')}${L('Обновлено в 10:47', 'Updated at 10:47')}</div>
  </div>`;
}

function toolbar({ search = '', title = L('Почта — Работа', 'Mail — Work') } = {}) {
  const field = search
    ? `<span class="mw-search active">${icon('search', 12, 'var(--fg2)')}<span style="flex:1">${search}<i class="caret"></i></span>${icon('xmark', 11, 'var(--fg2)', 2.6)}</span>`
    : `<span class="mw-search">${icon('search', 12, 'var(--fg3)')}${L('Поиск в почте', 'Search mail')}</span>`;
  return `<div class="mw-toolbar"><span class="traffic"><i></i><i></i><i></i></span><span class="ttl">${title}</span><span class="spacer"></span>
    <span class="tb-btn">${icon('compose', 15, 'var(--fg)')}</span><span class="tb-btn">${icon('refresh', 14, 'var(--fg)')}</span>${field}</div>`;
}

function readingPane({ compact = false } = {}) {
  const o = MAIL.olga;
  const bar = `<div class="read-bar">
    <span class="act">${icon('reply', 14)}${L('Ответить', 'Reply')}</span><span class="act">${icon('replyAll', 14)}${L('Всем', 'All')}</span>
    <span class="act">${icon('forward', 14)}${L('Переслать', 'Forward')}</span><span class="sep"></span>
    <span class="act" title="">${icon('envOpen', 14)}</span><span class="act">${icon('tag', 14)}</span><span class="act">${icon('folder', 14)}</span>
    <span class="act">${icon('trash', 14)}</span><span class="spacer"></span><span class="act">${icon('ext', 13)}${L('Открыть в OWA', 'Open in OWA')}</span></div>`;
  const recipients = L(`Кому: ${ME}, ${PEOPLE.dmitry}, ${PEOPLE.anna}, ${PEOPLE.alex} · Копия: ${PEOPLE.pavel} и ещё 6`,
    `To: ${ME}, ${PEOPLE.dmitry}, ${PEOPLE.anna}, ${PEOPLE.alex} · Cc: ${PEOPLE.pavel} and 6 more`);
  const body = L(
    `<span>Коллеги, привет!</span><span>Собрала всё, что осталось до релиза в пятницу. По трём пунктам нужны ваши подтверждения <b>до 15:00</b>:</span>
     <span>1. Миграция платёжного профиля — Дмитрий, подтверди, что откат проверен на стейдже.<br>2. Тексты онбординга — Анна, финальная вычитка.<br>3. Мониторинг — Сергей, алерты на новый шлюз.</span>
     <span>Чек-лист целиком — во вложении, статусы обновляю там же. Дашборд релиза: <u style="color:var(--accent)">grafana.company.com/d/release-1-3</u></span>
     <span>Спасибо!<br>Ольга</span>`,
    `<span>Hi all,</span><span>Here is everything left before Friday’s release. I need your sign-off on three items <b>by 3 pm</b>:</span>
     <span>1. Payment profile migration — Noah, please confirm the rollback was tested on staging.<br>2. Onboarding copy — Sophie, final proofread.<br>3. Monitoring — Ethan, alerts for the new gateway.</span>
     <span>The full checklist is attached, I keep the statuses there. Release dashboard: <u style="color:var(--accent)">grafana.company.com/d/release-1-3</u></span>
     <span>Thanks!<br>Grace</span>`);
  return `<div class="mw-read">${bar}<div class="read-scroll">
    <div class="read-subj">${THREADS[0].s}</div>
    <div class="read-meta"><span class="row" style="gap:5px"><span class="cat" style="background:${CAT.purple.c}"></span>${CAT.purple.n}</span><span>·</span><span>${L('3 письма', '3 messages')}</span><span>·</span><span>${L('Входящие', 'Inbox')}</span></div>
    <div class="msg"><div class="msg-h">${avatar(o.n, 30, o.c)}<span class="col" style="gap:2px;min-width:0"><span class="who">${o.n}</span><span class="rc">${recipients}</span></span><span class="t">${L('Сегодня, 10:42', 'Today, 10:42')}</span></div>
      <div class="msg-b">${body}
        <span class="link-hover">${L('Ссылка ведёт на', 'Link goes to')} https://grafana.company.com/d/release-1-3</span>
        <span class="row" style="gap:8px;flex-wrap:wrap">${attachment(L('чек-лист-релиза-1.3.xlsx', 'release-1.3-checklist.xlsx'), L('48 КБ', '48 KB'))}${compact ? '' : attachment(L('план-отката.pdf', 'rollback-plan.pdf'), L('312 КБ', '312 KB'))}</span>
      </div></div>
    <div class="msg collapsed"><div class="msg-h">${avatar(MAIL.dmitry.n, 24, MAIL.dmitry.c)}<span class="col" style="gap:1px;min-width:0;flex:1"><span class="who" style="font-size:12px">${MAIL.dmitry.n}</span>
      <span class="snip">${L('Откат проверил вчера вечером, логи приложил в тикет. По миграции — ок.', 'Tested the rollback last night, logs are in the ticket. Migration is fine.')}</span></span><span class="t">${L('Вчера, 19:20', 'Yesterday, 19:20')}</span></div></div>
    ${compact ? '' : `<div class="msg collapsed"><div class="msg-h">${avatar(o.n, 24, o.c)}<span class="col" style="gap:1px;min-width:0;flex:1"><span class="who" style="font-size:12px">${o.n}</span>
      <span class="snip">${L('Предлагаю зафиксировать дату релиза на пятницу и собрать чек-лист к среде.', 'Let’s lock Friday as the release date and have the checklist ready by Wednesday.')}</span></span><span class="t">${L('Пн, 16:05', 'Mon, 16:05')}</span></div></div>`}
    <div class="notice">${icon('shield', 13, 'var(--fg2)')}${L('Внешние картинки не загружены.', 'External images are blocked.')}<span style="color:var(--accent)">${L('Загрузить для этого письма', 'Load for this message')}</span></div>
  </div></div>`;
}

function mailWindow({ w = 1180, h = 740, list, read, search = '', title } = {}) {
  return `<div class="window mw" style="width:${w}px;height:${h}px">${toolbar({ search, title })}<div class="divider"></div>
    <div class="mw-body">${sidebar()}${list}${read || readingPane()}</div></div>`;
}

function inboxList() {
  return `<div class="mw-list"><div class="list-h">${L('Входящие', 'Inbox')}<span class="count" style="background:${a(C.accent, 0.18)};color:${C.accent}">12</span><span class="spacer"></span>
    <span class="seg" style="font-size:11px"><span class="on">${L('Все', 'All')}</span><span>${L('Непрочитанные', 'Unread')}</span></span></div><div class="divider"></div>
    ${THREADS.map((t, i) => threadRow(t, { sel: i === 0 })).join('')}
    <div class="list-foot">${icon('chevD', 10, 'var(--fg2)', 2.6)}${L('Ещё 25 — подгрузятся при прокрутке', '25 more load as you scroll')}</div></div>`;
}
