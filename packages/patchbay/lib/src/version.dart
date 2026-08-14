/// The `patchbay` package version the host was compiled from.
///
/// A Dart runtime cannot read its own `pubspec.yaml`, so the only way a host
/// can tell a client which build it is running is to carry the number in the
/// binary. It is served as `serverVersion` on the identity plane.
///
/// This is the fifth place a release has to bump, which is why
/// `test/release_version_parity_test.dart` pins it to the four manifests: a
/// stale constant here would make every host lie about itself, and lying is
/// worse than not reporting at all.
const String patchbayPackageVersion = '0.2.1';
