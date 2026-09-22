/// Persists API tokens. Keyed by an opaque slot (internal use only).
abstract interface class CredentialStore {
  Future<String?> read(String providerId);

  Future<void> write(String providerId, String secret);

  Future<void> delete(String providerId);
}
