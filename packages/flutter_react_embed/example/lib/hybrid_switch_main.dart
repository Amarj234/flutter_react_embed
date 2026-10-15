// Hybrid engine harness: switches one ReactView between ReactEmbedType.web
// (WebView) and ReactEmbedType.native (ReactHost).
//
//   flutter run -t lib/hybrid_switch_main.dart --dart-define=FRE_REACT_NATIVE=true
//
// tool/run_local_test.sh builds the React Native probe bundle first and, in
// soak mode, passes --dart-define=FRE_AUTOCYCLE=<n> so the harness switches
// engines n times unattended. Every step is logged as a `FRE_HARNESS` line.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';

import 'hybrid/hybrid_probe.dart';

void main() => runApp(const HybridHarnessApp());

/// Root widget.
class HybridHarnessApp extends StatelessWidget {
  /// Creates the app.
  const HybridHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_react_embed hybrid harness',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), useMaterial3: true),
      home: const HybridHarnessPage(),
    );
  }
}

/// Shows one surface at a time and probes it after every switch.
class HybridHarnessPage extends StatefulWidget {
  /// Creates the page.
  const HybridHarnessPage({super.key});

  @override
  State<HybridHarnessPage> createState() => _HybridHarnessPageState();
}

class _HybridHarnessPageState extends State<HybridHarnessPage> {
  /// Engine on screen, or null when the view is unmounted.
  ReactEmbedType? _type = ReactEmbedType.web;
  int _generation = 0;
  int _passed = 0;
  int _failed = 0;
  bool _cycling = false;
  final List<String> _lines = <String>[];
  Completer<ProbeResult>? _probe;
  ProbeEventLog? _log;

  @override
  void initState() {
    super.initState();
    _say('START reactNativeLinked=$kReactNativeLinked autoCycles=$kAutoCycles rounds=$kRounds');
    if (kAutoCycles > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_soak(kAutoCycles, kRounds)));
    }
  }

  @override
  void dispose() {
    unawaited(_log?.close());
    super.dispose();
  }

  void _say(String line) {
    debugPrint('$kLogTag $line');
    if (!mounted) {
      return;
    }
    setState(() {
      _lines.insert(0, line);
      if (_lines.length > 200) {
        _lines.removeLast();
      }
    });
  }

  /// Mounts [type] (or nothing) as a new surface and returns its probe result.
  Future<ProbeResult?> _show(ReactEmbedType? type) {
    if (type == ReactEmbedType.native && !kReactNativeLinked) {
      _say('SKIP native: build without FRE_REACT_NATIVE=true');
      return Future<ProbeResult?>.value();
    }
    unawaited(_log?.close());
    _log = null;
    final Completer<ProbeResult> probe = Completer<ProbeResult>();
    _probe = probe;
    setState(() {
      _type = type;
      _generation++;
    });
    return type == null ? Future<ProbeResult?>.value() : probe.future;
  }

  void _onViewCreated(ReactEmbedType type, int generation, ReactViewController controller) {
    final Completer<ProbeResult>? probe = _probe;
    final ProbeEventLog log = ProbeEventLog(controller);
    _log = log;
    _say('CREATED ${type.name} gen=$generation view=${controller.viewId} runtime=${controller.runtime.id}');
    exerciseSurface(type, controller, log, generation: generation).then(
      (ProbeResult result) {
        _passed++;
        _say('PASS ${type.name} gen=$generation in ${result.elapsed.inMilliseconds} ms');
        if (probe != null && !probe.isCompleted) {
          probe.complete(result);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _failed++;
        _say('FAIL ${type.name} gen=$generation: $error');
        if (probe != null && !probe.isCompleted) {
          probe.completeError(error, stackTrace);
        }
      },
    );
  }

  void _onError(ReactEmbedType type, ReactEmbedException error) {
    _failed++;
    _say('ERROR ${type.name} gen=$_generation: $error');
    final Completer<ProbeResult>? probe = _probe;
    if (probe != null && !probe.isCompleted) {
      probe.completeError(error);
    }
  }

  /// Unattended soak: [rounds] rounds of [cycles] switches, idling on an empty
  /// screen after each round so the script can measure what was left behind.
  Future<void> _soak(int cycles, int rounds) async {
    for (int round = 1; round <= rounds && mounted; round++) {
      await _autoCycle(cycles, label: 'ROUND $round/$rounds');
      await Future<void>.delayed(kRoundIdle);
    }
    _say('DONE rounds=$rounds cycles=$cycles passed=$_passed failed=$_failed');
  }

  Future<void> _autoCycle(int cycles, {String label = 'CYCLES'}) async {
    if (_cycling) {
      return;
    }
    setState(() => _cycling = true);
    final int passedBefore = _passed;
    final int failedBefore = _failed;
    final List<ReactEmbedType> order = kReactNativeLinked
        ? <ReactEmbedType>[ReactEmbedType.web, ReactEmbedType.native]
        : <ReactEmbedType>[ReactEmbedType.web];
    for (int i = 0; i < cycles && mounted; i++) {
      final ReactEmbedType type = order[i % order.length];
      try {
        await _show(type).timeout(const Duration(seconds: 30));
      } on Object catch (error) {
        _say('CYCLE $i ${type.name} failed: $error');
      }
    }
    // End on an empty screen so the script measures what the switches left behind.
    await _show(null);
    await Future<void>.delayed(const Duration(seconds: 1));
    _say('$label DONE cycles=$cycles passed=${_passed - passedBefore} failed=${_failed - failedBefore}');
    if (mounted) {
      setState(() => _cycling = false);
    }
  }

  Future<void> _manualProbe(ReactEmbedType? type) async {
    try {
      await _show(type);
    } on Object catch (_) {
      // Already logged by _onViewCreated / _onError.
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReactEmbedType? type = _type;
    final int generation = _generation;
    return Scaffold(
      appBar: AppBar(
        title: Text('Hybrid harness · ${type?.name ?? 'unmounted'}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('passed $_passed · failed $_failed · RN ${kReactNativeLinked ? 'linked' : 'not linked'}'),
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _cycling ? null : () => _manualProbe(ReactEmbedType.web),
                  child: const Text('Web'),
                ),
                FilledButton(
                  onPressed: _cycling || !kReactNativeLinked ? null : () => _manualProbe(ReactEmbedType.native),
                  child: const Text('Native'),
                ),
                OutlinedButton(onPressed: _cycling ? null : () => _manualProbe(null), child: const Text('Unmount')),
                OutlinedButton(
                  onPressed: _cycling ? null : () => _autoCycle(20),
                  child: Text(_cycling ? 'Cycling…' : 'Auto-cycle ×20'),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
              child: type == null
                  ? const Center(child: Text('No surface mounted'))
                  : ReactView(
                      key: ValueKey<int>(generation),
                      configuration: hybridConfiguration(type, generation: generation),
                      onViewCreated: (ReactViewController c) => _onViewCreated(type, generation, c),
                      onError: (ReactEmbedException e, StackTrace _) => _onError(type, e),
                      placeholderBuilder: (BuildContext _) => const Center(child: CircularProgressIndicator()),
                    ),
            ),
          ),
          Expanded(
            flex: 2,
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _lines.length,
              itemBuilder: (BuildContext _, int i) =>
                  Text(_lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}
