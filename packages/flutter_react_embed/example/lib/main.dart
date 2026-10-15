import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_react_embed/flutter_react_embed.dart';

import 'react_app_manifest.dart';

void main() => runApp(const EmbedLabApp());

/// The two embedded surfaces the dropdown switches between.
enum EmbeddedSurface {
  /// CoreUI's open-source React admin dashboard, built by
  /// `tool/setup_test_react.sh` into `assets/react_app/`.
  reactDashboard('React Dashboard', Icons.dashboard_outlined),

  /// The hand-written fixture page in `assets/demo_spa/`, rendering state that
  /// Flutter owns and pushes in as props.
  internalState('Internal state view', Icons.data_object);

  const EmbeddedSurface(this.label, this.icon);

  /// Dropdown label.
  final String label;

  /// Dropdown icon.
  final IconData icon;
}

/// Root widget.
class EmbedLabApp extends StatelessWidget {
  /// Creates the app.
  const EmbedLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_react_embed lab',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3A6EA5), useMaterial3: true),
      home: const EmbedLabPage(),
    );
  }
}

// -----------------------------------------------------------------------------
// Log model
// -----------------------------------------------------------------------------

/// Where a log line came from.
enum LogSource {
  /// A JSON-RPC notification from JS (ReactBridgeEvent).
  event('EVT', Color(0xFF4FC3F7)),

  /// A console.* call forwarded by the bridge shim.
  console('CON', Color(0xFFB0BEC5)),

  /// A runtime error reported by the native host.
  error('ERR', Color(0xFFFF8A80)),

  /// A runtime lifecycle change.
  state('STA', Color(0xFFFFD54F)),

  /// Something Flutter did (calls, surface switches).
  host('DART', Color(0xFFA5D6A7));

  const LogSource(this.tag, this.color);

  /// Three-letter tag shown in the panel.
  final String tag;

  /// Tag color.
  final Color color;
}

/// One line in the log panel.
@immutable
class LogEntry {
  /// Creates a log line.
  const LogEntry(this.time, this.source, this.message);

  /// When the line was recorded.
  final DateTime time;

  /// Its origin.
  final LogSource source;

  /// Text shown in the panel.
  final String message;
}

/// Bounded, listenable log. Only the panel listens, so a burst of JS messages
/// never rebuilds the platform view.
class JsLog extends ChangeNotifier {
  /// Lines kept before the oldest are dropped.
  static const int capacity = 500;

  final List<LogEntry> _entries = <LogEntry>[];

  /// Current lines, oldest first.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// Appends a line.
  void add(LogSource source, String message) {
    _entries.add(LogEntry(DateTime.now(), source, message));
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    notifyListeners();
  }

  /// Removes every line.
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

// -----------------------------------------------------------------------------
// Page
// -----------------------------------------------------------------------------

/// Dropdown-switched React surface with a live JS log overlay.
class EmbedLabPage extends StatefulWidget {
  /// Creates the page.
  const EmbedLabPage({super.key});

  @override
  State<EmbedLabPage> createState() => _EmbedLabPageState();
}

class _EmbedLabPageState extends State<EmbedLabPage> {
  final JsLog _log = JsLog();
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];

  EmbeddedSurface _surface = reactAppManifest.available
      ? EmbeddedSurface.reactDashboard
      : EmbeddedSurface.internalState;
  ReactViewController? _controller;

  // State owned by Flutter and rendered by the internal state view.
  int _count = 0;
  bool _darkTheme = false;

  @override
  void initState() {
    super.initState();
    _log.add(
      LogSource.host,
      reactAppManifest.available
          ? 'React bundle ${reactAppManifest.ref} (${_short(reactAppManifest.commit)}), '
                '${reactAppManifest.fileCount} files'
          : 'No React bundle installed; run example/tool/setup_test_react.sh',
    );
  }

  @override
  void dispose() {
    _detachController();
    _log.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Bridge wiring
  // ---------------------------------------------------------------------------

  void _attachController(ReactViewController controller) {
    _detachController();
    final FlutterReactEmbedPlatform platform = FlutterReactEmbedPlatform.instance;
    _log.add(LogSource.host, 'surface attached: view ${controller.viewId}, runtime ${_short(controller.runtime.id)}');
    try {
      _subscriptions
        ..add(controller.events().listen(_onEvent))
        ..add(
          platform.runtimeErrors(controller.runtime).listen((ReactRuntimeError e) {
            final String stack = e.jsStack == null ? '' : '\n${e.jsStack!.split('\n').first}';
            _log.add(LogSource.error, '${e.isFatal ? 'FATAL ' : ''}${e.message}$stack');
          }),
        )
        ..add(
          platform.runtimeStates(controller.runtime).listen((ReactRuntimeState s) {
            _log.add(LogSource.state, 'runtime ${s.name}');
          }),
        );
    } on ReactEmbedException catch (e) {
      _log.add(LogSource.error, 'could not subscribe: ${e.message}');
    }
    setState(() => _controller = controller);
  }

  void _detachController() {
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _controller = null;
  }

  void _onEvent(ReactBridgeEvent event) {
    final Object? data = event.data;
    if (event.name == 'console' && data is Map<String, Object?>) {
      _log.add(LogSource.console, '${data['level']}: ${data['message']}');
      return;
    }
    _log.add(LogSource.event, data == null ? event.name : '${event.name} ${_compact(data)}');
  }

  Future<void> _invoke(String method, [Map<String, Object?>? params]) async {
    final ReactViewController? controller = _controller;
    if (controller == null) return;
    _log.add(LogSource.host, '-> $method${params == null ? '' : ' ${_compact(params)}'}');
    try {
      final Object? result = await controller.invoke<Object?>(method, params: params);
      _log.add(LogSource.host, '<- $method ${_compact(result)}');
    } on ReactEmbedException catch (e) {
      _log.add(LogSource.error, '$method failed: ${e.message}');
    }
  }

  Future<void> _emit(String name, Object? data) async {
    final ReactViewController? controller = _controller;
    if (controller == null) return;
    _log.add(LogSource.host, '-> event $name ${_compact(data)}');
    try {
      await controller.emit(name, data);
    } on ReactEmbedException catch (e) {
      _log.add(LogSource.error, 'emit $name failed: ${e.message}');
    }
  }

  void _select(EmbeddedSurface? surface) {
    if (surface == null || surface == _surface) return;
    _detachController();
    _log.add(LogSource.host, 'switching to ${surface.label}');
    setState(() => _surface = surface);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: DropdownButtonHideUnderline(
          child: DropdownButton<EmbeddedSurface>(
            value: _surface,
            onChanged: _select,
            items: <DropdownMenuItem<EmbeddedSurface>>[
              for (final EmbeddedSurface surface in EmbeddedSurface.values)
                DropdownMenuItem<EmbeddedSurface>(
                  value: surface,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[Icon(surface.icon, size: 20), const SizedBox(width: 8), Text(surface.label)],
                  ),
                ),
            ],
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          _ActionBar(children: _actionsFor(_surface)),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _buildSurface()),
                Positioned(left: 0, right: 0, bottom: 0, child: JsLogPanel(log: _log)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSurface() {
    switch (_surface) {
      case EmbeddedSurface.reactDashboard:
        if (!reactAppManifest.available) {
          return const _MissingBundle();
        }
        return ReactView(
          key: const ValueKey<EmbeddedSurface>(EmbeddedSurface.reactDashboard),
          configuration: ReactViewConfiguration(
            engine: ReactEngineConfig(
              engine: ReactEngineKind.web,
              bundle: reactAppManifest.bundle,
              bundleSha256: reactAppManifest.indexSha256,
            ),
            // The bridge shim treats moduleName as the initial route. CoreUI
            // uses React Router's HashRouter, so routes are '#/...'.
            moduleName: '#/dashboard',
            // Keep the dashboard alive while the other surface is shown.
            cacheKey: 'react-dashboard',
          ),
          onViewCreated: _attachController,
          onError: _onViewError,
          placeholderBuilder: (_) => const Center(child: CircularProgressIndicator()),
          errorBuilder: _buildError,
        );
      case EmbeddedSurface.internalState:
        return ReactView(
          key: const ValueKey<EmbeddedSurface>(EmbeddedSurface.internalState),
          configuration: ReactViewConfiguration(
            engine: const ReactEngineConfig(engine: ReactEngineKind.web, bundle: 'assets/demo_spa/'),
            moduleName: '/state',
            cacheKey: 'internal-state',
            initialProps: <String, Object?>{'count': _count, 'theme': _darkTheme ? 'dark' : 'light'},
          ),
          onViewCreated: _attachController,
          onError: _onViewError,
          placeholderBuilder: (_) => const Center(child: CircularProgressIndicator()),
          errorBuilder: _buildError,
        );
    }
  }

  List<Widget> _actionsFor(EmbeddedSurface surface) {
    final bool ready = _controller != null;
    ActionChip chip(String label, VoidCallback onPressed) =>
        ActionChip(label: Text(label), onPressed: ready ? onPressed : null);

    return switch (surface) {
      EmbeddedSurface.reactDashboard => <Widget>[
        chip('Dashboard', () => _invoke('navigate', <String, Object?>{'path': '#/dashboard'})),
        chip('Charts', () => _invoke('navigate', <String, Object?>{'path': '#/charts'})),
        chip('Cards', () => _invoke('navigate', <String, Object?>{'path': '#/components/cards'})),
        chip('getState', () => _invoke('getState')),
      ],
      EmbeddedSurface.internalState => <Widget>[
        chip('count +1', () => setState(() => _count++)),
        chip(_darkTheme ? 'Light theme' : 'Dark theme', () => setState(() => _darkTheme = !_darkTheme)),
        chip('ping', () => _emit('ping', <String, Object?>{'at': DateTime.now().toIso8601String()})),
        chip('describe', () => _invoke('describe')),
      ],
    };
  }

  void _onViewError(ReactEmbedException error, StackTrace stackTrace) {
    _log.add(LogSource.error, '${error.runtimeType}: ${error.message}');
  }

  Widget _buildError(BuildContext context, ReactEmbedException error, VoidCallback retry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 40),
            const SizedBox(height: 12),
            Text(error.message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  static String _short(String? id) => id == null ? 'n/a' : (id.length <= 8 ? id : id.substring(0, 8));

  static String _compact(Object? value) {
    final String text = value is String ? value : jsonEncode(value);
    return text.length > 300 ? '${text.substring(0, 300)}...' : text;
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: <Widget>[
            for (final Widget child in children) Padding(padding: const EdgeInsets.only(right: 8), child: child),
          ],
        ),
      ),
    );
  }
}

class _MissingBundle extends StatelessWidget {
  const _MissingBundle();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.download_outlined, size: 40),
            SizedBox(height: 12),
            Text('The React dashboard is not installed yet.', textAlign: TextAlign.center),
            SizedBox(height: 8),
            SelectableText(
              'cd packages/flutter_react_embed/example\ntool/setup_test_react.sh',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Log panel overlay
// -----------------------------------------------------------------------------

/// Collapsible overlay listing messages from the JS context in real time.
class JsLogPanel extends StatefulWidget {
  /// Creates a panel showing [log].
  const JsLogPanel({super.key, required this.log});

  /// The log to display.
  final JsLog log;

  @override
  State<JsLogPanel> createState() => _JsLogPanelState();
}

class _JsLogPanelState extends State<JsLogPanel> {
  static const double _expandedHeight = 240;
  final ScrollController _scroll = ScrollController();
  bool _expanded = true;
  bool _followTail = true;

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_scrollToTail);
    _scroll.addListener(() {
      // Stop auto-scrolling while the user reads older lines.
      if (_scroll.hasClients) {
        _followTail = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
      }
    });
  }

  @override
  void dispose() {
    widget.log.removeListener(_scrollToTail);
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToTail() {
    if (!_followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Material(
        color: const Color(0xF7101418),
        elevation: 8,
        child: ListenableBuilder(
          listenable: widget.log,
          builder: (BuildContext context, Widget? _) {
            final List<LogEntry> entries = widget.log.entries;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _header(entries.length),
                if (_expanded)
                  SizedBox(
                    height: _expandedHeight,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      itemCount: entries.length,
                      itemBuilder: (BuildContext context, int index) => _LogLine(entry: entries[index]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(int count) {
    const TextStyle style = TextStyle(color: Colors.white, fontWeight: FontWeight.w600);
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: <Widget>[
            const Icon(Icons.terminal, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Text('JS context log ($count)', style: style),
            const Spacer(),
            IconButton(
              tooltip: 'Clear',
              color: Colors.white70,
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              onPressed: widget.log.clear,
            ),
            Icon(_expanded ? Icons.expand_more : Icons.expand_less, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final DateTime t = entry.time;
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    const TextStyle mono = TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(
        TextSpan(
          style: mono.copyWith(color: Colors.white),
          children: <InlineSpan>[
            TextSpan(
              text: '$stamp ',
              style: mono.copyWith(color: Colors.white38),
            ),
            TextSpan(
              text: '${entry.source.tag.padRight(4)} ',
              style: mono.copyWith(color: entry.source.color, fontWeight: FontWeight.w700),
            ),
            TextSpan(text: entry.message),
          ],
        ),
      ),
    );
  }
}
