/*
 * flutter_react_embed bridge for React Native apps (the `react_native` engine).
 *
 * Copy this file into the React Native project whose bundle Flutter embeds.
 * It implements the native host's wire contract:
 *
 *   NativeModules.FlutterReactEmbed.postMessage(runtimeId, frame)   JS -> host
 *   'freFrame' events {runtimeId, frame} on NativeEventEmitter      host -> JS
 *
 * Every root component Flutter mounts receives `props.__fre`:
 *   {runtimeId, viewId, contractVersion, platform, cacheKey}
 *
 * One JavaScript instance serves every Flutter runtime, so connections are
 * keyed by runtimeId and shared (reference counted) by all surfaces of that
 * runtime: a request from Dart is answered exactly once.
 *
 * JS can also call Dart handlers registered with
 * ReactViewController.registerHandler: `await bridge.call('method', params)`.
 *
 * Usage in a root component:
 *
 *   import { useFlutterBridge } from './fre-bridge-native';
 *
 *   export default function Checkout(props) {
 *     const bridge = useFlutterBridge(props.__fre, {
 *       getTotal: () => ({ total: props.total }),
 *     });
 *     return <Button title="Pay" onPress={() => bridge.emit('paid', { total: props.total })} />;
 *   }
 *   AppRegistry.registerComponent('Checkout', () => Checkout);
 *
 * Props updates from Dart re-render the root natively; nothing to do here.
 */
import { useEffect, useMemo, useRef } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';

const native = NativeModules.FlutterReactEmbed;
const emitter = native ? new NativeEventEmitter(native) : null;

/** runtimeId -> connection */
const connections = new Map();

function send(runtimeId, message) {
  try {
    native.postMessage(runtimeId, JSON.stringify(message));
  } catch (_) {
    // Never let the bridge throw into the app.
  }
}

function rpcError(code, message) {
  const error = new Error(message);
  error.rpcCode = code;
  return error;
}

/** Default deadline for JS -> Dart requests, in milliseconds. */
const CALL_TIMEOUT_MS = 10000;

function createConnection(runtimeId) {
  const handlers = new Map();
  const eventListeners = new Set();
  /** JS -> Dart requests awaiting a reply: id -> {resolve, reject, timer} */
  const pending = new Map();
  let nextRequestId = 1;

  async function answer(message) {
    const handler = handlers.get(message.method);
    if (!handler) {
      send(runtimeId, {
        jsonrpc: '2.0',
        id: message.id,
        error: { code: -32601, message: 'No JS handler for ' + message.method },
      });
      return;
    }
    try {
      const result = await handler(message.params);
      send(runtimeId, { jsonrpc: '2.0', id: message.id, result: result === undefined ? null : result });
    } catch (error) {
      send(runtimeId, {
        jsonrpc: '2.0',
        id: message.id,
        error: {
          code: error.rpcCode || -32000,
          message: String(error.message || error),
          data: { stack: String(error.stack || '') },
        },
      });
    }
  }

  const subscription = emitter.addListener('freFrame', (event) => {
    if (!event || event.runtimeId !== runtimeId) return;
    let message;
    try {
      message = JSON.parse(event.frame);
    } catch (_) {
      return;
    }
    if (typeof message.method !== 'string') {
      // A reply to one of our own requests.
      const request = message.id === undefined ? undefined : pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      clearTimeout(request.timer);
      if (message.error) {
        request.reject(rpcError(message.error.code, message.error.message || 'Dart handler failed'));
      } else {
        request.resolve(message.result === undefined ? null : message.result);
      }
      return;
    }
    if (message.method.startsWith('$/')) return; // Host lifecycle; props arrive natively.
    if (message.id === undefined || message.id === null) {
      eventListeners.forEach((listener) => listener(message.method, message.params || {}));
      return;
    }
    answer(message);
  });

  const connection = {
    references: 0,
    handlers,
    eventListeners,
    emit(name, params) {
      send(runtimeId, { jsonrpc: '2.0', method: name, params: params || {} });
    },
    call(method, params, timeoutMs) {
      return new Promise((resolve, reject) => {
        // String ids never collide with Dart's numeric request ids.
        const id = 'rn-' + nextRequestId++;
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(rpcError(-32001, 'Dart did not answer "' + method + '" within ' + (timeoutMs || CALL_TIMEOUT_MS) + ' ms'));
        }, timeoutMs || CALL_TIMEOUT_MS);
        pending.set(id, { resolve, reject, timer });
        const message = { jsonrpc: '2.0', id, method };
        if (params !== undefined) message.params = params;
        send(runtimeId, message);
      });
    },
    close() {
      subscription.remove();
      handlers.clear();
      eventListeners.clear();
      pending.forEach((request) => {
        clearTimeout(request.timer);
        request.reject(rpcError(-32002, 'Flutter runtime ' + runtimeId + ' disconnected'));
      });
      pending.clear();
    },
  };

  // First frame: the host starts delivering queued frames once it arrives.
  connection.emit('hello', { runtimeId, platform: 'react-native' });
  return connection;
}

/**
 * Connects to the Flutter runtime described by `fre` (the `__fre` prop) and
 * serves `handlers` ({method: (params) => result}). Returns
 * `{emit(name, data), call(method, params, timeoutMs), onEvent(listener) -> unsubscribe,
 * dispose()}`, or null
 * when the component is not running inside flutter_react_embed.
 */
export function connectFlutter(fre, handlers = {}) {
  if (!emitter || !fre || typeof fre.runtimeId !== 'string') return null;
  const runtimeId = fre.runtimeId;
  const owned = Object.keys(handlers);
  const existing = connections.get(runtimeId);
  // Validate before touching shared state, so a rejected call leaks nothing.
  owned.forEach((method) => {
    if (existing && existing.handlers.has(method)) {
      throw rpcError(-32603, 'A handler for "' + method + '" is already registered on runtime ' + runtimeId);
    }
  });
  let connection = existing;
  if (!connection) {
    connection = createConnection(runtimeId);
    connections.set(runtimeId, connection);
  }
  connection.references += 1;
  owned.forEach((method) => connection.handlers.set(method, handlers[method]));

  const listeners = new Set();
  let disposed = false;
  return {
    emit: (name, data) => {
      if (!disposed) connection.emit(name, data);
    },
    call: (method, params, timeoutMs) =>
      disposed
        ? Promise.reject(rpcError(-32002, 'Bridge was disposed'))
        : connection.call(method, params, timeoutMs),
    onEvent: (listener) => {
      connection.eventListeners.add(listener);
      listeners.add(listener);
      return () => {
        connection.eventListeners.delete(listener);
        listeners.delete(listener);
      };
    },
    dispose: () => {
      if (disposed) return;
      disposed = true;
      owned.forEach((method) => connection.handlers.delete(method));
      listeners.forEach((listener) => connection.eventListeners.delete(listener));
      connection.references -= 1;
      if (connection.references === 0) {
        connection.close();
        connections.delete(runtimeId);
      }
    },
  };
}

/**
 * React hook over `connectFlutter`. `handlers` may change between renders;
 * the latest ones are always called. Returns `{emit, call, onEvent}`; outside
 * flutter_react_embed, emit and onEvent are no-ops and call rejects.
 */
export function useFlutterBridge(fre, handlers = {}) {
  const runtimeId = fre ? fre.runtimeId : undefined;
  const latest = useRef(handlers);
  latest.current = handlers;
  const connectionRef = useRef(null);
  const methods = Object.keys(handlers).sort().join('\u0000');

  useEffect(() => {
    const proxies = {};
    methods.split('\u0000').filter(Boolean).forEach((method) => {
      proxies[method] = (params) => latest.current[method](params);
    });
    const connection = connectFlutter(runtimeId ? { runtimeId } : null, proxies);
    connectionRef.current = connection;
    return () => {
      connectionRef.current = null;
      if (connection) connection.dispose();
    };
  }, [runtimeId, methods]);

  return useMemo(
    () => ({
      emit: (name, data) => {
        if (connectionRef.current) connectionRef.current.emit(name, data);
      },
      call: (method, params, timeoutMs) =>
        connectionRef.current
          ? connectionRef.current.call(method, params, timeoutMs)
          : Promise.reject(rpcError(-32002, 'Not running inside flutter_react_embed')),
      onEvent: (listener) => (connectionRef.current ? connectionRef.current.onEvent(listener) : () => {}),
    }),
    [],
  );
}
