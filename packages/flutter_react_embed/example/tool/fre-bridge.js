/*
 * flutter_react_embed bridge shim for unmodified single-page apps.
 *
 * tool/setup_test_react.sh copies this file next to the built index.html and
 * loads it as the first classic <script> in <head>, so it runs before the
 * app's module scripts. It implements the native host's wire contract:
 *
 *   window.__freNative.postMessage(frame)  JS -> host   (installed by the host)
 *   window.__freReceive(frame)             host -> JS   (defined here)
 *
 * and reports what the app does as JSON-RPC notifications, which reach Dart
 * as ReactBridgeEvents:
 *
 *   hello         first frame; tells the host the bridge is ready
 *   domReady      DOMContentLoaded, with elapsed ms
 *   loaded        window load, with elapsed ms and resource count
 *   route         path/hash changes (history API, popstate, hashchange)
 *   console       console.log/info/warn/error/debug calls
 *   click         clicks on links, buttons and tabs
 *   mounted / propsApplied / unmounted   host lifecycle acknowledgements
 *   dropped       how many console/click events the rate limiter dropped
 *
 * JSON-RPC methods Dart can call: ping, getState, navigate({path}).
 *
 * Routes (navigate's path and the mount's moduleName) state their routing
 * mode explicitly, because the router type cannot be detected reliably
 * before the app has started:
 *   '#/charts'  hash routing (React Router HashRouter): sets location.hash
 *   '/charts'   history routing (BrowserRouter): pushState + popstate
 *
 * Opened outside the host (a normal browser), the shim does nothing.
 */
(function () {
  'use strict';

  var native = window.__freNative;
  if (!native || typeof native.postMessage !== 'function' || window.__freReceive) {
    return;
  }

  var boot = window.__FRE_BOOT__ || {};
  var MAX_TEXT = 500;
  var EVENTS_PER_SECOND = 40;
  var mounted = null;
  var props = {};

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  function send(message) {
    try {
      native.postMessage(JSON.stringify(message));
    } catch (_) {
      // Never let the bridge throw into the host app.
    }
  }

  function emit(name, params) {
    send({ jsonrpc: '2.0', method: name, params: params || {} });
  }

  // Console and click events can burst; cap them and report what was dropped.
  var budget = EVENTS_PER_SECOND;
  var dropped = 0;
  setInterval(function () {
    if (dropped > 0) {
      emit('dropped', { count: dropped });
      dropped = 0;
    }
    budget = EVENTS_PER_SECOND;
  }, 1000);

  function emitLimited(name, params) {
    if (budget > 0) {
      budget -= 1;
      emit(name, params);
    } else {
      dropped += 1;
    }
  }

  function clip(text) {
    text = String(text);
    return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) + '…' : text;
  }

  function describe(value) {
    if (value instanceof Error) return value.name + ': ' + value.message;
    if (typeof value === 'string') return value;
    try {
      return JSON.stringify(value);
    } catch (_) {
      return String(value);
    }
  }

  // ---------------------------------------------------------------------------
  // Observed app activity
  // ---------------------------------------------------------------------------

  function currentLocation() {
    return { path: window.location.pathname, hash: window.location.hash, title: document.title };
  }

  var lastRoute = null;
  function routeChanged(trigger) {
    var key = window.location.pathname + window.location.hash;
    if (key === lastRoute) return;
    lastRoute = key;
    var route = currentLocation();
    route.trigger = trigger;
    emit('route', route);
  }

  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    history[name] = function () {
      var result = original.apply(this, arguments);
      routeChanged(name);
      return result;
    };
  });
  window.addEventListener('popstate', function () { routeChanged('popstate'); });
  window.addEventListener('hashchange', function () { routeChanged('hashchange'); });

  ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
    var original = console[level];
    if (typeof original !== 'function') return;
    console[level] = function () {
      try {
        var text = Array.prototype.map.call(arguments, describe).join(' ');
        emitLimited('console', { level: level, message: clip(text) });
      } catch (_) {}
      return original.apply(console, arguments);
    };
  });

  document.addEventListener(
    'click',
    function (event) {
      var target = event.target && event.target.closest
        ? event.target.closest('a, button, [role="button"], [role="tab"], .nav-link')
        : null;
      if (!target) return;
      var label = (target.innerText || target.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ');
      emitLimited('click', {
        tag: target.tagName.toLowerCase(),
        text: label.slice(0, 80),
        href: target.getAttribute('href'),
      });
    },
    true,
  );

  document.addEventListener('DOMContentLoaded', function () {
    emit('domReady', { ms: Math.round(performance.now()) });
  });
  window.addEventListener('load', function () {
    emit('loaded', {
      ms: Math.round(performance.now()),
      resources: performance.getEntriesByType('resource').length,
    });
    routeChanged('load');
  });

  // ---------------------------------------------------------------------------
  // Host -> JS
  // ---------------------------------------------------------------------------

  function rpcError(code, message) {
    var error = new Error(message);
    error.rpcCode = code;
    return error;
  }

  function navigate(path) {
    if (path.charAt(0) === '#') {
      window.location.hash = path;
    } else {
      history.pushState(null, '', path);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }
  }

  function publishProps() {
    window.__FRE_PROPS__ = props;
    window.dispatchEvent(new CustomEvent('fre:props', { detail: props }));
  }

  var handlers = {
    ping: function () {
      return 'pong';
    },
    getState: function () {
      var state = currentLocation();
      state.mounted = mounted;
      state.props = props;
      state.scrollY = Math.round(window.scrollY);
      return state;
    },
    navigate: function (params) {
      var path = params && params.path;
      if (typeof path !== 'string' || path.length === 0) {
        throw rpcError(-32602, 'navigate requires {"path": string}');
      }
      navigate(path);
      return currentLocation();
    },
  };

  window.__freReceive = function (frame) {
    var message;
    try {
      message = JSON.parse(frame);
    } catch (_) {
      return;
    }
    var params = message.params || {};

    switch (message.method) {
      case '$/mount':
        mounted = { viewId: params.viewId, moduleName: params.moduleName, cacheKey: params.cacheKey };
        props = params.props || {};
        publishProps();
        // moduleName is the initial route; a reattached surface keeps its own.
        if (!params.reattached && params.moduleName && params.moduleName !== '/' && params.moduleName !== '#/') {
          navigate(params.moduleName);
        }
        emit('mounted', { viewId: params.viewId, moduleName: params.moduleName, reattached: !!params.reattached });
        return;
      case '$/updateProps':
        props = params.props || {};
        publishProps();
        emit('propsApplied', props);
        return;
      case '$/unmount':
        emit('unmounted', { viewId: params.viewId, cacheKey: params.cacheKey });
        mounted = null;
        return;
      case '$/cancelRequest':
        return;
    }

    if (message.id === undefined || message.id === null) {
      // A Dart event: re-dispatch it for app code that wants to listen.
      window.dispatchEvent(new CustomEvent('fre:event', { detail: { name: message.method, data: params } }));
      return;
    }

    var handler = handlers[message.method];
    if (!handler) {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'No JS handler for ' + message.method } });
      return;
    }
    try {
      var result = handler(message.params);
      send({ jsonrpc: '2.0', id: message.id, result: result === undefined ? null : result });
    } catch (error) {
      send({
        jsonrpc: '2.0',
        id: message.id,
        error: {
          code: error.rpcCode || -32000,
          message: String(error.message || error),
          data: { stack: String(error.stack || '') },
        },
      });
    }
  };

  // First frame: the host completes initializeEngine when it arrives.
  emit('hello', {
    runtimeId: boot.runtimeId,
    platform: boot.platform,
    transport: boot.transport,
    href: window.location.href,
  });
})();
