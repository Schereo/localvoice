/* Apply the saved or requested theme before the stylesheet loads. */
(function () {
  var params = new URLSearchParams(location.search);
  var t = params.get('theme');
  if (!t) {
    try { t = localStorage.getItem('lv-theme'); } catch (e) {}
  }
  if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
  if (params.get('motion') === 'still') {
    document.documentElement.dataset.heroMotion = 'still';
  }
})();
