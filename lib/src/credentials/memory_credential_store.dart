import 'credential_store.dart';

/// In-memory store for **tests and non-Flutter tooling only**.
///
/// Do **not** use in production/release builds: secrets sit in process heap
/// with no encryption, persistence controls, or wipe-on-dispose.
final class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _secrets = {};

  @override
  Future<String?> read(String providerId) async => _secrets[providerId];

  @override
  Future<void> write(String providerId, String secret) async {
    _secrets[providerId] = secret;
  }

  @override
  Future<void> delete(String providerId) async {
    _secrets.remove(providerId);
  }
}
