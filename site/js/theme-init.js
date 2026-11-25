/* Apply the saved or requested theme before the stylesheet loads. */
(function () {
  var params = new URLSearchParams(location.search);
  var t = params.get('theme');
  if (!t) {
    try { t = localStorage.getItem('lv-theme'); } catch (e) {}
  }
  if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
  document.documentElement.dataset.js = '';
  if (params.get('motion') === 'still') {
    document.documentElement.dataset.heroMotion = 'still';
  } else if (!(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches)) {
    /* The demos will animate, so the first paint shows their starting frame, not the finished one. */
    document.documentElement.dataset.motion = 'on';
  }
})();
