/// Describes the React bundle installed by `tool/setup_test_react.sh`.
library;

part 'react_app_manifest.g.dart';

/// Build metadata for `assets/react_app/`.
class ReactAppManifest {
  /// Creates a manifest. Only the generated part file calls this.
  const ReactAppManifest({
    required this.available,
    required this.bundle,
    required this.indexSha256,
    required this.repository,
    required this.ref,
    required this.commit,
    required this.fileCount,
    required this.builtAt,
  });

  /// Whether the setup script has installed a bundle.
  final bool available;

  /// Flutter asset key of the bundle directory.
  final String bundle;

  /// SHA-256 of the installed index.html; passed as `bundleSha256` so the
  /// native host refuses a bundle that changed after the build.
  final String? indexSha256;

  /// Source repository.
  final String repository;

  /// Requested tag, branch or commit.
  final String ref;

  /// Resolved commit SHA.
  final String? commit;

  /// Number of installed files.
  final int fileCount;

  /// UTC build timestamp (ISO 8601).
  final String? builtAt;
}
