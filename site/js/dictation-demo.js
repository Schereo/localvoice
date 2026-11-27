/* The recording pill, as the app draws it: a circle at the hotkey that grows
   into the pill, folds back into a circle while the text is transcribed, and
   turns its spinning arc into a green check, at which point the text lands at
   the cursor above. Two dictations make one cycle: the second sentence is
   added to the first, then the text clears and it starts over. One clock
   drives every frame, so scrolling away simply stops the clock. Timings and
   curves follow the overlay in src/ctrlspeak-overlay.swift. */

const SEED = 12, CIRCLE = 44, PILL = 240, ARC_R = 12.5, CHECK_R = 6.6;
// Phase boundaries in seconds.
const T = {
  appear: 0, grow: 0.34, recEnd: 3.4, folded: 3.82, handoff: 5.0,
  leave: 6.3, gone: 6.56, loop: 7.4,
};
const LANDS = T.handoff + 0.08;      // the text is pasted as the check begins
const CYCLE = 2 * T.loop;            // two dictations, then the text clears
const CLEAR = [CYCLE - 0.9, CYCLE - 0.4];

const clamp = (x) => Math.max(0, Math.min(1, x));
const smooth = (x) => { x = clamp(x); return x * x * (3 - 2 * x); };
// Underdamped spring, about 4 % overshoot, settled at 1.
const spring = (x) => (x >= 1 ? 1 : 1 - Math.exp(-6 * x) * Math.cos(6 * x));
const mix = (a, b, e) => a + (b - a) * e;
const mixRGB = (a, b, e) => a.map((v, i) => Math.round(mix(v, b[i], e)));

const INK = [243, 244, 247], GREEN = [79, 211, 155];

export function setupDictationDemo(still) {
  const stage = document.querySelector('.pill-stage');
  if (!stage) return;
  const pill = stage.querySelector('.lv');
  const text = stage.querySelector('.lv-text');
  const first = text.querySelector('.lv-first');
  const second = text.querySelector('.lv-second');
  const rec = pill.querySelector('.lv-rec');
  const timer = rec.querySelector('time');
  const mark = pill.querySelector('.lv-mark');
  const arc = mark.querySelector('.lv-arc');
  const check = mark.querySelector('.lv-check');
  const checkLength = check.getTotalLength();
  check.style.strokeDasharray = checkLength;

  // Reduced motion: the recording pill, standing still. ?pill=<seconds>
  // freezes any moment of the loop, for screenshots.
  const frozen = parseFloat(new URLSearchParams(location.search).get('pill'));
  if (still || frozen >= 0) {
    render(still ? T.loop + 1.6 : frozen);
    return;
  }

  let elapsed = 0, last = null, running = false, inView = false, frame = 0;

  function render(cycleTime) {
    const round = cycleTime < T.loop ? 0 : 1;
    const t = cycleTime - round * T.loop;
    // The text at the cursor: the first sentence lands in round one, the
    // second joins it in round two, then both clear before the next cycle.
    const landed = (r) => round > r || (round === r && t >= LANDS);
    first.style.display = landed(0) ? '' : 'none';
    second.style.display = landed(1) ? '' : 'none';
    text.style.opacity = (1 - clamp((cycleTime - CLEAR[0]) / (CLEAR[1] - CLEAR[0]))).toFixed(3);

    let width = CIRCLE, scale = 1, opacity = 1, recAlpha = 0, markAlpha = 0;
    let head = 0, length = 0, radius = ARC_R, arcColor = INK, arcAlpha = 0.55, arcWidth = 2.2;
    let checkDraw = 0;

    if (t < T.grow) {                                   // hotkey: a circle appears
      const x = (t - T.appear) / (T.grow - T.appear);
      scale = mix(SEED / CIRCLE, 1, spring(x));
      opacity = smooth(x / 0.3);
    } else if (t < T.recEnd) {                          // grows into the recording pill
      const x = (t - T.grow) / 0.46;
      width = mix(CIRCLE, PILL, spring(clamp(x)));
      recAlpha = smooth((x - 0.28) / 0.45);
    } else if (t < T.leave) {                           // folded: transcribing, then the check
      const x = (t - T.recEnd) / (T.folded - T.recEnd);
      width = mix(PILL, CIRCLE, spring(clamp(x)));
      recAlpha = 1 - smooth(x / 0.35);
      markAlpha = smooth((x - 0.45) / 0.4);
      const spin = (s) => ({ head: 6.2 * s, length: 1.5 + 0.45 * Math.sin(s * 2.7) });
      if (t < T.handoff) {
        ({ head, length } = spin(t));
      } else {
        // The arc spirals inward, turns green and lands where the check starts.
        const from = spin(T.handoff);
        const u = clamp((t - T.handoff) / 0.26), e = smooth(u);
        let travel = (Math.PI - from.head) % (2 * Math.PI);
        if (travel < 0) travel += 2 * Math.PI;
        if (travel < 2.1) travel += 2 * Math.PI;
        head = from.head + travel * e;
        length = from.length * (1 - e);
        radius = mix(ARC_R, CHECK_R, e);
        arcColor = mixRGB(INK, GREEN, e);
        arcAlpha = mix(0.55, 1, e);
        arcWidth = mix(2.2, 2.6, e);
        const k = clamp((t - T.handoff - 0.21) / 0.28);
        checkDraw = 1 - Math.pow(1 - k, 3);
      }
    } else if (t < T.gone) {                            // folds into a point and is gone
      const x = (t - T.leave) / (T.gone - T.leave);
      scale = mix(1, SEED / CIRCLE, x * x * x);
      markAlpha = 1 - x / 0.35;
      opacity = clamp((1 - x) / 0.3);
      checkDraw = 1;
    } else {
      opacity = 0;
    }

    pill.style.width = `calc(var(--u) * ${width.toFixed(2)})`;
    pill.style.transform = `scale(${scale.toFixed(4)})`;
    pill.style.opacity = opacity.toFixed(3);
    rec.style.opacity = clamp(recAlpha).toFixed(3);
    mark.style.opacity = clamp(markAlpha).toFixed(3);

    // The arc trails `length` radians behind its head, clockwise on screen.
    const visible = length > 0.01;
    arc.style.display = visible ? '' : 'none';
    if (visible) {
      arc.setAttribute('r', radius.toFixed(2));
      arc.style.strokeDasharray = `${(length * radius).toFixed(2)} 999`;
      arc.style.transform = `rotate(${(head - length).toFixed(4)}rad)`;
      arc.style.stroke = `rgba(${arcColor.join(',')},${arcAlpha.toFixed(3)})`;
      arc.style.strokeWidth = arcWidth.toFixed(2);
    }
    // Hidden until it starts: a round cap would show a zero-length stroke as a dot.
    check.style.display = checkDraw > 0.001 ? '' : 'none';
    check.style.strokeDashoffset = (checkLength * (1 - checkDraw)).toFixed(2);

    if (t >= T.grow && t < T.recEnd) {
      const seconds = Math.floor(t - T.grow);
      timer.textContent = `00:0${Math.min(9, seconds)}`;
    }
  }

  function tick(now) {
    if (last !== null) elapsed = (elapsed + (now - last) / 1000) % CYCLE;
    last = now;
    render(elapsed);
    frame = requestAnimationFrame(tick);
  }

  function sync() {
    const run = inView;
    if (run === running) return;
    running = run;
    stage.classList.toggle('is-paused', !run);
    if (run) { last = null; frame = requestAnimationFrame(tick); }
    else cancelAnimationFrame(frame);
  }

  render(0);

  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; sync(); }, { threshold: 0.2 })
      .observe(stage);
  } else {
    inView = true;
    sync();
  }
}
