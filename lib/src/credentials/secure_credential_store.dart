import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

/// [CredentialStore] backed by [FlutterSecureStorage] with hardened defaults.
final class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({
    FlutterSecureStorage? storage,
    this.keyPrefix = 'ia_router.credential.',
  }) : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: encryptedSharedPreferences,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  /// Contract: Android uses EncryptedSharedPreferences when [storage] omitted.
  static const bool encryptedSharedPreferences = true;

  /// Contract: iOS keychain accessibility when [storage] omitted.
  static const String iosKeychainAccessibility = 'first_unlock_this_device';

  final FlutterSecureStorage _storage;
  final String keyPrefix;

  String _key(String providerId) => '$keyPrefix$providerId';

  @override
  Future<String?> read(String providerId) => _storage.read(key: _key(providerId));

  @override
  Future<void> write(String providerId, String secret) =>
      _storage.write(key: _key(providerId), value: secret);

  @override
  Future<void> delete(String providerId) =>
      _storage.delete(key: _key(providerId));
}
