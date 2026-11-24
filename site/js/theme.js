export function setupThemeToggle() {
  const root = document.documentElement;
  const toggle = document.querySelector('.theme-toggle');
  if (!toggle) return;
  const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');
  const isDark = () => root.dataset.theme ? root.dataset.theme === 'dark' : systemTheme.matches;
  const update = () => toggle.setAttribute('aria-pressed', String(isDark()));

  toggle.addEventListener('click', () => {
    const next = isDark() ? 'light' : 'dark';
    root.dataset.theme = next;
    update();
    try { localStorage.setItem('lv-theme', next); } catch (e) {}
  });
  systemTheme.addEventListener('change', update);
  update();
  toggle.hidden = false;
}
