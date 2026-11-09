import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/models.dart';

/// A server that counts the work it is asked to do, and can be told to fail in
/// specific ways, so tests can check cost and error handling.
class FakeServer implements CloudBackend {
  FakeServer() {
    folders.addAll(['', 'Backup']);
  }

  final folders = <String>{};
  final files =
      <String, ({List<int> bytes, int size, String etag, String? sha1})>{};

  /// Behave like a server that does not keep a checksum with the file.
  bool dropFingerprints = false;

  int listings = 0;
  int entriesListed = 0;
  int stats = 0;
  int uploads = 0;
  int folderRequests = 0;
  final uploadLog = <({List<String> path, String? sha1, DateTime? modified})>[];

  /// Runs before each upload; throw to make the server fail it.
  FutureOr<void> Function(List<String> path, int attempt)? beforeUpload;
  final _attempts = <String, int>{};
  int _revision = 0;

  void put(String path, List<int> bytes, {String? sha1}) {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      folders.add(parts.take(i).join('/'));
    }
    files[path] = (
      bytes: bytes,
      size: bytes.length,
      etag: '"${++_revision}"',
      sha1: sha1,
    );
  }

  @override
  Future<UploadResult> uploadNew(
    Account account,
    List<String> path,
    Stream<List<int>> bytes,
    int size, {
    String? sha1,
    DateTime? modified,
    String? replacing,
  }) async {
    final name = path.join('/');
    final attempt = _attempts[name] = (_attempts[name] ?? 0) + 1;
    await beforeUpload?.call(path, attempt);
    if (replacing == null
        ? files.containsKey(name)
        : files[name]?.etag != replacing) {
      throw const CloudException('exists', statusCode: 412);
    }
    final data = await bytes.expand((chunk) => chunk).toList();
    if (sha1 != null && sha1 != sha1Of(data)) {
      throw const CloudException('checksum mismatch', statusCode: 400);
    }
    put(name, data, sha1: dropFingerprints ? null : sha1);
    uploads++;
    uploadLog.add((path: path, sha1: sha1, modified: modified));
    return UploadResult(etag: files[name]!.etag);
  }

  int downloads = 0;

  @override
  Future<CloudDownload> download(
    Account account,
    CloudFile file, {
    String? expectedRevision,
  }) async {
    downloads++;
    final value = files[file.path.join('/')];
    if (value == null) throw const CloudException('gone', statusCode: 404);
    return CloudDownload(file, Stream.value(value.bytes));
  }

  int moves = 0;

  @override
  Future<void> move(
    Account account,
    CloudFile file,
    List<String> destination,
  ) async {
    final from = file.path.join('/');
    final to = destination.join('/');
    if (files.containsKey(to)) {
      throw const CloudException('exists', statusCode: 412);
    }
    final value = files.remove(from);
    if (value == null) throw const CloudException('gone', statusCode: 404);
    files[to] = value;
    moves++;
  }

  @override
  Future<RemoteStat?> stat(Account account, List<String> path) async {
    stats++;
    final name = path.join('/');
    if (folders.contains(name)) return const RemoteStat(isDirectory: true);
    final file = files[name];
    return file == null
        ? null
        : RemoteStat(
            isDirectory: false,
            size: file.size,
            etag: file.etag,
            sha1: file.sha1,
          );
  }

  @override
  Future<void> ensureFolder(Account account, List<String> path) async {
    folderRequests++;
    folders.add(path.join('/'));
  }

  @override
  Future<FolderListing> listFolder(
    Account account,
    List<String> path, {
    bool metadataOnly = false,
    bool optional = false,
  }) async {
    listings++;
    final prefix = path.isEmpty ? '' : '${path.join('/')}/';
    final children = [
      for (final name in files.keys)
        if (name.startsWith(prefix) &&
            !name.substring(prefix.length).contains('/'))
          CloudFile(
            path: name.split('/'),
            name: name.split('/').last,
            isDirectory: false,
            size: files[name]!.size,
            etag: files[name]!.etag,
          ),
    ];
    entriesListed += children.length;
    return FolderListing(children: children);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected backend call: ${invocation.memberName}',
  );
}

String sha1Of(List<int> data) => sha1.convert(data).toString();

/// A device folder of generated files, listed and exported like a real one.
class FakeDevice implements FolderAccess {
  FakeDevice(this.staging);

  final Directory staging;
  final entries = <String, DeviceEntry>{};
  final contents = <String, List<int>>{};
  bool wifi = true;
  int exports = 0;
  int discards = 0;

  /// Runs before each export; throw to make the provider fail that file.
  FutureOr<void> Function(String name)? beforeExport;

  void add(String path, List<int> bytes, {int modified = 1700000000000}) {
    final name = path.split('/').last;
    entries[path] = DeviceEntry(
      name,
      false,
      bytes.length,
      modified,
      contentType: 'image/jpeg',
    );
    contents[path] = bytes;
  }

  /// What is directly in [path]: the files there and the folders below it.
  /// Files are added with their whole path, such as `Trips/Rome/a.jpg`.
  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async {
    final prefix = path.isEmpty ? '' : '${path.join('/')}/';
    final result = <DeviceEntry>[];
    final folders = <String>{};
    for (final MapEntry(key: name, value: entry) in entries.entries) {
      if (!name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        result.add(entry);
      } else {
        folders.add(rest.substring(0, slash));
      }
    }
    return [
      for (final folder in folders) DeviceEntry(folder, true, 0, 0),
      ...result,
    ];
  }

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    exports++;
    await beforeExport?.call(path.last);
    final file = File('${staging.path}/${exports}_${path.last}.part');
    await file.writeAsBytes(contents[path.join('/')]!);
    return file;
  }

  @override
  Future<void> discard(File staged) async {
    discards++;
    if (await staged.exists()) await staged.delete();
  }

  @override
  Future<SyncConditions> conditions() async =>
      SyncConditions(wifi: wifi, charging: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected device call: ${invocation.memberName}',
  );
}
