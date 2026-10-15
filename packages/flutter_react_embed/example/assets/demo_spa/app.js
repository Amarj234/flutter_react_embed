// Contract fixture for the native hosts. A real micro-frontend gets this
// behaviour from @flutter-react-embed/bridge; this file implements the same
// wire contract by hand so the native layer can be tested without a JS build.
(function () {
  'use strict';
  var boot = window.__FRE_BOOT__ || {};
  var mounted = null;
  var status = document.getElementById('status');
  var propsView = document.getElementById('props');

  function send(message) {
    window.__freNative.postMessage(JSON.stringify(message));
  }

  function render() {
    status.textContent = mounted ? 'mounted: ' + mounted.moduleName : 'idle';
    propsView.textContent = mounted ? JSON.stringify(mounted.props, null, 2) : '';
  }

  var handlers = {
    echo: function (params) { return params; },
    add: function (params) { return params.a + params.b; },
    describe: function () { return { platform: boot.platform, transport: boot.transport, mounted: mounted }; },
    throwError: function () { throw new Error('boom from JS'); },
  };

  window.__freReceive = function (frame) {
    var message = JSON.parse(frame);
    var params = message.params || {};
    switch (message.method) {
      case '$/mount':
        mounted = params;
        render();
        send({ jsonrpc: '2.0', method: 'mounted', params: { viewId: params.viewId, moduleName: params.moduleName, reattached: !!params.reattached } });
        return;
      case '$/updateProps':
        if (mounted) mounted.props = params.props;
        render();
        send({ jsonrpc: '2.0', method: 'propsApplied', params: params.props });
        return;
      case '$/unmount':
        mounted = null;
        render();
        return;
      case '$/cancelRequest':
        return;
    }
    if (message.id === undefined) {
      if (message.method === 'ping') send({ jsonrpc: '2.0', method: 'pong', params: params });
      return;
    }
    var handler = handlers[message.method];
    if (!handler) {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'No JS handler for ' + message.method } });
      return;
    }
    try {
      send({ jsonrpc: '2.0', id: message.id, result: handler(message.params) });
    } catch (e) {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: String(e.message), data: { stack: String(e.stack) } } });
    }
  };

  render();
  // First frame: tells the host the bridge is ready.
  send({ jsonrpc: '2.0', method: 'hello', params: { runtimeId: boot.runtimeId, platform: boot.platform, transport: boot.transport } });
})();
