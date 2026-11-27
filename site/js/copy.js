// Copy buttons: data-copy-target names the element whose text is copied
// (decorative parts marked aria-hidden, like the shell prompt, are left out).
export function setupCopyButtons() {
  // Fade the end of a command line only while it is actually cut off.
  const lines = document.querySelectorAll('.brew-box code');
  const markClipped = () => lines.forEach((line) => {
    line.classList.toggle('is-clipped', line.scrollWidth > line.clientWidth + 1);
  });
  markClipped();
  if ('ResizeObserver' in window) {
    const observer = new ResizeObserver(markClipped);
    lines.forEach((line) => observer.observe(line.parentElement));
  }

  for (const button of document.querySelectorAll('[data-copy-target]')) {
    const target = document.getElementById(button.dataset.copyTarget);
    const label = button.getAttribute('aria-label');
    if (!target) continue;
    let reset;
    button.addEventListener('click', async () => {
      const clone = target.cloneNode(true);
      clone.querySelectorAll('[aria-hidden="true"]').forEach((node) => node.remove());
      const text = clone.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // Older browsers or a denied permission: select the text instead.
        const range = document.createRange();
        range.selectNodeContents(target);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        return;
      }
      button.classList.add('is-copied');
      button.setAttribute('aria-label', 'Copied');
      clearTimeout(reset);
      reset = setTimeout(() => {
        button.classList.remove('is-copied');
        button.setAttribute('aria-label', label);
      }, 1600);
    });
  }
}
