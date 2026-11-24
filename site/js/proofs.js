export function setupModelTransfer(still) {
  const transfer = document.querySelector('.model-transfer');
  if (!transfer || still || !('IntersectionObserver' in window)) return;

  const observer = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return;
    transfer.classList.add('is-playing');
    observer.disconnect();
  }, { threshold: 0.6 });

  observer.observe(transfer);
}
