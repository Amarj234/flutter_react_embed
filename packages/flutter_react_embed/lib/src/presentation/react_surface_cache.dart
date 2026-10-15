import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_react_embed_platform_interface/flutter_react_embed_platform_interface.dart';

/// A runtime handed back by [ReactSurfaceCache.acquire] for a retained surface.
@immutable
final class ReactSurfaceLease {
  /// Creates a lease.
  const ReactSurfaceLease({required this.runtime, required this.ownsRuntime});

  /// Runtime that still renders the retained surface.
  final ReactRuntimeHandle runtime;

  /// Whether the cache entry, rather than the caller, owns [runtime].
  final bool ownsRuntime;
}

/// LRU cache of native React surfaces kept alive after their `ReactView`
/// leaves the widget tree.
///
/// Remounting a view with the same `cacheKey` reattaches the retained native
/// surface instead of booting a runtime and rendering from scratch. What is
/// retained is platform-specific and owned by native code:
///
/// * Android: the `ReactSurfaceView` (or WebView) and, under texture-layer
///   composition, its `SurfaceTexture` with the last rendered frame, so the
///   view reappears without a blank frame.
/// * iOS: the hosting `UIView` and its layer contents.
/// * Web: the detached DOM element (iframe) and its document.
///
/// A key is used by at most one mounted view at a time. Idle entries beyond
/// [maxRetainedSurfaces] are evicted oldest-first: the native surface is
/// dropped and, if the view had booted its own runtime, that runtime is
/// disposed.
final class ReactSurfaceCache {
  /// Creates a cache retaining at most [maxRetainedSurfaces] idle surfaces.
  ReactSurfaceCache({this.maxRetainedSurfaces = 2, FlutterReactEmbedPlatform? platform})
      : assert(maxRetainedSurfaces >= 0),
        _platformOverride = platform;

  /// Process-wide cache used by `ReactView` unless another one is supplied.
  static final ReactSurfaceCache shared = ReactSurfaceCache();

  /// Maximum number of idle (unmounted) surfaces kept alive.
  final int maxRetainedSurfaces;

  final FlutterReactEmbedPlatform? _platformOverride;

  // Iteration order is least-recently-released first.
  final LinkedHashMap<String, _CacheEntry> _entries = LinkedHashMap<String, _CacheEntry>();

  FlutterReactEmbedPlatform get _platform => _platformOverride ?? FlutterReactEmbedPlatform.instance;

  /// Whether [cacheKey] is currently claimed by a mounted view.
  bool isInUse(String cacheKey) => _entries[cacheKey]?.inUse ?? false;

  /// Number of entries, in use or idle.
  @visibleForTesting
  int get length => _entries.length;

  /// Claims [cacheKey] for a mounting view.
  ///
  /// Returns the retained runtime when a surface is cached under the key, or
  /// `null` when the caller must create one and then call [attach]. Throws
  /// [ReactConfigurationException] if another mounted view holds the key.
  ReactSurfaceLease? acquire(String cacheKey) {
    final _CacheEntry? entry = _entries[cacheKey];
    if (entry == null) {
      return null;
    }
    if (entry.inUse) {
      throw ReactConfigurationException(
        'cacheKey "$cacheKey" is already used by a mounted ReactView; '
        'a native surface can only be attached to one view at a time',
      );
    }
    entry.inUse = true;
    return ReactSurfaceLease(runtime: entry.runtime, ownsRuntime: entry.ownsRuntime);
  }

  /// Records a newly created surface under [cacheKey], marked in use.
  ///
  /// When [ownsRuntime] is true the cache disposes [runtime] on eviction.
  void attach(String cacheKey, ReactRuntimeHandle runtime, {required bool ownsRuntime}) {
    final _CacheEntry? existing = _entries[cacheKey];
    if (existing != null && existing.inUse) {
      throw ReactConfigurationException('cacheKey "$cacheKey" is already attached');
    }
    _entries.remove(cacheKey);
    _entries[cacheKey] = _CacheEntry(runtime: runtime, ownsRuntime: ownsRuntime)..inUse = true;
  }

  /// Marks [cacheKey] idle after its view unmounted, then trims the cache.
  Future<void> release(String cacheKey) async {
    final _CacheEntry? entry = _entries.remove(cacheKey);
    if (entry == null) {
      return;
    }
    entry.inUse = false;
    _entries[cacheKey] = entry; // Re-insert as most recently released.
    await _trim();
  }

  /// Drops [cacheKey] immediately, even if idle entries are below the limit.
  ///
  /// An in-use key cannot be evicted; the call is ignored for it.
  Future<void> evict(String cacheKey) async {
    final _CacheEntry? entry = _entries[cacheKey];
    if (entry == null || entry.inUse) {
      return;
    }
    _entries.remove(cacheKey);
    await _destroy(cacheKey, entry);
  }

  /// Evicts every idle entry.
  Future<void> clear() async {
    final List<String> idle = <String>[
      for (final MapEntry<String, _CacheEntry> e in _entries.entries)
        if (!e.value.inUse) e.key,
    ];
    await Future.wait(idle.map(evict));
  }

  Future<void> _trim() async {
    final List<MapEntry<String, _CacheEntry>> idle =
        _entries.entries.where((MapEntry<String, _CacheEntry> e) => !e.value.inUse).toList();
    final int excess = idle.length - maxRetainedSurfaces;
    if (excess <= 0) {
      return;
    }
    final List<Future<void>> evictions = <Future<void>>[];
    for (final MapEntry<String, _CacheEntry> victim in idle.take(excess)) {
      _entries.remove(victim.key);
      evictions.add(_destroy(victim.key, victim.value));
    }
    await Future.wait(evictions);
  }

  Future<void> _destroy(String cacheKey, _CacheEntry entry) async {
    try {
      await _platform.evictCachedSurface(cacheKey);
      if (entry.ownsRuntime) {
        await _platform.disposeEngine(entry.runtime);
      }
    } on ReactEmbedException catch (error, stackTrace) {
      // Eviction is housekeeping; it must not surface into app code paths.
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'flutter_react_embed',
        context: ErrorDescription('while evicting cached React surface "$cacheKey"'),
      ));
    }
  }
}

final class _CacheEntry {
  _CacheEntry({required this.runtime, required this.ownsRuntime});

  final ReactRuntimeHandle runtime;
  final bool ownsRuntime;
  bool inUse = false;
}
