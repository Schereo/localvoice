import { setupCopyButtons } from './copy.js';
import { setupDictationDemo } from './dictation-demo.js';
import { setupModelTransfer } from './proofs.js';
import { setupThemeToggle } from './theme.js';
import { setupWaveforms } from './waveform.js';

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const still = reducedMotion || document.documentElement.dataset.heroMotion === 'still';

setupThemeToggle();
setupCopyButtons();
setupWaveforms();
setupDictationDemo(still);
setupModelTransfer(still);
