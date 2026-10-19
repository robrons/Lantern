// Lantern's page driver. Runs in a private script world in every frame, so pages can't see
// or call it. The TV app calls window.__lantern in the top frame with pointer coordinates in
// screen points; child frames are reached with postMessage carrying a per-launch token.
(() => {
  'use strict';
  if (window.__lantern) return;

  const TOKEN = '__LANTERN_TOKEN__';
  const isTop = window === window.top;

  // "Verify you're human" checks only accept real touches, and treat scripted events as signs
  // of automation. Lantern sends nothing into them, so they can run undisturbed.
  const VERIFICATION = /(^|\.)(challenges\.cloudflare\.com|hcaptcha\.com|recaptcha\.net|arkoselabs\.com|funcaptcha\.com|perimeterx\.net|px-cdn\.net|px-cloud\.net|captcha-delivery\.com)$/;
  const isVerificationFrame = !isTop && (VERIFICATION.test(location.hostname)
    || (/(^|\.)google\.com$/.test(location.hostname) && location.pathname.startsWith('/recaptcha')));

  const post = (message) => {
    try { window.webkit.messageHandlers.lantern.postMessage(message); } catch (e) {}
  };
  const send = (win, data) => {
    try { win.postMessage(Object.assign({ __lantern: TOKEN }, data), '*'); } catch (e) {}
  };

  // The boxes these checks put on a page. Many hide their checkbox in a sealed part of the
  // page, so Lantern recognises the box itself and keeps its hands off it too.
  const VERIFICATION_BOX = [
    '.cf-turnstile', '#turnstile-wrapper', '#challenge-stage', '[id^="cf-chl-widget"]',
    '.g-recaptcha', '.h-captcha', '#px-captcha', '[data-sitekey]',
    'iframe[src*="challenges.cloudflare.com"]', 'iframe[src*="hcaptcha.com"]',
    'iframe[src*="/recaptcha/"]', 'iframe[src*="captcha-delivery.com"]',
  ].join(', ');

  function isVerificationBox(el) {
    for (let e = el, depth = 0; e && e.nodeType === 1 && depth < 12; e = parentOf(e), depth++) {
      try { if (e.matches(VERIFICATION_BOX)) return true; } catch (err) { return false; }
    }
    return false;
  }

  const parentOf = (node) => {
    if (node.parentElement) return node.parentElement;
    const root = node.getRootNode && node.getRootNode();
    return root && root.host ? root.host : null;
  };
  const isFrame = (el) => el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME');
  const frames = () => Array.from(document.querySelectorAll('iframe, frame'));
  const frameFor = (win) => frames().find((frame) => frame.contentWindow === win) || null;

  function elementAt(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }

  function framePoint(frame, x, y) {
    const rect = frame.getBoundingClientRect();
    const style = getComputedStyle(frame);
    return {
      x: x - rect.left - frame.clientLeft - (parseFloat(style.paddingLeft) || 0),
      y: y - rect.top - frame.clientTop - (parseFloat(style.paddingTop) || 0),
    };
  }

  // ---- What's under the pointer ----

  const TEXT_TYPES = new Set(['text', 'search', 'email', 'url', 'tel', 'password', 'number',
    'date', 'datetime-local', 'month', 'week', 'time']);

  function textFieldFor(el) {
    for (let e = el; e && e.nodeType === 1; e = parentOf(e)) {
      if (e.tagName === 'TEXTAREA' && !e.disabled && !e.readOnly) return e;
      if (e.tagName === 'INPUT') {
        return TEXT_TYPES.has((e.type || 'text').toLowerCase()) && !e.disabled && !e.readOnly ? e : null;
      }
      if (e.tagName === 'LABEL' && e.control) return textFieldFor(e.control);
      if (e.isContentEditable) {
        let host = e;
        while (parentOf(host) && parentOf(host).isContentEditable) host = parentOf(host);
        return host;
      }
      if (e === document.body) break;
    }
    return null;
  }

  function selectFor(el) {
    for (let e = el; e && e.nodeType === 1; e = parentOf(e)) {
      if (e.tagName === 'SELECT') return e.disabled || e.multiple ? null : e;
      if (e.tagName === 'LABEL' && e.control) return selectFor(e.control);
      if (e === document.body) break;
    }
    return null;
  }

  const CLICKABLE_ROLES = /^(button|link|tab|menuitem|menuitemcheckbox|menuitemradio|option|checkbox|radio|switch|treeitem|combobox)$/;

  function kindOf(el) {
    if (!el) return 'none';
    if (isFrame(el)) return 'frame';
    if (textFieldFor(el)) return 'text';
    for (let e = el; e && e.nodeType === 1; e = parentOf(e)) {
      const tag = e.tagName;
      if ((tag === 'A' && e.hasAttribute('href')) || tag === 'BUTTON' || tag === 'SELECT'
          || tag === 'SUMMARY' || tag === 'LABEL' || tag === 'INPUT') return 'link';
      const role = e.getAttribute('role');
      if (role && CLICKABLE_ROLES.test(role)) return 'link';
      if (e === document.body) break;
    }
    try { if (getComputedStyle(el).cursor === 'pointer') return 'link'; } catch (e) {}
    if (el.tagName === 'VIDEO') return 'video';
    return 'none';
  }

  // ---- Forgiving targets ----

  const CLICKABLE_TAGS = new Set(['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY', 'LABEL', 'VIDEO']);

  /// The element a click on `el` is really aimed at: a link, button, field or anything the
  /// page styles as clickable. Returns null for plain content. `memo` caches answers within
  /// one pointer check, since nearby points usually land on the same elements.
  function clickableFor(el, memo) {
    if (memo && memo.has(el)) return memo.get(el);
    const found = findClickable(el);
    if (memo) memo.set(el, found);
    return found;
  }

  function findClickable(el) {
    let depth = 0;
    for (let e = el; e && e.nodeType === 1 && e !== document.body && e !== document.documentElement && depth < 14; e = parentOf(e), depth++) {
      if (CLICKABLE_TAGS.has(e.tagName) && !(e.tagName === 'A' && !e.hasAttribute('href'))) return e;
      const role = e.getAttribute('role');
      if ((role && CLICKABLE_ROLES.test(role)) || e.isContentEditable || e.hasAttribute('onclick')) return e;
      let pointer = false;
      try { pointer = getComputedStyle(e).cursor === 'pointer'; } catch (err) {}
      if (pointer) {
        // Highlight the whole clickable thing, not just the text inside it.
        let outer = e;
        let climbed = 0;
        for (let p = parentOf(e); p && p.nodeType === 1 && p !== document.body && climbed < 8; p = parentOf(p), climbed++) {
          let parentPointer = false;
          try { parentPointer = getComputedStyle(p).cursor === 'pointer'; } catch (err) {}
          if (!parentPointer) break;
          outer = p;
        }
        return outer;
      }
    }
    return null;
  }

  // Vertical distance counts for more, so a link on the same line beats one on the next.
  function distanceToRect(x, y, r) {
    const dx = Math.max(r.left - x, 0, x - r.right);
    const dy = Math.max(r.top - y, 0, y - r.bottom);
    return Math.hypot(dx, dy * 1.8);
  }

  /// What a click at (x, y) should hit. When nothing clickable is right under the pointer,
  /// the nearest clickable thing within reach wins, so clicks don't need to be precise.
  /// The search stops after a few milliseconds so a heavy page can never be bogged down.
  function targetAt(x, y) {
    const started = performance.now();
    const memo = new Map();
    const el = elementAt(x, y);
    if (!el) return null;
    if (isFrame(el)) return { frame: el, hit: el, x, y };
    const direct = clickableFor(el, memo);
    if (direct) return { el: direct, hit: el, x, y };

    const reach = 34;
    let best = null;
    let bestDistance = Infinity;
    search:
    for (const radius of [16, reach]) {
      for (let step = 0; step < 8; step++) {
        if (performance.now() - started > 6) break search;
        const angle = step * Math.PI / 4;
        const near = elementAt(x + Math.cos(angle) * radius, y + Math.sin(angle) * radius);
        if (!near || isFrame(near)) continue;
        const candidate = clickableFor(near, memo);
        if (!candidate) continue;
        const distance = distanceToRect(x, y, candidate.getBoundingClientRect());
        if (distance < bestDistance) { best = candidate; bestDistance = distance; }
      }
    }
    if (!best || bestDistance > reach) return { el: null, hit: el, x, y };
    const r = best.getBoundingClientRect();
    const tx = Math.min(Math.max(x, r.left + 2), r.right - 2);
    const ty = Math.min(Math.max(y, r.top + 2), r.bottom - 2);
    return { el: best, hit: elementAt(tx, ty) || best, x: tx, y: ty };
  }

  // ---- Synthetic pointer events ----

  function fire(el, x, y, types, buttons) {
    for (const type of types) {
      const init = {
        bubbles: true, cancelable: true, composed: true, view: window,
        clientX: x, clientY: y, screenX: x, screenY: y,
        button: 0, buttons, detail: type.startsWith('pointer') ? 0 : 1,
        pointerId: 1, pointerType: 'mouse', isPrimary: true,
      };
      if (type.endsWith('enter') || type.endsWith('leave')) init.bubbles = false;
      let event;
      try {
        event = type.startsWith('pointer') ? new PointerEvent(type, init) : new MouseEvent(type, init);
      } catch (e) {
        event = new MouseEvent(type, init);
      }
      el.dispatchEvent(event);
    }
  }

  let hovered = null;

  function hoverAt(x, y) {
    const target = targetAt(x, y);
    if (target && isVerificationBox(target.hit)) {
      hovered = null;
      return { kind: 'none' };
    }
    const el = target ? target.hit : null;
    const px = target ? target.x : x;
    const py = target ? target.y : y;
    if (el !== hovered) {
      if (hovered && hovered.isConnected) {
        fire(hovered, px, py, ['pointerout', 'pointerleave', 'mouseout', 'mouseleave'], 0);
      }
      if (el) fire(el, px, py, ['pointerover', 'pointerenter', 'mouseover', 'mouseenter'], 0);
      hovered = el;
    }
    if (el) fire(el, px, py, ['pointermove', 'mousemove'], 0);
    if (target && target.frame) {
      const p = framePoint(target.frame, x, y);
      send(target.frame.contentWindow, { t: 'hover', x: p.x, y: p.y });
      return { kind: 'frame' };
    }
    if (!target || !target.el) return { kind: kindOf(el) === 'video' ? 'video' : 'none' };
    const r = target.el.getBoundingClientRect();
    // Outlining something nearly page-sized would just frame the screen.
    const outline = r.width < innerWidth * 0.9 && r.height < innerHeight * 0.6
      ? [r.left, r.top, r.width, r.height] : null;
    return { kind: kindOf(target.hit), rect: outline };
  }

  // Two clicks in the same spot also send a double-click, which many players use for full screen.
  let lastClick = null;

  function isDoubleClick(el, x, y) {
    const now = Date.now();
    const double = lastClick && lastClick.el === el && now - lastClick.time < 450
      && Math.abs(lastClick.x - x) < 30 && Math.abs(lastClick.y - y) < 30;
    lastClick = double ? null : { el, x, y, time: now };
    return double;
  }

  // Where text typed on the TV, or a choice from a list, should land: an element in this
  // frame, or a child frame the last click was forwarded to.
  let focusTarget = null;

  function clickAt(pointerX, pointerY) {
    const target = targetAt(pointerX, pointerY);
    if (!target) return 'none';
    const el = target.hit;
    if (isVerificationBox(el)) {
      post({ type: 'verification' });
      return 'none';
    }
    markUserAction();
    const x = target.x;
    const y = target.y;

    const stopped = parkedVideoAt(pointerX, pointerY);
    if (stopped && unpark(stopped)) {
      activeMedia = stopped;
      return 'video';
    }

    if (isFrame(el)) {
      const p = framePoint(el, x, y);
      focusTarget = { win: el.contentWindow };
      send(el.contentWindow, { t: 'click', x: p.x, y: p.y });
      return 'frame';
    }

    const field = textFieldFor(el);
    if (field) {
      focusTarget = { el: field };
      fire(el, x, y, ['pointerdown', 'mousedown'], 1);
      try { field.focus({ preventScroll: true }); } catch (e) {}
      fire(el, x, y, ['pointerup', 'mouseup', 'click'], 0);
      requestText(field);
      return 'text';
    }

    const select = selectFor(el);
    if (select) {
      focusTarget = { el: select };
      requestChoice(select);
      return 'link';
    }

    // The browser's own video controls ignore script-made clicks, so work them directly.
    if (el instanceof HTMLVideoElement && el.controls) {
      activeMedia = el;
      if (el.paused || el.ended) el.play().catch(() => {});
      else el.pause();
      return 'video';
    }

    const kind = kindOf(el);
    fire(el, x, y, ['pointerdown', 'mousedown'], 1);
    fire(el, x, y, ['pointerup', 'mouseup', 'click'], 0);
    if (isDoubleClick(el, x, y)) {
      el.dispatchEvent(new MouseEvent('dblclick', {
        bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, detail: 2,
      }));
    }
    return kind;
  }

  // ---- Text fields and lists ----

  function labelFor(field) {
    const aria = field.getAttribute('aria-label');
    if (aria) return aria.trim();
    if (field.labels && field.labels[0]) return field.labels[0].innerText.trim();
    return (field.placeholder || field.getAttribute('title') || '').trim();
  }

  function requestText(field) {
    const isInput = field.tagName === 'INPUT';
    post({
      type: 'input',
      value: field.isContentEditable ? field.innerText : (field.value || ''),
      label: labelFor(field).slice(0, 120),
      inputType: isInput ? (field.type || 'text').toLowerCase() : 'text',
      multiline: !isInput,
    });
  }

  function shouldSubmit(field) {
    if (field.tagName !== 'INPUT' || field.type === 'password') return false;
    const hints = [field.type, field.name, field.id, field.getAttribute('role'),
      field.getAttribute('aria-label'), field.placeholder, field.getAttribute('enterkeyhint')]
      .join(' ').toLowerCase();
    if (/search|query|\bq\b|combobox|\bgo\b/.test(hints)) return true;
    if (!field.form) return false;
    const fields = Array.from(field.form.elements).filter((e) => textFieldFor(e) === e);
    return fields.length === 1;
  }

  function applyText(field, value) {
    try { field.focus({ preventScroll: true }); } catch (e) {}

    if (field.isContentEditable) {
      // Typing through the editing commands keeps rich editors' own state in sync.
      document.execCommand('selectAll', false);
      if (!document.execCommand('insertText', false, value)) field.textContent = value;
      return;
    }

    let typed = false;
    try {
      field.select();
      typed = value
        ? document.execCommand('insertText', false, value)
        : document.execCommand('delete', false);
    } catch (e) {}
    if (!typed || field.value !== value) {
      const proto = field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(field, value);
      field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
    }
    field.dispatchEvent(new Event('change', { bubbles: true }));

    // The Enter key itself is sent from the page's own world (lantern-page.js) so that
    // keyCode-based handlers see it.
    if (shouldSubmit(field)) {
      field.dispatchEvent(new CustomEvent('__lanternsubmit', { bubbles: true, composed: true }));
    }
  }

  function setText(value) {
    if (!focusTarget) return;
    if (focusTarget.win) send(focusTarget.win, { t: 'setText', value });
    else if (focusTarget.el.isConnected) applyText(focusTarget.el, value);
  }

  function requestChoice(select) {
    post({
      type: 'select',
      label: labelFor(select).slice(0, 120),
      options: Array.from(select.options).map((o) => ({ label: (o.label || o.text || '').trim(), disabled: o.disabled })),
      selectedIndex: select.selectedIndex,
    });
  }

  function choose(index) {
    if (!focusTarget) return;
    if (focusTarget.win) { send(focusTarget.win, { t: 'choose', index }); return; }
    const select = focusTarget.el;
    if (!(select instanceof HTMLSelectElement)) return;
    select.selectedIndex = index;
    select.dispatchEvent(new Event('input', { bubbles: true }));
    select.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // ---- Video and audio ----

  let activeMedia = null;

  function visibleArea(el) {
    const r = el.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return w * h;
  }

  // Muted previews that play on hover shouldn't take over the Play/Pause button.
  const matters = (media) => media.tagName === 'AUDIO' || !media.muted
    || visibleArea(media) > innerWidth * innerHeight * 0.25;

  // ---- Muted videos that start by themselves ----
  //
  // Pages often autoplay muted clips: backgrounds, previews, video ads. A paused video keeps
  // everything it loaded, so on a 4 GB TV these are stopped *and unloaded* unless they're the
  // page's main video or you just clicked. Clicking one brings it back.

  let lastUserAction = 0;
  const markUserAction = () => { lastUserAction = Date.now(); };
  const parked = new WeakMap();

  function isMainVideo(video) {
    const area = visibleArea(video);
    if (area < innerWidth * innerHeight * 0.2) return false;
    for (const other of document.querySelectorAll('video')) {
      if (other !== video && !other.paused && visibleArea(other) > area) return false;
    }
    return true;
  }

  function park(video) {
    if (parked.has(video)) {
      video.pause();
      return;
    }
    const sources = Array.from(video.querySelectorAll('source')).map((source) => [source, source.getAttribute('src')]);
    parked.set(video, { src: video.getAttribute('src'), sources });
    video.pause();
    video.removeAttribute('src');
    for (const [source] of sources) source.removeAttribute('src');
    video.load();
  }

  function unpark(video) {
    const saved = parked.get(video);
    if (!saved) return false;
    parked.delete(video);
    if (saved.src) video.setAttribute('src', saved.src);
    for (const [source, src] of saved.sources) if (src) source.setAttribute('src', src);
    video.load();
    video.play().catch(() => {});
    return true;
  }

  /// A stopped video under the point, if there is one.
  function parkedVideoAt(x, y) {
    for (const video of document.querySelectorAll('video')) {
      if (!parked.has(video)) continue;
      const r = video.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return video;
    }
    return null;
  }

  document.addEventListener('play', (event) => {
    const video = event.target;
    if (!(video instanceof HTMLVideoElement) || !video.muted) return;
    if (Date.now() - lastUserAction < 3000 || isMainVideo(video)) return;
    park(video);
  }, true);

  for (const type of ['play', 'pause', 'ended']) {
    document.addEventListener(type, (event) => {
      const media = event.target;
      if (!(media instanceof HTMLMediaElement) || !matters(media)) return;
      activeMedia = media;
      post({ type: 'media', playing: !media.paused && !media.ended });
    }, true);
  }

  function controlMedia(action, value) {
    markUserAction();
    const media = activeMedia && activeMedia.isConnected ? activeMedia : null;
    if (!media) {
      for (const frame of frames()) send(frame.contentWindow, { t: 'media', action, value });
      return false;
    }
    if (action === 'toggle') {
      if (media.paused || media.ended) media.play().catch(() => {});
      else media.pause();
    } else if (action === 'pause') {
      media.pause();
    } else if (action === 'seek') {
      const end = Number.isFinite(media.duration) ? media.duration : Infinity;
      media.currentTime = Math.max(0, Math.min(end, media.currentTime + value));
    }
    return true;
  }

  // ---- Theater: one video (or player) fills the screen ----

  const STAGE_CSS = [
    'position:fixed', 'inset:0', 'left:0', 'top:0', 'right:auto', 'bottom:auto',
    'width:100vw', 'height:100vh', 'max-width:none', 'max-height:none', 'min-width:0', 'min-height:0',
    'margin:0', 'padding:0', 'border:0', 'border-radius:0', 'transform:none', 'translate:none', 'scale:none',
    'z-index:2147483647', 'background:#000', 'opacity:1', 'visibility:visible', 'clip-path:none',
    'object-fit:contain',
  ].map((rule) => rule + ' !important').join(';');

  // Anything that would make a fixed element position itself inside its ancestor.
  const ANCESTOR_CSS = [
    'transform:none', 'translate:none', 'scale:none', 'filter:none', 'backdrop-filter:none',
    'perspective:none', 'contain:none', 'will-change:auto', 'container-type:normal',
  ].map((rule) => rule + ' !important').join(';');

  function ensureStageStyle() {
    if (document.getElementById('__lantern-style')) return;
    const style = document.createElement('style');
    style.id = '__lantern-style';
    style.textContent = `
      html.__lantern-theater, html.__lantern-theater body { overflow: hidden !important; background: #000 !important; }
      html.__lantern-theater body * { visibility: hidden !important; }
      html.__lantern-theater .__lantern-stage, html.__lantern-theater .__lantern-stage * { visibility: visible !important; }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  let stage = null;

  function bestStageTarget() {
    if (activeMedia && activeMedia.isConnected && activeMedia.tagName === 'VIDEO' && visibleArea(activeMedia) > 0) {
      return activeMedia;
    }
    let best = null;
    let bestScore = 0;
    for (const video of document.querySelectorAll('video')) {
      const score = visibleArea(video) * (video.paused ? 1 : 4);
      if (score > bestScore) { best = video; bestScore = score; }
    }
    if (best) return best;
    const minimum = innerWidth * innerHeight * 0.05;
    for (const frame of document.querySelectorAll('iframe')) {
      const area = visibleArea(frame);
      const score = area * (/youtube|vimeo|player|embed|video|dailymotion|twitch|stream/i.test(frame.src) ? 3 : 1);
      if (area > minimum && score > bestScore) { best = frame; bestScore = score; }
    }
    return best;
  }

  function reportStage(on) {
    if (isTop) post({ type: 'theater', on });
    else send(window.parent, { t: 'stage', on });
  }

  function enterTheater(target, options) {
    const opts = Object.assign({ notifyParent: true, fromChild: false }, options);
    exitTheater({ notifyParent: false, cascade: false });
    const el = target || bestStageTarget();
    if (!el) return false;

    ensureStageStyle();
    const saved = [];
    const restyle = (node, css) => {
      saved.push([node, node.getAttribute('style')]);
      node.style.cssText += ';' + css;
    };

    // A bare video is lifted out of the page into its own layer: some sites' layouts keep
    // the picture drawn where the video used to be. Moving it in one step keeps it playing.
    let placeholder = null;
    let layer = null;
    if (el.tagName === 'VIDEO') {
      placeholder = document.createComment('lantern-video');
      el.before(placeholder);
      layer = document.createElement('div');
      layer.style.cssText = STAGE_CSS;
      layer.classList.add('__lantern-stage');
      layer.appendChild(el);
      document.documentElement.appendChild(layer);
    } else {
      for (let p = parentOf(el); p && p !== document.documentElement; p = parentOf(p)) {
        if (p.nodeType === 1) restyle(p, ANCESTOR_CSS);
      }
    }
    restyle(el, STAGE_CSS);
    el.classList.add('__lantern-stage');
    document.documentElement.classList.add('__lantern-theater');
    stage = { el, saved, placeholder, layer };

    el.dispatchEvent(new CustomEvent('__lanternfsstate', { bubbles: true, composed: true }));
    if (opts.notifyParent) reportStage(true);

    if (isFrame(el)) {
      if (!opts.fromChild) send(el.contentWindow, { t: 'stageInside' });
    } else {
      const video = el.tagName === 'VIDEO' ? el : el.querySelector('video');
      if (video) {
        activeMedia = video;
        if (video.paused) video.play().catch(() => {});
      }
    }
    return true;
  }

  function exitTheater(options) {
    const opts = Object.assign({ notifyParent: true, cascade: true }, options);
    if (!stage) return false;
    const { el, saved, placeholder, layer } = stage;
    stage = null;
    for (const [node, style] of saved.reverse()) {
      if (style === null) node.removeAttribute('style');
      else node.setAttribute('style', style);
    }
    el.classList.remove('__lantern-stage');
    if (placeholder) {
      if (placeholder.isConnected) placeholder.replaceWith(el);
      else document.body.appendChild(el);
      layer.remove();
    }
    document.documentElement.classList.remove('__lantern-theater');
    document.dispatchEvent(new CustomEvent('__lanternfsstate'));
    if (opts.cascade && isFrame(el)) send(el.contentWindow, { t: 'exitStage' });
    if (opts.notifyParent) reportStage(false);
    return true;
  }

  // ---- Full screen in Apple's own player ----

  // The video last handed to the TV's player, so its position can be restored afterwards.
  let nativeVideo = null;

  const videoIn = (el) => (el instanceof HTMLVideoElement ? el : (el && el.querySelector ? el.querySelector('video') : null));

  /// Sends a video's stream to the TV's own player. Only works for streams with a real web
  /// address; videos fed to the page piece by piece (blob: addresses) stay in the page.
  function handOff(video) {
    const src = video && (video.currentSrc || video.src);
    if (!src || !/^https?:/i.test(src)) return false;
    nativeVideo = video;
    post({
      type: 'video',
      src,
      time: video.currentTime || 0,
      live: !Number.isFinite(video.duration),
      page: location.href,
      agent: navigator.userAgent,
    });
    video.pause();
    return true;
  }

  /// Full screen for whatever is playing: Apple's player if possible, otherwise the page's
  /// video stretched over the whole screen.
  function fullScreen(target) {
    markUserAction();
    const el = target || (activeMedia && activeMedia.isConnected ? activeMedia : null) || bestStageTarget();
    if (!el) return false;
    if (isFrame(el)) {
      send(el.contentWindow, { t: 'fullScreen' });
      return true;
    }
    const video = videoIn(el);
    if (video && handOff(video)) return true;
    return enterTheater(el);
  }

  function resumeAt(seconds) {
    if (nativeVideo && nativeVideo.isConnected) {
      if (Number.isFinite(nativeVideo.duration)) nativeVideo.currentTime = seconds;
      nativeVideo = null;
      return;
    }
    for (const frame of frames()) send(frame.contentWindow, { t: 'resumeAt', seconds });
  }

  // Fullscreen requests from the page itself (see lantern-page.js).
  document.addEventListener('__lanternfs', (event) => {
    const el = event.composedPath()[0];
    fullScreen(el instanceof Element ? el : null);
  }, true);
  document.addEventListener('__lanternfsexit', () => exitTheater(), true);

  // ---- Scrolling ----

  function canScroll(el, dx, dy) {
    const style = getComputedStyle(el);
    const scrollsY = el === document.body || /(auto|scroll|overlay)/.test(style.overflowY);
    const scrollsX = el === document.body || /(auto|scroll|overlay)/.test(style.overflowX);
    if (dy && scrollsY && (dy > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 1 : el.scrollTop > 0)) return true;
    if (dx && scrollsX && (dx > 0 ? el.scrollLeft + el.clientWidth < el.scrollWidth - 1 : el.scrollLeft > 0)) return true;
    return false;
  }

  /// 'inner' when the pointer is over a scrollable box inside the page, otherwise 'page'.
  function scrollerAt(x, y) {
    let depth = 0;
    for (let e = elementAt(x, y); e && e.nodeType === 1 && e !== document.documentElement && depth < 25; e = parentOf(e), depth++) {
      if (e === document.body) break;
      const style = getComputedStyle(e);
      const scrollsY = /(auto|scroll|overlay)/.test(style.overflowY) && e.scrollHeight > e.clientHeight + 1;
      const scrollsX = /(auto|scroll|overlay)/.test(style.overflowX) && e.scrollWidth > e.clientWidth + 1;
      if (scrollsY || scrollsX) return 'inner';
    }
    const root = document.scrollingElement || document.documentElement;
    return root.scrollHeight > root.clientHeight + 1 ? 'page' : 'inner';
  }

  function scrollAt(x, y, dx, dy, smooth) {
    const behavior = smooth ? 'smooth' : 'auto';
    for (let e = elementAt(x, y); e && e.nodeType === 1 && e !== document.documentElement; e = parentOf(e)) {
      if (e === document.body && document.scrollingElement === document.documentElement) break;
      if (canScroll(e, dx, dy)) {
        e.scrollBy({ left: dx, top: dy, behavior });
        return 'inner';
      }
    }
    const root = document.scrollingElement || document.documentElement;
    if (dy < 0 && !dx && root.scrollTop <= 0) return 'top';
    window.scrollBy({ left: dx, top: dy, behavior });
    return 'page';
  }

  // Gliding, to match Lantern's native scrolling for boxes inside the page: each request adds
  // speed, and the box slows to a stop by itself, one animation frame at a time.
  const GLIDE_RATE = 4.5;
  let glide = null;

  function glideAt(x, y, dx, dy, maxSpeed) {
    const root = document.scrollingElement || document.documentElement;
    let target = root;
    for (let e = elementAt(x, y); e && e.nodeType === 1 && e !== document.documentElement; e = parentOf(e)) {
      if (e === document.body && document.scrollingElement === document.documentElement) break;
      if (canScroll(e, dx, dy)) {
        target = e;
        break;
      }
    }
    if (!glide || glide.el !== target) {
      glide = { el: target, vx: 0, vy: 0, x: target.scrollLeft, y: target.scrollTop, last: 0, running: false };
    }
    // Going the other way stops the glide first.
    if (glide.vx * dx < 0) glide.vx = 0;
    if (glide.vy * dy < 0) glide.vy = 0;
    glide.vx = Math.max(-maxSpeed, Math.min(maxSpeed, glide.vx + dx * GLIDE_RATE));
    glide.vy = Math.max(-maxSpeed, Math.min(maxSpeed, glide.vy + dy * GLIDE_RATE));
    if (!glide.running) {
      glide.running = true;
      glide.x = target.scrollLeft;
      glide.y = target.scrollTop;
      glide.last = performance.now();
      requestAnimationFrame(stepGlide);
    }
    return target === root ? 'page' : 'inner';
  }

  function stepGlide(now) {
    const g = glide;
    if (!g || !g.el.isConnected) {
      glide = null;
      return;
    }
    const dt = Math.max(0, Math.min(0.05, (now - g.last) / 1000));
    g.last = now;
    // If the box moved by itself, carry on from where it is.
    if (Math.abs(g.el.scrollTop - g.y) > 2) g.y = g.el.scrollTop;
    if (Math.abs(g.el.scrollLeft - g.x) > 2) g.x = g.el.scrollLeft;
    const maxX = Math.max(0, g.el.scrollWidth - g.el.clientWidth);
    const maxY = Math.max(0, g.el.scrollHeight - g.el.clientHeight);
    g.x += g.vx * dt;
    g.y += g.vy * dt;
    // Reaching an end stops the glide that way.
    if ((g.x <= 0 && g.vx < 0) || (g.x >= maxX && g.vx > 0)) g.vx = 0;
    if ((g.y <= 0 && g.vy < 0) || (g.y >= maxY && g.vy > 0)) g.vy = 0;
    g.x = Math.max(0, Math.min(maxX, g.x));
    g.y = Math.max(0, Math.min(maxY, g.y));
    const decay = Math.exp(-GLIDE_RATE * dt);
    g.vx *= decay;
    g.vy *= decay;
    try {
      g.el.scrollTo({ left: g.x, top: g.y, behavior: 'instant' });
    } catch {
      g.el.scrollLeft = g.x;
      g.el.scrollTop = g.y;
    }
    if (Math.hypot(g.vx, g.vy) < 6) {
      g.running = false;
      return;
    }
    requestAnimationFrame(stepGlide);
  }

  // ---- Page details for the library ----

  function bestIcon() {
    let best = null;
    let bestSize = -1;
    const links = document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]');
    for (const link of links) {
      if (!link.href || /\.svg(\?|#|$)/i.test(link.href) || /svg/.test(link.type)) continue;
      const declared = (link.getAttribute('sizes') || '').match(/(\d+)x\d+/);
      const size = declared ? Number(declared[1]) : (link.rel.includes('apple') ? 180 : 32);
      if (size > bestSize) { best = link.href; bestSize = size; }
    }
    return best;
  }

  // ---- Messages from parent and child frames ----

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || data.__lantern !== TOKEN) return;
    event.stopImmediatePropagation();

    if (!isTop && event.source === window.parent) {
      if (isVerificationFrame) {
        if (data.t === 'click') post({ type: 'verification' });
        return;
      }
      switch (data.t) {
        case 'click': clickAt(data.x, data.y); break;
        case 'hover': hoverAt(data.x, data.y); break;
        case 'setText': setText(data.value); break;
        case 'choose': choose(data.index); break;
        case 'media': controlMedia(data.action, data.value); break;
        case 'stageInside': enterTheater(null, { notifyParent: false }); break;
        case 'fullScreen': fullScreen(null); break;
        case 'resumeAt': resumeAt(data.seconds); break;
        case 'exitStage': exitTheater({ notifyParent: false }); break;
      }
      return;
    }

    if (data.t === 'stage') {
      const frame = frameFor(event.source);
      if (!frame) return;
      if (data.on) enterTheater(frame, { fromChild: true });
      else if (stage && stage.el === frame) exitTheater({ cascade: false });
    }
  }, true);

  // ---- Called by the TV app (top frame only) ----

  if (isTop) {
    const scale = (viewWidth) => window.innerWidth / viewWidth;
    window.__lantern = {
      hover: (x, y, vw) => {
        const s = scale(vw);
        const result = hoverAt(x * s, y * s);
        if (result.rect) result.rect = result.rect.map((n) => n / s);
        return result;
      },
      click: (x, y, vw) => { const s = scale(vw); return clickAt(x * s, y * s); },
      scroll: (x, y, dx, dy, vw, smooth) => {
        const s = scale(vw);
        return scrollAt(x * s, y * s, dx * s, dy * s, smooth);
      },
      scroller: (x, y, vw) => { const s = scale(vw); return scrollerAt(x * s, y * s); },
      glide: (x, y, dx, dy, vw) => {
        const s = scale(vw);
        return glideAt(x * s, y * s, dx * s, dy * s, 6000 * s);
      },
      page: (x, y, direction, vw) => {
        const s = scale(vw);
        return scrollAt(x * s, y * s, 0, direction * innerHeight * 0.8, true);
      },
      setText,
      choose,
      media: (action, value) => controlMedia(action, value || 0),
      theater: () => enterTheater(null),
      fullScreen: () => fullScreen(null),
      resumeAt,
      exitTheater: () => exitTheater(),
      info: () => ({ icon: bestIcon(), theater: !!stage }),
    };
  } else {
    window.__lantern = {};
  }
})();
