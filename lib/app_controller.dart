import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'demo.dart';
import 'local_cache.dart';
import 'models.dart';
import 'nextcloud_client.dart';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _key = 'ncloud.account.v1';

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

String errorMessage(Object error) => switch (error) {
  CloudException() => error.message,
  FormatException() =>
    'Invalid address, name, or server response. ${error.message}',
  SocketException() => 'No connection to the server. Check your network.',
  FileSystemException() =>
    'Cannot access this file. Check free space and permissions.',
  TimeoutException() => 'The operation timed out. Please try again.',
  PlatformException() =>
    'A device service failed. Please retry or restart the app.',
  _ =>
    'The operation failed unexpectedly. Please retry and check server compatibility.',
};

class AppController extends ChangeNotifier {
  AppController({required this.store, NextcloudClient? client, this.cache})
    : client = client ?? NextcloudClient();

  final SessionStore store;
  final NextcloudClient client;

  /// Optional persistent cache; tests run purely in memory without it.
  final LocalCache? cache;

  /// True while showing locally cached results that are being refreshed.
  bool refreshing = false;
  Account? account;
  bool demo = false;
  bool starting = true;
  bool signingIn = false;
  bool _savingAccount = false;
  bool loading = false;
  bool busy = false;
  bool loadingMore = false;
  bool hasMore = false;
  List<CloudFile> _libraryFiles = [];
  List<NativeAlbum> nativeAlbums = [];
  NativeAlbum? activeNativeAlbum;
  bool smartAlbumOpen = false;
  String? nativeAlbumError;
  List<String>? _demoPhotoRoot;
  List<CloudFile> get libraryFiles => _libraryFiles;
  List<String> get photoRoot =>
      (demo ? _demoPhotoRoot : account?.photoRoot) ??
      (_libraryFiles.any((f) => f.path.firstOrNull == 'Photos')
          ? ['Photos']
          : []);
  List<SmartAlbum> get smartAlbums =>
      buildSmartAlbums(_libraryFiles, photoRoot);
  int completed = 0;
  int total = 0;
  int tab = 0;
  List<String> directory = [];
  List<CloudFile> items = [];
  String? error;
  String? notice;
  int _loadVersion = 0;
  int _loginVersion = 0;
  bool _disposed = false;
  List<CloudFile> _demo = [];
  final Map<String, Future<Uint8List>> _previews = {};
  final Map<String, int> _previewSizes = {};
  int _previewBytes = 0;
  final Map<String, Future<CloudFile?>> _covers = {};
  final Map<String, List<CloudFile>> _demoTrash = {};

  bool get connected => account != null || demo;
  bool get canCancelLogin => signingIn && !_savingAccount;

  Future<void> initialize() async {
    try {
      final saved = await store.read();
      if (saved != null) account = Account.decode(saved);
    } catch (e) {
      error = 'Could not restore the saved account. ${errorMessage(e)}';
    } finally {
      starting = false;
      notifyListeners();
    }
    if (connected) await load();
  }

  void enterDemo() {
    if (_savingAccount) return;
    cancelLogin();
    demo = true;
    _demo = demoFiles();
    _demoTrash.clear();
    tab = 0;
    directory = [];
    error = null;
    notice = null;
    unawaited(load());
  }

  Future<void> passwordLogin(
    String server,
    String user,
    String password,
  ) async {
    final version = ++_loginVersion;
    signingIn = true;
    error = null;
    notifyListeners();
    try {
      final result = await client.authenticate(
        normalizeServer(server),
        user,
        password,
      );
      if (version != _loginVersion) return;
      await _saveAccount(result);
    } catch (e) {
      if (version == _loginVersion) error = errorMessage(e);
    } finally {
      if (version == _loginVersion) {
        signingIn = false;
        notifyListeners();
      }
    }
  }

  Future<void> browserLogin(
    String server,
    Future<bool> Function(Uri) openBrowser,
  ) async {
    final version = ++_loginVersion;
    signingIn = true;
    error = null;
    notifyListeners();
    try {
      final uri = normalizeServer(server);
      final flow = await client.startLogin(uri);
      if (version != _loginVersion) return;
      if (!await openBrowser(flow.login)) {
        throw const CloudException(
          'Could not open your browser. Try an app password instead.',
        );
      }
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (version == _loginVersion && DateTime.now().isBefore(deadline)) {
        final result = await client.pollLogin(uri, flow);
        if (version != _loginVersion) return;
        if (result != null) {
          await _saveAccount(result);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (version == _loginVersion) {
        throw const CloudException(
          'Sign-in timed out. Start again to get a new login link.',
        );
      }
    } catch (e) {
      if (version == _loginVersion) error = errorMessage(e);
    } finally {
      if (version == _loginVersion) {
        signingIn = false;
        notifyListeners();
      }
    }
  }

  void cancelLogin() {
    if (_savingAccount) return;
    _loginVersion++;
    signingIn = false;
    notifyListeners();
  }

  Future<void> _saveAccount(Account result) async {
    _savingAccount = true;
    notifyListeners();
    try {
      await store.write(result.encode());
      account = result;
      demo = false;
      tab = 0;
      directory = [];
      await load();
    } finally {
      _savingAccount = false;
    }
  }

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!demo) {
        await store.clear();
        final cache = Directory(
          '${(await getTemporaryDirectory()).path}/ncloud-downloads',
        );
        if (await cache.exists()) await cache.delete(recursive: true);
        await this.cache?.clear();
      }
      _loadVersion++;
      _loginVersion++;
      _clearPreviews();
      _covers.clear();
      _demoTrash.clear();
      account = null;
      demo = false;
      _demo = [];
      _libraryFiles = [];
      nativeAlbums = [];
      activeNativeAlbum = null;
      smartAlbumOpen = false;
      _demoPhotoRoot = null;
      items = [];
      directory = [];
      notice = null;
      loading = false;
    } catch (e) {
      error =
          'Could not completely clear local session data. ${errorMessage(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> selectTab(int value) async {
    tab = value;
    directory = [];
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    await load();
  }

  Future<void> openFolder(CloudFile folder) async {
    tab = 1;
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    directory = [...folder.path];
    await load();
  }

  Future<void> goTo(List<String> path) async {
    directory = [...path];
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    await load();
  }

  Future<void> openSmartAlbum(List<String> path) async {
    tab = 4;
    directory = [...path];
    activeNativeAlbum = null;
    smartAlbumOpen = true;
    await load();
  }

  Future<void> openNativeAlbum(NativeAlbum album) async {
    activeNativeAlbum = album;
    smartAlbumOpen = false;
    tab = 4;
    directory = [];
    await load();
  }

  Future<void> setPhotoRoot(List<String> path) async {
    if (demo) {
      _demoPhotoRoot = [...path];
    } else if (account case final session?) {
      final updated = session.withPhotoRoot(path);
      try {
        await store.write(updated.encode());
      } catch (e) {
        error = 'Could not save your photo source. ${errorMessage(e)}';
        notifyListeners();
        return;
      }
      account = updated;
    }
    await selectTab(4);
  }

  Future<void> load() async {
    final version = ++_loadVersion;
    final session = account;
    final currentTab = tab;
    final path = [...directory];
    final native = activeNativeAlbum;
    final wholeLibrary =
        (currentTab == 0 || currentTab == 4) && path.isEmpty && native == null;
    _covers.clear();
    loading = true;
    refreshing = false;
    loadingMore = false;
    hasMore = false;
    error = null;
    items = wholeLibrary ? _libraryFiles : [];
    refreshing = items.isNotEmpty;
    notifyListeners();
    final listingKey = _listingKey();
    if (listingKey != null && cache != null) {
      final cached = await cache!.readListing(listingKey);
      if (version != _loadVersion) return;
      if (cached != null && cached.isNotEmpty) {
        items = cached;
        if (wholeLibrary) _libraryFiles = cached;
        refreshing = true;
        notifyListeners();
      }
    }
    try {
      final List<CloudFile> result;
      if (currentTab == 6) {
        final saved = await cache?.readListing(_offlineListingKey) ?? [];
        final available = <CloudFile>[];
        for (final file in saved) {
          if (await offlineCopy(file) != null) available.add(file);
        }
        result = available;
      } else if (currentTab == 3) {
        result = [];
      } else if (demo) {
        result = native != null
            ? _demo.where((f) => f.isMedia && f.favorite).toList()
            : _demo
                  .where(
                    (file) => switch (currentTab) {
                      0 => file.isMedia,
                      2 => file.favorite,
                      4 => file.isMedia && pathStartsWith(file.path, path),
                      5 => false,
                      _ =>
                        file.path.length == directory.length + 1 &&
                            listEquals(
                              file.path.take(directory.length).toList(),
                              directory,
                            ),
                    },
                  )
                  .toList();
        if (currentTab == 1) {
          result.sort(
            (a, b) => a.isDirectory == b.isDirectory
                ? a.name.compareTo(b.name)
                : a.isDirectory
                ? -1
                : 1,
          );
        }
        if (currentTab == 4 && native == null && path.isEmpty) {
          nativeAlbums = [
            const NativeAlbum(
              name: 'Best days',
              davPath: ['demo-album'],
              count: 3,
            ),
          ];
        }
      } else if (session != null) {
        if (native != null) {
          result = await client.albumFiles(session, native, _libraryFiles);
        } else if (currentTab == 1) {
          result = await client.listFiles(session, path);
        } else {
          final fetched = <String, CloudFile>{};
          final cached = [...items];
          final sharedPaths = currentTab == 5
              ? await client.sharedPaths(session)
              : null;
          if (version != _loadVersion) return;
          var offset = 0;
          while (true) {
            final page = await client.search(
              session,
              favorites: currentTab == 2,
              path: path,
              offset: offset,
            );
            if (version != _loadVersion || _disposed) return;
            final before = fetched.length;
            for (final file in page) {
              fetched[file.key] = file;
            }
            if (page.isNotEmpty && fetched.length == before) {
              throw const CloudException(
                'The server repeated a page. Refresh to retry loading your library.',
              );
            }
            offset += page.length;
            hasMore = page.length == NextcloudClient.photoLimit;
            final accumulated = [
              ...fetched.values,
              if (hasMore) ...cached.where((f) => !fetched.containsKey(f.key)),
            ];
            items = sharedPaths == null
                ? accumulated
                : accumulated
                      .where(
                        (f) =>
                            sharedPaths.any((p) => pathStartsWith(f.path, p)),
                      )
                      .toList();
            if (wholeLibrary) _libraryFiles = items;
            loading = false;
            loadingMore = hasMore;
            notifyListeners();
            if (before == 0 && cached.isEmpty && listingKey != null) {
              await cache?.writeListing(listingKey, items);
              if (version != _loadVersion || _disposed) return;
            }
            if (!hasMore) break;
          }
          if (currentTab == 5) {
            result = fetched.values
                .where(
                  (f) => sharedPaths!.any((p) => pathStartsWith(f.path, p)),
                )
                .toList();
          } else {
            result = fetched.values.toList();
          }
        }
      } else {
        result = [];
      }
      if (version == _loadVersion) {
        items = result;
        if (wholeLibrary) _libraryFiles = result;
        if (listingKey != null) {
          unawaited(cache?.writeListing(listingKey, result));
        }
        hasMore = false;
        if (currentTab == 4 &&
            native == null &&
            path.isEmpty &&
            session != null &&
            !demo) {
          nativeAlbumError = null;
          try {
            final own = await client.albums(session);
            if (version != _loadVersion) return;
            final shared = await client.albums(session, shared: true);
            if (version != _loadVersion) return;
            nativeAlbums = [...own, ...shared];
          } catch (e) {
            if (version == _loadVersion) {
              nativeAlbumError =
                  'Could not load Nextcloud albums. ${errorMessage(e)}';
            }
          }
        }
      }
    } catch (e) {
      if (version == _loadVersion) error = errorMessage(e);
    } finally {
      if (version == _loadVersion) {
        loading = false;
        refreshing = false;
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  String? _listingKey() {
    final session = account;
    if (demo || session == null || tab == 3) return null;
    return 'listing|${session.server}|${session.userId}|$tab|'
        '${directory.join('/')}|${activeNativeAlbum?.davPath.join('/') ?? ''}';
  }

  Future<List<CloudFile>> folderContents(List<String> path) async {
    if (demo) {
      return _demo
          .where(
            (f) =>
                f.path.length == path.length + 1 &&
                pathStartsWith(f.path, path),
          )
          .toList();
    }
    return client.listFiles(account!, path);
  }

  Future<CloudFile?> albumCover(CloudFile folder) => _covers.putIfAbsent(
    folder.key,
    () async {
      if (demo) {
        return _demo
            .where((f) => f.isMedia && pathStartsWith(f.path, folder.path))
            .firstOrNull;
      }
      final found = await client.search(account!, path: folder.path, limit: 1);
      return found.firstOrNull;
    },
  );

  Future<bool> organize(
    List<CloudFile> files,
    String operation, {
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) async {
    if (busy || files.isEmpty) return false;
    busy = true;
    error = null;
    notice = null;
    completed = 0;
    total = files.length;
    notifyListeners();
    Object? failure;
    try {
      for (final file in files) {
        if (file.readOnly) {
          throw const CloudException(
            'This album item is view-only. Manage its original in Nextcloud.',
          );
        }
        final target = [...?destination, newName ?? file.name];
        if (operation == 'move' ||
            operation == 'copy' ||
            operation == 'rename') {
          if (operation == 'rename') {
            target.clear();
            target.addAll([...file.path.take(file.path.length - 1), newName!]);
          }
          validateName(target.last);
          if (file.isDirectory && pathStartsWith(target, file.path)) {
            throw const CloudException(
              'A folder cannot be placed inside itself.',
            );
          }
          if (demo) {
            if (_demo.any((f) => listEquals(f.path, target))) {
              throw const CloudException(
                'An item with that name already exists.',
              );
            }
            final affected = _demo
                .where((f) => pathStartsWith(f.path, file.path))
                .toList();
            final moved = affected
                .map(
                  (f) =>
                      f.atPath([...target, ...f.path.skip(file.path.length)]),
                )
                .toList();
            if (operation != 'copy') {
              _demo.removeWhere((f) => pathStartsWith(f.path, file.path));
            }
            _demo.addAll(moved);
          } else {
            await client.transfer(
              account!,
              file,
              target,
              copy: operation == 'copy',
            );
          }
        } else if (operation == 'delete') {
          if (demo) {
            _demoTrash['${file.key}:${DateTime.now().microsecondsSinceEpoch}'] =
                _demo.where((f) => pathStartsWith(f.path, file.path)).toList();
            _demo.removeWhere((f) => pathStartsWith(f.path, file.path));
          } else {
            await client.delete(account!, file);
          }
        } else if (operation == 'favorite') {
          if (demo) {
            _demo = _demo
                .map((f) => f.key == file.key ? f.withFavorite(favorite) : f)
                .toList();
          } else {
            await client.setFavorite(account!, file, favorite);
          }
        } else {
          throw const CloudException('This action is not supported.');
        }
        completed++;
        notifyListeners();
      }
    } catch (e) {
      failure = e;
    }
    _covers.clear();
    await load();
    if (failure != null) {
      error = '$completed of $total completed. ${errorMessage(failure)}';
    } else {
      notice = '$completed ${completed == 1 ? 'item' : 'items'} updated';
    }
    busy = false;
    notifyListeners();
    return failure == null;
  }

  Future<List<TrashEntry>> trash() async {
    if (!demo) return client.trash(account!);
    return _demoTrash.entries
        .map(
          (entry) => TrashEntry(
            key: entry.key,
            name: entry.value.first.name,
            originalPath: entry.value.first.path.join('/'),
            deleted: DateTime.now(),
          ),
        )
        .toList();
  }

  Future<void> restore(TrashEntry entry) async {
    if (busy) throw const CloudException('Wait for the current operation.');
    busy = true;
    notifyListeners();
    try {
      if (demo) {
        final files = _demoTrash[entry.key]!;
        if (_demo.any((f) => f.key == files.first.key)) {
          throw const CloudException(
            'An item already exists at the original location.',
          );
        }
        _demo.addAll(files);
        _demoTrash.remove(entry.key);
      } else {
        await client.restore(account!, entry);
      }
      _covers.clear();
      await load();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _action(Future<void> Function() action, String success) async {
    if (busy) return;
    busy = true;
    total = 0;
    completed = 0;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await action();
      notice = success;
      await load();
    } catch (e) {
      error = errorMessage(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> favorite(CloudFile file) => _action(() async {
    if (demo) {
      _demo = _demo
          .map((f) => f.key == file.key ? f.withFavorite(!file.favorite) : f)
          .toList();
    } else {
      await client.setFavorite(account!, file, !file.favorite);
    }
  }, file.favorite ? 'Removed from favorites' : 'Added to favorites');

  Future<void> createFolder(String name) => _action(() async {
    validateName(name);
    if (demo) {
      final path = [...directory, name];
      if (_demo.any((f) => listEquals(f.path, path))) {
        throw const CloudException('An item with that name already exists.');
      }
      _demo.add(CloudFile(path: path, name: name, isDirectory: true));
    } else {
      await client.createFolder(account!, [...directory, name]);
    }
  }, 'Folder created');

  Future<void> upload(String name, Stream<List<int>> bytes, int size) =>
      _action(() async {
        if (demo) {
          throw const CloudException(
            'Connect a Nextcloud server to upload files.',
          );
        }
        await client.upload(account!, [...directory, name], bytes, size);
      }, 'Upload complete');

  void _discardPreview(String key) {
    _previews.remove(key);
    _previewBytes -= _previewSizes.remove(key) ?? 0;
  }

  void _clearPreviews() {
    _previews.clear();
    _previewSizes.clear();
    _previewBytes = 0;
  }

  Future<Uint8List> preview(
    CloudFile file, {
    bool retry = false,
    int size = 384,
  }) {
    final session = account;
    if (session == null) {
      return Future.error(const CloudException('Reconnect to load previews.'));
    }
    final key =
        '${session.server}|${session.userId}|${file.id ?? file.key}|'
        '${file.modified?.microsecondsSinceEpoch}|${file.size}|$size';
    if (retry) _discardPreview(key);
    final cached = _previews.remove(key);
    if (cached != null) {
      _previews[key] = cached;
      return cached;
    }
    late final Future<Uint8List> pending;
    final disk = cache;
    Future<Uint8List> fetch() async {
      if (!retry && disk != null) {
        final stored = await disk.readThumbnail(key);
        if (stored != null) return stored;
      }
      final bytes = await client.preview(session, file, size: size);
      unawaited(disk?.writeThumbnail(key, bytes));
      return bytes;
    }

    pending = fetch().then(
      (bytes) {
        if (identical(_previews[key], pending)) {
          _previewSizes[key] = bytes.length;
          _previewBytes += bytes.length;
          while (_previewBytes > 24 * 1024 * 1024 && _previews.isNotEmpty) {
            _discardPreview(_previews.keys.first);
          }
        }
        return bytes;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_previews[key], pending)) _discardPreview(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _previews[key] = pending;
    while (_previews.length > 128) {
      _discardPreview(_previews.keys.first);
    }
    return pending;
  }

  /// Previously saved original for offline replay, if any.
  Future<File?> offlineCopy(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) return null;
    final copy = await cache!.original(_originalKey(session, file), file.name);
    return await copy.exists() ? copy : null;
  }

  String _originalKey(Account session, CloudFile file) =>
      'original|${session.server}|${session.userId}|${file.id ?? file.key}|'
      '${file.modified?.microsecondsSinceEpoch}|${file.size}';

  /// Direct authenticated WebDAV stream for the platform video player.
  ({Uri uri, Map<String, String> headers})? streamSource(CloudFile file) {
    final session = account;
    if (demo || session == null) return null;
    return (
      uri: client.fileUri(session, file),
      headers: {'Authorization': session.authorization},
    );
  }

  /// Keeps a full copy of [file] in the cache so it replays without network.
  Future<File> saveOffline(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) {
      throw const CloudException('Offline copies need a connected server.');
    }
    final target = await cache!.original(
      _originalKey(session, file),
      file.name,
    );
    if (!await target.exists()) {
      final downloaded = await download(file);
      try {
        await downloaded.copy(target.path);
      } finally {
        await downloaded.parent.delete(recursive: true);
      }
    }
    final saved = await cache!.readListing(_offlineListingKey) ?? [];
    await cache!.writeListing(_offlineListingKey, [
      ...saved.where((f) => f.key != file.key),
      file,
    ]);
    unawaited(cache!.trim());
    return target;
  }

  String get _offlineListingKey =>
      'offline|${account?.server}|${account?.userId}';

  Future<int> cacheSize() async => await cache?.size() ?? 0;

  Future<void> clearCache() async {
    _clearPreviews();
    _covers.clear();
    await cache?.clear();
    notifyListeners();
  }

  Future<File> download(CloudFile file) async {
    if (demo) {
      throw const CloudException(
        'Demo files are illustrations. Connect a server to download.',
      );
    }
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    busy = true;
    total = 0;
    completed = 0;
    notifyListeners();
    File? output;
    try {
      final folder = Directory(
        '${(await getTemporaryDirectory()).path}/ncloud-downloads',
      );
      await folder.create(recursive: true);
      validateName(file.name);
      final response = await client.download(account!, file);
      // Separate each transfer so identical filenames never collide.
      final transfer = await folder.createTemp('transfer-');
      output = File('${transfer.path}/${file.name}');
      final sink = output.openWrite();
      try {
        await sink.addStream(
          response.stream.timeout(const Duration(seconds: 45)),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      return output;
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadVersion++;
    _loginVersion++;
    client.close();
    super.dispose();
  }
}
