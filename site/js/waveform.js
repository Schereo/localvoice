/* Waveform bars. Heights come from a fixed sequence so every load looks the same. */
export const waveformHeights = [.35, .5, .3, .62, .8, .45, .7, .95, .55, .78, .4, .88, .6, .98, .5, .72, .36, .64, .85, .42, .58, .3, .7, .48, .9, .38];

export function setupWaveforms() {
  document.querySelectorAll('.wave').forEach(function (wave) {
    var n = parseInt(wave.getAttribute('data-bars'), 10) || 20;
    for (var i = 0; i < n; i++) {
      var bar = document.createElement('i');
      var h = waveformHeights[i % waveformHeights.length];
      bar.style.setProperty('--h', h);
      bar.style.setProperty('--t', (0.55 + ((i * 37) % 50) / 100) + 's');
      bar.style.setProperty('--d', (-((i * 53) % 90) / 100) + 's');
      if (wave.hasAttribute('data-static')) bar.style.transform = 'scaleY(' + h + ')';
      wave.appendChild(bar);
    }
  });
}
