import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

import '../models/vpn_profile.dart';

class DvsFileData {
  const DvsFileData({required this.profile, this.expiresAt});

  final VpnProfile profile;
  final DateTime? expiresAt;
}

class DvsFileService {
  static const extension = '.dvs';
  static const _format = 'swock-dvs';
  static const _version = 1;
  static const _encryptedVersion = 2;
  static const _pbkdf2Iterations = 120000;

  bool isDvsFile(String contents) {
    try {
      final decoded = jsonDecode(contents);
      return decoded is Map && decoded['format'] == _format;
    } on FormatException {
      return false;
    }
  }

  String encode(
    VpnProfile profile, {
    required bool locked,
    DateTime? expiresAt,
    String? password,
  }) {
    final portableProfile = profile.copyWith(
      isLocked: locked,
      isSelected: false,
      expiresAt: expiresAt,
      clearExpiresAt: expiresAt == null,
    );
    final payload = const JsonEncoder().convert({
      'expiresAt': expiresAt?.toUtc().toIso8601String(),
      'profile': portableProfile.toJson(),
    });
    final passphrase = password ?? '';
    if (passphrase.isNotEmpty) {
      final random = Random.secure();
      final salt = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final iv = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final keys = _deriveKeys(passphrase, salt);
      final ciphertext = encrypt.Encrypter(
        encrypt.AES(
          encrypt.Key(Uint8List.fromList(keys.sublist(0, 32))),
          mode: encrypt.AESMode.cbc,
        ),
      ).encrypt(payload, iv: encrypt.IV(iv)).bytes;
      final authenticated = Uint8List.fromList([...salt, ...iv, ...ciphertext]);
      final mac = Hmac(sha256, keys.sublist(32)).convert(authenticated);
      return const JsonEncoder.withIndent('  ').convert({
        'format': _format,
        'version': _encryptedVersion,
        'encrypted': true,
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': _pbkdf2Iterations,
        'salt': base64Encode(salt),
        'iv': base64Encode(iv),
        'ciphertext': base64Encode(ciphertext),
        'mac': base64Encode(mac.bytes),
      });
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': _format,
      'version': _version,
      'locked': locked,
      ...jsonDecode(payload) as Map<String, dynamic>,
    });
  }

  bool requiresPassword(String contents) {
    final decoded = jsonDecode(contents);
    return decoded is Map &&
        decoded['format'] == _format &&
        decoded['encrypted'] == true;
  }

  DvsFileData decode(String contents, {String? password}) {
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic> || decoded['format'] != _format) {
      throw const FormatException('This is not a supported .dvs profile file.');
    }
    final Map<String, dynamic> payload;
    final bool locked;
    if (decoded['encrypted'] == true &&
        decoded['version'] == _encryptedVersion) {
      final passphrase = password ?? '';
      if (passphrase.isEmpty) throw const DvsPasswordRequiredException();
      try {
        final salt = base64Decode(decoded['salt'] as String);
        final iv = base64Decode(decoded['iv'] as String);
        final ciphertext = base64Decode(decoded['ciphertext'] as String);
        final suppliedMac = base64Decode(decoded['mac'] as String);
        final keys = _deriveKeys(passphrase, salt);
        final authenticated =
            Uint8List.fromList([...salt, ...iv, ...ciphertext]);
        final expectedMac =
            Hmac(sha256, keys.sublist(32)).convert(authenticated).bytes;
        if (!_constantTimeEquals(expectedMac, suppliedMac)) {
          throw const FormatException(
              'Incorrect password or damaged .dvs file.');
        }
        final plaintext = encrypt.Encrypter(
          encrypt.AES(
            encrypt.Key(Uint8List.fromList(keys.sublist(0, 32))),
            mode: encrypt.AESMode.cbc,
          ),
        ).decryptBytes(
          encrypt.Encrypted(ciphertext),
          iv: encrypt.IV(iv),
        );
        payload = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(plaintext)) as Map);
        locked = true;
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('Incorrect password or damaged .dvs file.');
      }
    } else if (decoded['version'] == _version && decoded['profile'] is Map) {
      payload = Map<String, dynamic>.from(decoded);
      locked = decoded['locked'] as bool? ?? false;
    } else {
      throw const FormatException('This is not a supported .dvs profile file.');
    }
    final expiresAt = DateTime.tryParse(payload['expiresAt'] as String? ?? '');
    final profile = VpnProfile.fromJson(
      Map<String, dynamic>.from(payload['profile'] as Map),
    ).copyWith(
      isLocked: locked,
      expiresAt: expiresAt,
      clearExpiresAt: expiresAt == null,
      isSelected: false,
    );
    return DvsFileData(profile: profile, expiresAt: expiresAt);
  }

  Uint8List _deriveKeys(String password, List<int> salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final block = Uint8List.fromList([...salt, 0, 0, 0, 1]);
    var u = hmac.convert(block).bytes;
    final result = Uint8List.fromList(u);
    for (var index = 1; index < _pbkdf2Iterations; index++) {
      u = hmac.convert(u).bytes;
      for (var byte = 0; byte < result.length; byte++) {
        result[byte] ^= u[byte];
      }
    }
    final secondBlock = Uint8List.fromList([...salt, 0, 0, 0, 2]);
    u = hmac.convert(secondBlock).bytes;
    final second = Uint8List.fromList(u);
    for (var index = 1; index < _pbkdf2Iterations; index++) {
      u = hmac.convert(u).bytes;
      for (var byte = 0; byte < second.length; byte++) {
        second[byte] ^= u[byte];
      }
    }
    return Uint8List.fromList([...result, ...second]);
  }

  bool _constantTimeEquals(List<int> expected, List<int> supplied) {
    if (expected.length != supplied.length) return false;
    var mismatch = 0;
    for (var index = 0; index < expected.length; index++) {
      mismatch |= expected[index] ^ supplied[index];
    }
    return mismatch == 0;
  }
}

class DvsPasswordRequiredException implements Exception {
  const DvsPasswordRequiredException();
}
