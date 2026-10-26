import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Result of resolving the assets for the patch currently running on the device.
class SaturnAssets {
  const SaturnAssets._(this.bundle, this.patchNumber, this.source);

  final AssetBundle bundle;
  final int patchNumber;
  final String source;

  /// Call this before runApp, after ShorebirdUpdater.readCurrentPatch().
  /// The bundle must be installed with DefaultAssetBundle in MaterialApp.builder.
  static Future<SaturnAssets> load({
    required Uri server,
    required String appId,
    required String releaseVersion,
    required String channel,
    required String platform,
    required int patchNumber,
    AssetBundle? base,
    Directory? cacheDirectory,
    Future<Uint8List> Function(Uri uri, int maxBytes)? fetch,
  }) async {
    base ??= rootBundle;
    if (patchNumber < 1) return SaturnAssets._(base, patchNumber, 'base');
    final cache = cacheDirectory ?? await getApplicationSupportDirectory();
    final root = Directory('${cache.path}/saturn_assets/$appId/$releaseVersion/$platform/$patchNumber');
    final pointer = File('${root.path}/active.json');
    fetch ??= (uri, maxBytes) => _get(uri, maxBytes: maxBytes);
    final query = <String, String>{
      'app_id': appId,
      'release_version': releaseVersion,
      'channel': channel,
      'platform': platform,
      'patch_number': '$patchNumber',
    };
    final endpoint = server.resolve('/api/v1/assets/check').replace(queryParameters: query);
    try {
      final response = await fetch(endpoint, 65536);
      final data = jsonDecode(utf8.decode(response)) as Map<String, dynamic>;
      if (data['asset_bundle_available'] != true) {
        return SaturnAssets._(base, patchNumber, 'base');
      }
      final hash = data['sha256'] as String;
      final size = data['size'] as int;
      final url = Uri.parse(data['download_url'] as String);
      if (url.scheme != 'https' && !(server.scheme == 'http' && url.scheme == 'http')) {
        throw const FormatException('Asset URL must use HTTPS');
      }
      if (hash.length != 64 || size < 1 || size > 32 * 1024 * 1024) {
        throw const FormatException('Invalid asset bundle metadata');
      }
      if (!await _hasVerifiedCache(pointer, hash)) {
        final bytes = await fetch(url, size);
        if (bytes.length != size || sha256.convert(bytes).toString() != hash) {
          throw const FormatException('Asset bundle SHA-256 mismatch');
        }
        await _extract(bytes, root, hash);
      }
      return SaturnAssets._(SaturnAssetBundle(root, base), patchNumber, 'downloaded');
    } catch (_) {
      if (await pointer.exists()) {
        return SaturnAssets._(SaturnAssetBundle(root, base), patchNumber, 'cache');
      }
      return SaturnAssets._(base, patchNumber, 'base');
    }
  }
}

/// Loads files from a verified patch overlay and falls back to the packaged app.
class SaturnAssetBundle extends CachingAssetBundle {
  SaturnAssetBundle(this.directory, this.base);

  final Directory directory;
  final AssetBundle base;

  @override
  Future<ByteData> load(String key) async {
    if (!_safePath(key)) return base.load(key);
    final file = File('${directory.path}/files/$key');
    if (await file.exists()) {
      return ByteData.sublistView(await file.readAsBytes());
    }
    return base.load(key);
  }
}

bool _safePath(String name) =>
    name.isNotEmpty &&
    !name.startsWith('/') &&
    !name.contains('\\') &&
    !name.contains(':') &&
    name.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');

Future<bool> _hasVerifiedCache(File pointer, String hash) async {
  if (!await pointer.exists()) return false;
  try {
    final data = jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
    return data['sha256'] == hash;
  } catch (_) {
    return false;
  }
}

Future<Uint8List> _get(Uri uri, {required int maxBytes}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Asset request returned ${response.statusCode}', uri: uri);
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (output.length + chunk.length > maxBytes) {
        throw const FormatException('Asset response exceeds declared size');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<void> _extract(Uint8List bytes, Directory root, String hash) async {
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final staging = Directory('${root.path}.staging');
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  var total = 0;
  try {
    for (final entry in archive) {
      if (!entry.isFile || entry.isSymbolicLink || !_safePath(entry.name)) {
        throw const FormatException('Unsafe asset archive entry');
      }
      total += entry.size;
      if (total > 64 * 1024 * 1024 || archive.length > 4096) {
        throw const FormatException('Asset archive exceeds extraction limit');
      }
      final file = File('${staging.path}/files/${entry.name}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.readBytes()!, flush: true);
    }
    // The compiled Flutter manifest is required for newly added image keys
    // and resolution variants. It must come from the same patched build.
    if (!await File('${staging.path}/files/AssetManifest.bin').exists()) {
      throw const FormatException('AssetManifest.bin missing from archive');
    }
    await File('${staging.path}/active.json').writeAsString(jsonEncode({'sha256': hash}), flush: true);
    if (await root.exists()) await root.delete(recursive: true);
    await staging.rename(root.path);
  } catch (_) {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }
}

