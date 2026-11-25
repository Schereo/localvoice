import { waveformHeights as seq } from './waveform.js';

export function setupDictationDemo(still) {
  var stage = document.querySelector('.stage');
  var control = document.querySelector('.demo-control');
  if (!stage || !control) return;
  var controlLabel = control.querySelector('.demo-control-label');
  var landed = stage.querySelector('.landed');
  var note = stage.querySelector('.stage-note');
  var pill = stage.querySelector('.pill-voice');
  var transcript = pill.querySelector('.transcript');
  var timer = pill.querySelector('time');
  var bars = Array.prototype.slice.call(pill.querySelectorAll('.wave i'));
  var lang = stage.querySelector('.lang');
  /* Each phrase is spoken in chunks; the pause between chunks confirms the first one.
     The third entry names where the text lands, so every round is a different place. */
  var phrases = [
    [["Let's move the review to Thursday.", "I'll bring the numbers."], 'EN', 'Meeting notes'],
    [['Kannst du mir die Unterlagen', 'bis Freitag schicken?'], 'DE', 'Message to Jonas'],
    [['Fix the race in the onset buffer', 'and add a regression test.'], 'EN', 'Commit message']
  ];
  var index = 0, current = null;
  /* With motion on, the demo loops while it is on screen until someone pauses it. */
  var looping = !still, inView = false, nextTimer = null;
  var HOLD_MS = 3200;
  var speakingUntil = 0, level = 0, meter = null, clock = null;

  function setControl(action, label) {
    control.dataset.action = action;
    controlLabel.textContent = label;
  }

  function wait(ms, signal) {
    return new Promise(function (resolve) {
      if (signal.aborted) { resolve(false); return; }
      var timeout = setTimeout(function () {
        signal.removeEventListener('abort', abort);
        resolve(true);
      }, ms);
      function abort() { clearTimeout(timeout); resolve(false); }
      signal.addEventListener('abort', abort, { once: true });
    });
  }

  /* The waveform follows the voice: lively during words, near flat in pauses. */
  function startMeter() {
    var started = Date.now(), n = 0;
    timer.textContent = '00:00';
    clock = setInterval(function () {
      var s = Math.floor((Date.now() - started) / 1000);
      timer.textContent = '00:' + (s < 10 ? '0' : '') + s;
    }, 250);
    if (still) return;
    meter = setInterval(function () {
      n++;
      var target = Date.now() < speakingUntil ? .55 + .45 * Math.abs(Math.sin(n * 1.7)) : .04;
      level += (target - level) * (target > level ? .7 : .35);
      stage.style.setProperty('--level', level.toFixed(2));
      bars.forEach(function (bar, i) {
        var wobble = .55 + .45 * Math.abs(Math.sin(n * 1.3 + i * 2.1));
        bar.style.transform = 'scaleY(' + Math.max(.14, level * seq[i % seq.length] * wobble * 1.15).toFixed(2) + ')';
      });
    }, 90);
  }
  function stopMeter() {
    clearInterval(meter); clearInterval(clock);
    level = 0; stage.style.setProperty('--level', '0');
    if (!still) bars.forEach(function (bar) { bar.style.transform = 'scaleY(.14)'; });
  }

  /* Transcript: confirmed words in full ink, the running guess dimmed, at most two lines. */
  var conf = [], guess = [];
  function render(fresh) {
    var maxH = parseFloat(getComputedStyle(transcript).lineHeight) * 2 + 20;
    var drop = 0;
    do {
      transcript.textContent = '';
      var c = conf.slice(drop), g = guess.slice(Math.max(0, drop - conf.length));
      if (drop) transcript.appendChild(document.createTextNode('… '));
      if (c.length) transcript.appendChild(document.createTextNode(c.join(' ') + ' '));
      if (g.length) {
        var span = document.createElement('span');
        span.className = 'guess';
        span.appendChild(document.createTextNode(g.slice(0, -1).join(' ') + (g.length > 1 ? ' ' : '')));
        var last = document.createElement('span');
        if (fresh) last.className = 'w';
        last.textContent = g[g.length - 1];
        span.appendChild(last);
        transcript.appendChild(span);
      }
      drop++;
    } while (transcript.offsetHeight > maxH && drop < conf.length + guess.length);
  }

  async function speak(chunks, signal) {
    if (!await wait(450, signal)) return false;
    for (var ci = 0; ci < chunks.length; ci++) {
      for (var word of chunks[ci].split(' ')) {
        var ms = 170 + word.length * 48;
        speakingUntil = Date.now() + ms - 60;
        guess.push(word);
        render(true);
        if (!await wait(ms, signal)) return false;
      }
      /* A pause: the phrase is confirmed and turns to full ink. */
      var more = ci < chunks.length - 1;
      if (!await wait(more ? 520 : 420, signal)) return false;
      conf = conf.concat(guess);
      guess = [];
      render(false);
      if (!await wait(more ? 260 : 380, signal)) return false;
    }
    return true;
  }

  /* The finished sentence travels from the pill to the caret. */
  function land(text) {
    var from = transcript.getBoundingClientRect();
    var fromSize = parseFloat(getComputedStyle(transcript).fontSize);
    landed.textContent = text;
    landed.classList.add('fly');
    stage.classList.add('flying');
    var to = landed.getBoundingClientRect();
    var scale = fromSize / parseFloat(getComputedStyle(landed).fontSize);
    var done = function () { landed.classList.remove('fly'); stage.classList.remove('flying'); };
    if (!landed.animate) { done(); return; }
    landed.animate([
      { transform: 'translate(' + (from.left - to.left + 6) + 'px,' + (from.top - to.top + 15) + 'px) scale(' + scale + ')', opacity: .75 },
      { transform: 'none', opacity: 1 }
    ], { duration: 820, easing: 'cubic-bezier(.16, 1, .3, 1)' }).onfinish = done;
  }

  function finish(run, animate) {
    if (current !== run) return;
    current = null;
    run.controller.abort();
    stopMeter();
    lang.textContent = 'Detected ' + run.phrase[1];
    var text = run.phrase[0].join(' ');
    if (animate) land(text);
    else landed.textContent = text;
    stage.dataset.state = 'done';
    delete stage.dataset.playing;
    if (still) setControl('replay', 'Replay demo');
    else if (looping) { setControl('pause', 'Pause demo'); scheduleNext(); }
    else setControl('play', 'Play demo');
  }

  function scheduleNext() {
    clearTimeout(nextTimer);
    nextTimer = setTimeout(function () {
      nextTimer = null;
      if (looping && inView) play();
    }, HOLD_MS);
  }

  async function play() {
    if (current) return;
    clearTimeout(nextTimer);
    nextTimer = null;
    var run = { phrase: phrases[index++ % phrases.length], controller: new AbortController() };
    var signal = run.controller.signal;
    current = run;
    if (landed.getAnimations) landed.getAnimations().forEach(function (animation) { animation.cancel(); });
    landed.classList.remove('fly');
    stage.classList.remove('flying');
    conf = []; guess = [];
    speakingUntil = 0;
    stage.dataset.playing = '';
    stage.dataset.state = 'idle';
    setControl(still ? 'skip' : 'pause', still ? 'Skip demo' : 'Pause demo');
    /* The previous sentence fades out before the next one is spoken. */
    if (!still && landed.textContent && landed.animate) {
      landed.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 320, easing: 'ease-out', fill: 'forwards' });
      if (!await wait(320, signal)) return;
    }
    if (landed.getAnimations) landed.getAnimations().forEach(function (animation) { animation.cancel(); });
    landed.textContent = '';
    if (note.textContent !== run.phrase[2]) {
      note.textContent = run.phrase[2];
      if (!still && note.animate) note.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 360, easing: 'ease-out' });
    }
    if (!await wait(still ? 0 : 500, signal)) return;
    transcript.textContent = '';
    stage.dataset.state = 'rec';
    startMeter();
    if (await speak(run.phrase[0], signal)) finish(run, !still);
  }

  control.addEventListener('click', function () {
    if (still) {
      if (current) finish(current, false);
      else play();
    } else if (looping) {
      looping = false;
      clearTimeout(nextTimer);
      nextTimer = null;
      if (current) finish(current, false);
      setControl('play', 'Play demo');
    } else {
      looping = true;
      setControl('pause', 'Pause demo');
      play();
    }
  });
  setControl('play', 'Play demo');
  control.hidden = false;
  if (still) return;
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function ([entry]) {
      inView = entry.isIntersecting;
      if (inView && looping && !current && !nextTimer) play();
    }, { threshold: 0.2 }).observe(stage);
  } else {
    inView = true;
    play();
  }
}
