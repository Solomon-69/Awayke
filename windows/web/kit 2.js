// kit.js: shared panel helpers for the Windows versions of Nox and Awayke (identical copy in both).
// Smooth switches, chips, the drum picker, panel height reporting and open/close motion.
(() => {
  'use strict';
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');

  function post(type, data) {
    try { window.chrome.webview.postMessage(Object.assign({ type }, data || {})); } catch (e) { /* not in the app */ }
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // A switch that flips the moment it is clicked and slides once. The app's real value is followed
  // later (follow), but never within a short time of a click, so it can't snap back and forth.
  function sw(on, label, onChange) {
    const b = el('button', 'switch');
    b.setAttribute('role', 'switch');
    b.setAttribute('aria-label', label);
    let shown = !!on, lastTap = -Infinity;
    const set = v => { shown = !!v; b.setAttribute('aria-checked', String(shown)); };
    set(on);
    b.addEventListener('click', () => { lastTap = performance.now(); set(!shown); onChange(shown); });
    b.follow = v => { if (performance.now() - lastTap > 800 && !!v !== shown) set(v); };
    b.force = v => set(v);
    return b;
  }

  // Chips: [{label, value}]. seg = joined segmented look.
  function chips(options, value, onPick, seg) {
    const box = el('div', 'chips' + (seg ? ' seg' : ''));
    let current = value;
    const paint = () => box.querySelectorAll('.chip').forEach(c => c.classList.toggle('on', c.dataset.v === String(current)));
    options.forEach(o => {
      const c = el('button', 'chip', o.label);
      c.dataset.v = String(o.value);
      c.addEventListener('click', () => { if (String(current) === String(o.value)) return; current = o.value; paint(); onPick(o.value); });
      box.appendChild(c);
    });
    paint();
    box.select = v => { current = v; paint(); };
    return box;
  }

  const pad = n => String(n).padStart(2, '0');
  const ROW = 26, STEP = 5;

  // Scroll-wheel "drum" for a time of day (mode 'clock', minutes after midnight) or a length of time
  // (mode 'duration', min..max minutes). Snaps to rows, curves and fades away like iOS.
  function drum(opts) {
    const clock = opts.mode === 'clock';
    const min = clock ? 0 : (opts.min ?? 5), max = clock ? 1435 : (opts.max ?? 1440);
    const hours = [];
    for (let h = clock ? 0 : Math.floor(min / 60); h <= (clock ? 23 : Math.floor(max / 60)); h++) hours.push(h);
    const mins = [];
    for (let m = 0; m < 60; m += STEP) mins.push(m);
    const box = el('div', 'drum');
    let value = opts.value;

    function column(items, fmt) {
      const col = el('div', 'col');
      items.forEach((v, i) => {
        const it = el('div', 'item', fmt(v));
        it.addEventListener('click', () => col.scrollTo({ top: i * ROW, behavior: reduce.matches ? 'auto' : 'smooth' }));
        col.appendChild(it);
      });
      let timer = 0, frame = 0, settling = false;
      const paint = () => {
        frame = 0;
        const top = col.scrollTop;
        col.childNodes.forEach((it, i) => {
          const off = (i * ROW - top) / ROW;
          const a = Math.min(Math.abs(off), 2.6);
          it.style.transform = `rotateX(${-off * 22}deg) scale(${1 - a * 0.05})`;
          it.style.opacity = String(1 - a * 0.3);
          it.style.fontWeight = a < 0.5 ? '600' : '400';
        });
      };
      col.addEventListener('scroll', () => {
        if (!frame) frame = requestAnimationFrame(paint);
        clearTimeout(timer);
        timer = setTimeout(() => {
          if (settling) { settling = false; return; }
          commit();
        }, 120);
      }, { passive: true });
      col.index = () => Math.max(0, Math.min(items.length - 1, Math.round(col.scrollTop / ROW)));
      col.go = (i, smooth) => {
        const top = i * ROW;
        if (Math.abs(col.scrollTop - top) < 1) { paint(); return; }
        settling = true;
        col.scrollTo({ top, behavior: smooth && !reduce.matches ? 'smooth' : 'auto' });
        if (!smooth) requestAnimationFrame(paint);
      };
      col.paint = paint;
      return col;
    }

    const colH = column(hours, h => clock ? pad(h) : h + 'h');
    const colM = column(mins, m => clock ? pad(m) : pad(m) + 'm');
    box.appendChild(colH);
    if (clock) box.appendChild(el('div', 'sep', ':'));
    box.appendChild(colM);

    function commit() {
      let v = hours[colH.index()] * 60 + mins[colM.index()];
      v = Math.max(min, Math.min(max, v));
      if (v === value) return;
      value = v;
      if (hours[colH.index()] * 60 + mins[colM.index()] !== v) place(v, true);
      opts.onChange(v);
    }
    function place(v, smooth) {
      colH.go(Math.max(0, hours.indexOf(Math.floor(v / 60))), smooth);
      colM.go(Math.max(0, mins.indexOf(Math.round((v % 60) / STEP) * STEP % 60)), smooth);
    }
    box.set = (v, smooth) => { value = v; place(v, smooth); };
    // A drum can only scroll once it is laid out: place it again whenever it becomes visible.
    if (window.ResizeObserver) new ResizeObserver(() => { if (box.offsetHeight) place(value, false); }).observe(box);
    requestAnimationFrame(() => requestAnimationFrame(() => place(value, false)));
    return box;
  }

  // "Title 20:30" + preset chips on the left, drum on the right (like the Mac ChipDrumPicker).
  function chipDrum(opts) {
    const wrap = el('div', 'picker');
    const left = el('div', 'left');
    const head = el('div', 'label');
    const val = el('span', 'value');
    const fmt = opts.format || (opts.mode === 'clock' ? (v => pad(Math.floor(v / 60)) + ':' + pad(v % 60)) : duration);
    head.append((opts.title || '') + ' ', val);
    const presetBox = chips(opts.presets.map(p => ({ label: fmt(p), value: p })), opts.value, v => { d.set(v, true); update(v); opts.onChange(v); });
    left.append(head, presetBox);
    const d = drum({ mode: opts.mode, value: opts.value, min: opts.min, max: opts.max, onChange: v => { update(v); opts.onChange(v); } });
    function update(v) { val.textContent = fmt(v); presetBox.select(v); }
    update(opts.value);
    wrap.append(left, d);
    wrap.set = v => { d.set(v, true); update(v); };
    return wrap;
  }

  function duration(v) {
    const h = Math.floor(v / 60), m = v % 60;
    if (h === 0) return m + 'm';
    return m === 0 ? h + 'h' : h + 'h ' + m + 'm';
  }

  // ---------- panel ----------
  let lastH = 0;
  function reportHeight() {
    const root = document.getElementById('root');
    if (!root) return;
    const h = Math.ceil(root.getBoundingClientRect().height);
    if (h && h !== lastH) { lastH = h; post('height', { h }); }
  }

  function opened() {
    const root = document.getElementById('root');
    if (!root) return;
    [...root.children].forEach((c, i) => c.style.setProperty('--i', i));
    root.classList.remove('in');
    void root.offsetWidth;
    if (!reduce.matches) root.classList.add('in');
    document.documentElement.style.opacity = '';
    if (window.onPanelOpened) window.onPanelOpened();
  }

  function closed() { if (window.onPanelClosed) window.onPanelClosed(); }

  function fadeOut(ms) {
    const s = document.documentElement.style;
    s.transition = `opacity ${ms}ms ease`;
    s.opacity = '0';
  }

  function setDark(d) { document.documentElement.dataset.theme = d ? 'dark' : 'light'; }

  // Animated show/hide for a block (height via grid rows, plus fade).
  function reveal(node, open) { node.classList.toggle('open', !!open); node.setAttribute('aria-hidden', String(!open)); }


  // First-run welcome: a few pages shown in place of the panel, each part rising in a moment after the
  // one above it, pages sliding left and right. pages: [{ art, title, text, items: [{ icon, title, detail }],
  // extra: element, app: true for the big first-page tile }]. opts: { done: 'Get started', onDone(finished) }. Returns { close }.
  function intro(pages, opts) {
    const root = document.getElementById('root');
    const box = el('div', 'intro');
    const stage = el('div', 'intro-stage');
    const foot = el('div', 'intro-foot');
    const back = el('button', 'btn plain'), dots = el('div', 'intro-dots'), next = el('button', 'btn solid intro-next');
    pages.forEach(() => dots.appendChild(el('i')));
    foot.append(back, dots, next);
    box.append(stage, foot);
    let page = -1;

    function build(p) {
      const v = el('div', 'intro-page');
      let i = 0;
      const add = n => { n.style.setProperty('--i', i++); v.appendChild(n); };
      if (p.art) { const a = el('div', 'intro-art' + (p.app ? ' app' : '')); a.innerHTML = p.art; add(a); }
      add(el('h2', '', p.title));
      if (p.text) add(el('p', 'intro-text', p.text));
      (p.items || []).forEach(it => {
        const r = el('div', 'card intro-item');
        const ic = el('div', 'icon'); ic.innerHTML = it.icon || '';
        const g = el('div', 'grow');
        g.append(el('div', 'title', it.title), el('div', 'detail', it.detail));
        r.append(ic, g);
        add(r);
      });
      if (p.extra) add(p.extra);
      return v;
    }

    function go(n) {
      if (n < 0 || n >= pages.length || n === page) return;
      const dir = n > page ? 'next' : 'prev';
      const old = stage.firstChild;
      const v = build(pages[n]);
      if (old && !reduce.matches) {
        old.classList.add('out-' + dir);
        old.addEventListener('animationend', () => old.remove(), { once: true });
        setTimeout(() => old.remove(), 400);
      } else if (old) old.remove();
      if (page >= 0) v.classList.add('in-' + dir);
      stage.appendChild(v);
      page = n;
      dots.childNodes.forEach((d, k) => d.classList.toggle('on', k === n));
      back.textContent = n === 0 ? 'Skip' : 'Back';
      next.textContent = n === pages.length - 1 ? (opts.done || 'Get started') : 'Continue';
      reportHeight();
    }

    function close(finished) {
      box.classList.add('leaving');
      const end = () => {
        box.remove();
        root.classList.remove('intro-on', 'in');
        void root.offsetWidth;
        root.classList.add('in');
        reportHeight();
      };
      if (reduce.matches) end(); else setTimeout(end, 220);
      if (opts.onDone) opts.onDone(!!finished);
    }

    back.onclick = () => page === 0 ? close(false) : go(page - 1);
    next.onclick = () => page === pages.length - 1 ? close(true) : go(page + 1);
    box.addEventListener('keydown', e => {
      if (e.key === 'ArrowRight') next.click();
      if (e.key === 'ArrowLeft' && page > 0) back.click();
    });
    root.classList.add('intro-on');
    root.prepend(box);
    go(0);
    next.focus();
    return { close, go };
  }

  window.kit = { post, el, sw, chips, drum, chipDrum, duration, pad, opened, closed, fadeOut, setDark, reveal, reportHeight, intro };

  addEventListener('DOMContentLoaded', () => {
    const root = document.getElementById('root');
    if (root && window.ResizeObserver) new ResizeObserver(reportHeight).observe(root);
    // Every reveal animation changes the height: report through the transition, not just at the end.
    document.addEventListener('transitionend', reportHeight);
    reportHeight();
  });
  // Keyboard: Esc closes (handled by the app window), Space/Enter work on buttons natively.
})();
