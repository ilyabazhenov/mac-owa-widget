(function () {
  var ru = document.documentElement.lang === 'ru';

  // Language: each version has its own URL; the RU/EN links remember the choice
  // so the root page stops redirecting, and keep the section the visitor is on.
  document.querySelectorAll('[data-lang]').forEach(function (a) {
    a.addEventListener('click', function () {
      try { localStorage.setItem('owa-lang', a.dataset.lang); } catch (e) {}
      a.href = a.getAttribute('href') + location.hash;
    });
  });

  // Theme: follows the system until the visitor picks one.
  var themeButton = document.getElementById('theme');
  var themeMedia = window.matchMedia('(prefers-color-scheme: dark)');
  function currentTheme() { return document.documentElement.dataset.theme || (themeMedia.matches ? 'dark' : 'light'); }
  function labelTheme() {
    var dark = currentTheme() === 'dark';
    var label = dark ? (ru ? 'Светлая тема' : 'Light theme') : (ru ? 'Тёмная тема' : 'Dark theme');
    themeButton.setAttribute('aria-label', label);
    themeButton.title = label;
  }
  themeButton.addEventListener('click', function () {
    var next = currentTheme() === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('owa-theme', next); } catch (e) {}
    labelTheme();
  });
  if (!document.documentElement.dataset.theme) document.documentElement.dataset.theme = currentTheme();
  themeMedia.addEventListener('change', function () {
    var saved = null;
    try { saved = localStorage.getItem('owa-theme'); } catch (e) {}
    if (!saved) { document.documentElement.dataset.theme = themeMedia.matches ? 'dark' : 'light'; labelTheme(); }
  });
  labelTheme();

  // The section for the visitor's current hour gets the "now" dot.
  function tick() {
    var d = new Date(), mins = d.getHours() * 60 + d.getMinutes();
    var current = null;
    document.querySelectorAll('.slot[data-t]').forEach(function (s) {
      var p = s.dataset.t.split(':');
      s.classList.remove('is-now');
      if (+p[0] * 60 + +p[1] <= mins) current = s;
    });
    if (current) current.classList.add('is-now');
  }
  tick();
  setInterval(tick, 30000);

  // Latest version from GitHub; the static label stays if the request fails.
  fetch('https://api.github.com/repos/ilyabazhenov/mac-owa-widget/releases/latest')
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (j) { if (j && j.tag_name) document.getElementById('version').textContent = j.tag_name; })
    .catch(function () {});
})();
