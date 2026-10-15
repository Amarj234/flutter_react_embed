/*
 * Mock React Native app for the react_native engine's local tests.
 *
 * tool/run_local_test.sh copies this directory and ../fre-bridge-native.js
 * into .rn_mock/, installs React Native and bundles it into
 * assets/rn/index.android.bundle.
 *
 * It mirrors assets/demo_spa (the web fixture), so the same Dart checks run
 * against both engines:
 *
 *   JSON-RPC methods: add({a, b}), echo(params), getProps(), throwError()
 *   events:           hello (first frame, from the bridge), mounted,
 *                     propsApplied, pong (reply to Dart's ping)
 */
import React, { useEffect, useState } from 'react';
import { AppRegistry, StyleSheet, Text, View } from 'react-native';
import { useFlutterBridge } from './fre-bridge-native';

function withoutMeta(props) {
  const { __fre, ...rest } = props;
  return rest;
}

function FreProbe(props) {
  const [pings, setPings] = useState(0);
  const userProps = withoutMeta(props);
  const propsKey = JSON.stringify(userProps);

  const bridge = useFlutterBridge(props.__fre, {
    add: (params) => params.a + params.b,
    echo: (params) => params,
    getProps: () => userProps,
    throwError: () => {
      throw new Error('probe failure');
    },
  });

  useEffect(
    () =>
      bridge.onEvent((name, data) => {
        if (name !== 'ping') return;
        setPings((count) => count + 1);
        bridge.emit('pong', data);
      }),
    [bridge],
  );

  const viewId = props.__fre ? props.__fre.viewId : null;
  useEffect(() => {
    bridge.emit('mounted', { viewId, engine: 'react_native' });
  }, [bridge, viewId]);

  useEffect(() => {
    bridge.emit('propsApplied', JSON.parse(propsKey));
  }, [bridge, propsKey]);

  return (
    <View style={styles.root} testID="fre-probe">
      <Text style={styles.title}>React Native probe</Text>
      <Text style={styles.line}>runtime {props.__fre ? props.__fre.runtimeId.slice(0, 8) : 'none'}</Text>
      <Text style={styles.line}>view {viewId === null ? '-' : viewId}</Text>
      <Text style={styles.line}>props {propsKey}</Text>
      <Text style={styles.line}>pings {pings}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, padding: 16, backgroundColor: '#E8F0FA' },
  title: { fontSize: 18, fontWeight: '600', marginBottom: 8, color: '#1B2B3A' },
  line: { fontSize: 14, color: '#1B2B3A', marginBottom: 4 },
});

AppRegistry.registerComponent('FreProbe', () => FreProbe);
