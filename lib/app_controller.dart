import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'demo.dart';
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
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
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
      FormatException() => 'Invalid address, name, or server response. ${error.message}',
      SocketException() => 'No connection to the server. Check your network.',
      FileSystemException() => 'Cannot access this file. Check free space and permissions.',
      TimeoutException() => 'The operation timed out. Please try again.',
      PlatformException() => 'A device service failed. Please retry or restart the app.',
      _ => 'The operation failed unexpectedly. Please retry and check server compatibility.',
    };

class AppController extends ChangeNotifier {
  AppController({required this.store, NextcloudClient? client})
      : client = client ?? NextcloudClient();

  final SessionStore store;
  final NextcloudClient client;
  Account? account;
  bool demo = false;
  bool starting = true;
  bool signingIn = false;
  bool loading = false;
  bool busy = false;
  int tab = 0;
  List<String> directory = [];
  List<CloudFile> items = [];
  String? error;
  String? notice;
  int _loadVersion = 0;
  int _loginVersion = 0;
  List<CloudFile> _demo = [];
  final Map<String, Future<Uint8List>> _previews = {};

  bool get connected => account != null || demo;

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
    cancelLogin();
    demo = true;
    _demo = demoFiles();
    tab = 0;
    directory = [];
    error = null;
    notice = null;
    unawaited(load());
  }

  Future<void> passwordLogin(String server, String user, String password) async {
    final version = ++_loginVersion;
    signingIn = true;
    error = null;
    notifyListeners();
    try {
      final result = await client.authenticate(normalizeServer(server), user, password);
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
        throw const CloudException('Could not open your browser. Try an app password instead.');
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
        throw const CloudException('Sign-in timed out. Start again to get a new login link.');
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
    _loginVersion++;
    signingIn = false;
    notifyListeners();
  }

  Future<void> _saveAccount(Account result) async {
    await store.write(result.encode());
    account = result;
    demo = false;
    tab = 0;
    directory = [];
    await load();
  }

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!demo) {
        await store.clear();
        final cache = Directory('${(await getTemporaryDirectory()).path}/ncloud-downloads');
        if (await cache.exists()) await cache.delete(recursive: true);
      }
      _loadVersion++;
      _loginVersion++;
      _previews.clear();
      account = null;
      demo = false;
      _demo = [];
      items = [];
      directory = [];
      notice = null;
      loading = false;
    } catch (e) {
      error = 'Could not completely clear local session data. ${errorMessage(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> selectTab(int value) async {
    tab = value;
    directory = [];
    await load();
  }

  Future<void> openFolder(CloudFile folder) async {
    tab = 1;
    directory = [...folder.path];
    await load();
  }

  Future<void> goTo(List<String> path) async {
    directory = [...path];
    await load();
  }

  Future<void> load() async {
    final version = ++_loadVersion;
    loading = true;
    error = null;
    items = [];
    notifyListeners();
    try {
      final List<CloudFile> result;
      if (tab == 3) {
        result = [];
      } else if (demo) {
        result = _demo.where((file) => switch (tab) {
              0 => file.isMedia,
              2 => file.favorite,
              _ => file.path.length == directory.length + 1 &&
                  listEquals(file.path.take(directory.length).toList(), directory),
            }).toList();
        if (tab == 1) {
          result.sort((a, b) => a.isDirectory == b.isDirectory
              ? a.name.compareTo(b.name)
              : a.isDirectory ? -1 : 1);
        }
      } else if (account case final account?) {
        result = tab == 1
            ? await client.listFiles(account, directory)
            : await client.search(account, favorites: tab == 2);
      } else {
        result = [];
      }
      if (version == _loadVersion) items = result;
    } catch (e) {
      if (version == _loadVersion) error = errorMessage(e);
    } finally {
      if (version == _loadVersion) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _action(Future<void> Function() action, String success) async {
    if (busy) return;
    busy = true;
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
          _demo = _demo.map((f) => f.key == file.key
              ? f.withFavorite(!file.favorite) : f).toList();
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
        if (demo) throw const CloudException('Connect a Nextcloud server to upload files.');
        await client.upload(account!, [...directory, name], bytes, size);
      }, 'Upload complete');

  Future<Uint8List> preview(CloudFile file, {bool retry = false}) {
    if (retry) _previews.remove(file.key);
    // Keep only a small, session-scoped thumbnail cache.
    if (_previews.length >= 40 && !_previews.containsKey(file.key)) {
      _previews.remove(_previews.keys.first);
    }
    return _previews.putIfAbsent(file.key, () => client.preview(account!, file));
  }

  Future<File> download(CloudFile file) async {
    if (demo) throw const CloudException('Demo files are illustrations. Connect a server to download.');
    if (busy) throw const CloudException('Wait for the current transfer to finish.');
    busy = true;
    notifyListeners();
    File? output;
    try {
      final folder = Directory('${(await getTemporaryDirectory()).path}/ncloud-downloads');
      await folder.create(recursive: true);
      validateName(file.name);
      final response = await client.download(account!, file);
      // Separate each transfer so identical filenames never collide.
      final transfer = await folder.createTemp('transfer-');
      output = File('${transfer.path}/${file.name}');
      final sink = output.openWrite();
      try {
        await sink.addStream(response.stream.timeout(const Duration(seconds: 45)));
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
  void dispose() {
    _loginVersion++;
    client.close();
    super.dispose();
  }
}
