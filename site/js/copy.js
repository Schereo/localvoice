// Copy buttons: data-copy-target names the element whose text is copied
// (decorative parts marked aria-hidden, like the shell prompt, are left out).
export function setupCopyButtons() {
  for (const button of document.querySelectorAll('[data-copy-target]')) {
    const target = document.getElementById(button.dataset.copyTarget);
    const label = button.querySelector('.brew-copy-text');
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
      if (label) label.textContent = 'Copied';
      clearTimeout(reset);
      reset = setTimeout(() => {
        button.classList.remove('is-copied');
        if (label) label.textContent = 'Copy';
      }, 1600);
    });
  }
}
