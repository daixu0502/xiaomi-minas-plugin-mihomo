(function (global) {
  'use strict';

  if ((global.navigator && /SmartStorage|Electron/i.test(global.navigator.userAgent || '')) ||
      global.__MICRO_APP_ENVIRONMENT__ ||
      (global.microApp && typeof global.microApp.dispatch === 'function')) {
    document.documentElement.classList.add('desktop-client');
  }

  function installDesktopWheelSupport() {
    var shell = document.querySelector('.shell');
    if (!document.documentElement.classList.contains('desktop-client') || !shell || shell.getAttribute('data-desktop-wheel') === '1') return;
    shell.setAttribute('data-desktop-wheel', '1');
    function syncDesktopViewport() {
      var viewportHeight = (global.visualViewport && global.visualViewport.height) || global.innerHeight || document.documentElement.clientHeight;
      if (!viewportHeight) return;
      var top = shell.getBoundingClientRect ? Math.max(0, shell.getBoundingClientRect().top) : 0;
      var availableHeight = Math.floor(viewportHeight - top - 72);
      if (availableHeight < 180) availableHeight = Math.max(180, Math.floor(viewportHeight - 24));
      shell.style.setProperty('height', availableHeight + 'px', 'important');
      shell.style.setProperty('max-height', availableHeight + 'px', 'important');
      shell.style.setProperty('min-height', '0', 'important');
      shell.style.setProperty('overflow-x', 'hidden', 'important');
      shell.style.setProperty('overflow-y', 'auto', 'important');
      shell.style.setProperty('overscroll-behavior-y', 'contain', 'important');
    }
    syncDesktopViewport();
    global.addEventListener('resize', syncDesktopViewport);
    if (global.visualViewport) global.visualViewport.addEventListener('resize', syncDesktopViewport);
    function compactDesktopControls(root) {
      var buttons = [];
      if (root.matches && root.matches('button')) buttons.push(root);
      if (root.querySelectorAll) buttons = buttons.concat(Array.prototype.slice.call(root.querySelectorAll('button')));
      buttons.forEach(function (button) {
        if (button.classList.contains('icon-button') || button.classList.contains('mi-picker-close') || button.classList.contains('mi-confirm-close')) {
          button.style.setProperty('width', '38px', 'important');
          button.style.setProperty('height', '38px', 'important');
          button.style.setProperty('min-height', '38px', 'important');
          button.style.setProperty('padding', '0', 'important');
          button.style.setProperty('font-size', '18px', 'important');
        } else {
          button.style.setProperty('min-height', '34px', 'important');
          button.style.setProperty('padding', '7px 10px', 'important');
          button.style.setProperty('font-size', '12px', 'important');
          button.style.setProperty('line-height', '1.3', 'important');
        }
      });
    }
    compactDesktopControls(shell);
    if (global.MutationObserver) new global.MutationObserver(function (records) {
      records.forEach(function (record) { Array.prototype.forEach.call(record.addedNodes, function (node) { if (node.nodeType === 1) compactDesktopControls(node); }); });
    }).observe(shell, { childList: true, subtree: true });
    global.addEventListener('wheel', function (event) {
      if (event.ctrlKey || !event.deltaY || !shell.contains(event.target)) return;
      var node = event.target;
      var scroller = null;
      var direction = event.deltaY > 0 ? 1 : -1;
      while (node && node !== document.body) {
        if (node.scrollHeight > node.clientHeight + 1) {
          var overflowY = global.getComputedStyle(node).overflowY;
          var canScroll = direction > 0 ? node.scrollTop < node.scrollHeight - node.clientHeight - 1 : node.scrollTop > 1;
          if (/auto|scroll|overlay/.test(overflowY) && canScroll) { scroller = node; break; }
        }
        if (node === shell) break;
        node = node.parentElement;
      }
      if (!scroller && shell.scrollHeight > shell.clientHeight + 1) scroller = shell;
      if (!scroller) return;
      var delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? scroller.clientHeight : 1);
      scroller.scrollTop += delta;
      event.preventDefault();
      event.stopPropagation();
    }, { capture: true, passive: false });
  }

  installDesktopWheelSupport();

  var deviceInfo = null;
  var pendingInfo = null;

  function isDesktopClient() {
    var result = Boolean(global.__MICRO_APP_ENVIRONMENT__ ||
      (global.microApp && typeof global.microApp.dispatch === 'function' &&
        typeof global.microApp.addDataListener === 'function'));
    if (result) {
      document.documentElement.classList.add('desktop-client');
      installDesktopWheelSupport();
    }
    return result;
  }

  function normalizeInfo(response) {
    var value = response && (response.deviceInfo || response.data || response);
    if (value && value.data && !value.cgiToken) value = value.data;
    if (!value || !value.cgiPort || !value.cgiToken) return null;
    return value;
  }

  function loadDeviceInfo(forceRefresh) {
    if (!isDesktopClient()) return Promise.resolve(null);
    if (deviceInfo && !forceRefresh) return Promise.resolve(deviceInfo);
    if (pendingInfo && !forceRefresh) return pendingInfo;

    pendingInfo = new Promise(function (resolve) {
      var settled = false;
      var timer = global.setTimeout(function () { finish(null); }, 5000);

      function finish(response) {
        if (settled) return;
        settled = true;
        global.clearTimeout(timer);
        var info = normalizeInfo(response);
        if (info) deviceInfo = info;
        resolve(info);
      }

      try {
        var bridge = global.microApp;
        if (!bridge || typeof bridge.dispatch !== 'function') return finish(null);
        if (typeof bridge.removeDataListener === 'function') bridge.removeDataListener();
        bridge.addDataListener(function (response) {
          if (response && response.cmd && response.cmd !== 'getDeviceInfo') return;
          finish(response);
        });
        bridge.dispatch({ params: { cmd: 'getDeviceInfo', type: forceRefresh ? 'refresh' : '' } });
      } catch (error) {
        finish(null);
      }
    }).then(function (info) {
      pendingInfo = null;
      return info;
    });
    return pendingInfo;
  }

  function pluginUserId() {
    var sources = [global.location.pathname, global.location.href, document.referrer || ''];
    for (var i = 0; i < sources.length; i += 1) {
      var match = String(sources[i]).match(/\/plugin\/(?:u)?(\d+)(?:\/|$)/);
      if (match) return match[1];
    }
    return '';
  }

  function withAuthorization(options, token) {
    var result = {};
    Object.keys(options || {}).forEach(function (key) { result[key] = options[key]; });
    var headers = {};
    if (global.Headers && result.headers instanceof global.Headers) {
      result.headers.forEach(function (value, key) { headers[key] = value; });
    } else {
      Object.keys(result.headers || {}).forEach(function (key) { headers[key] = result.headers[key]; });
    }
    headers.Authorization = token;
    result.headers = headers;
    return result;
  }

  function request(settings) {
    var query = settings.action ? '?action=' + encodeURIComponent(settings.action) : '';
    var relativeUrl = settings.cgi + query;
    var originalOptions = settings.options || {};

    function send(info) {
      var uid = pluginUserId();
      var url = uid ? '/plugin/' + encodeURIComponent(uid) + '/' +
        encodeURIComponent(settings.plugin) + '/' + relativeUrl : relativeUrl;
      return global.fetch(url, info ? withAuthorization(originalOptions, info.cgiToken) : originalOptions);
    }

    return loadDeviceInfo(false).then(send).then(function (response) {
      if (!isDesktopClient() || (response.status !== 401 && response.status !== 403)) return response;
      deviceInfo = null;
      return loadDeviceInfo(true).then(send);
    });
  }

  global.XiaomiPluginClient = { request: request };
})(window);
