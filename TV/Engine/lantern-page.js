// Runs in the page's own world in every frame. It turns the page's fullscreen requests into
// Lantern's theater mode (handled by lantern-isolated.js), and presses Enter for it in a way
// keyCode-based handlers can see.
(() => {
  'use strict';

  // "Verify you're human" checks look for pages that have been modified; leave them untouched.
  const VERIFICATION = /(^|\.)(challenges\.cloudflare\.com|hcaptcha\.com|recaptcha\.net|arkoselabs\.com|funcaptcha\.com|perimeterx\.net|px-cdn\.net|px-cloud\.net|captcha-delivery\.com)$/;
  if (VERIFICATION.test(location.hostname) || (/(^|\.)google\.com$/.test(location.hostname) && location.pathname.startsWith('/recaptcha'))) return;

  let fullscreenElement = null;

  const define = (proto, name, value) => {
    try { Object.defineProperty(proto, name, { value, configurable: true, writable: true }); } catch (e) {}
  };
  const getter = (proto, name, get) => {
    try { Object.defineProperty(proto, name, { get, configurable: true }); } catch (e) {}
  };

  const request = function () {
    this.dispatchEvent(new CustomEvent('__lanternfs', { bubbles: true, composed: true }));
    return Promise.resolve();
  };
  const exit = function () {
    document.dispatchEvent(new CustomEvent('__lanternfsexit'));
    return Promise.resolve();
  };

  for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    define(Element.prototype, name, request);
  }
  for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
    define(HTMLVideoElement.prototype, name, request);
  }
  for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
    define(Document.prototype, name, exit);
  }
  for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
    getter(Document.prototype, name, () => fullscreenElement);
  }
  for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled']) {
    getter(Document.prototype, name, () => true);
  }
  getter(Document.prototype, 'fullscreen', () => fullscreenElement !== null);
  getter(Document.prototype, 'webkitIsFullScreen', () => fullscreenElement !== null);
  getter(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', () => true);
  getter(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', function () {
    return fullscreenElement === this;
  });

  document.addEventListener('__lanternfsstate', (event) => {
    const target = event.target === document ? null : event.composedPath()[0];
    if (target === fullscreenElement) return;
    const previous = fullscreenElement;
    fullscreenElement = target;
    const notified = target || previous || document;
    for (const type of ['fullscreenchange', 'webkitfullscreenchange']) {
      (notified.isConnected ? notified : document).dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  }, true);

  document.addEventListener('__lanternsubmit', (event) => {
    const field = event.composedPath()[0];
    const key = (type) => {
      const keyEvent = new KeyboardEvent(type, { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true, composed: true });
      Object.defineProperty(keyEvent, 'keyCode', { get: () => 13 });
      Object.defineProperty(keyEvent, 'which', { get: () => 13 });
      Object.defineProperty(keyEvent, 'charCode', { get: () => (type === 'keypress' ? 13 : 0) });
      return keyEvent;
    };
    const handled = !field.dispatchEvent(key('keydown'));
    field.dispatchEvent(key('keypress'));
    field.dispatchEvent(key('keyup'));
    if (!handled && field.form) {
      try { field.form.requestSubmit(); } catch (e) { field.form.submit(); }
    }
  }, true);
})();
