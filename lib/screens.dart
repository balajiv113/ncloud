import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'media_tile.dart';
import 'models.dart';
import 'nextcloud_client.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Icon(
                        Icons.cloud_outlined,
                        size: 44,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Your cloud.\nOne beautiful home.',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Photos, memories, and everyday files. Together in ncloud, connected directly to your Nextcloud.',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 28),
                  if (controller.error case final error?) ...[
                    MessageCard(message: error, isError: true),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _server,
                    enabled: !controller.signingIn,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Nextcloud server',
                      hintText: 'https://cloud.example.com',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: controller.signingIn
                        ? null
                        : () => controller.browserLogin(
                            _server.text,
                            (uri) => launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                    icon: const Icon(Icons.login),
                    label: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('Connect Nextcloud'),
                    ),
                  ),
                  if (controller.signingIn) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text(
                      'Complete sign-in in your browser, then return here. Your Nextcloud password never enters ncloud.',
                    ),
                    TextButton(
                      onPressed: controller.cancelLogin,
                      child: const Text('Cancel sign-in'),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: controller.enterDemo,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Try demo'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('Use an app password instead'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Create an app password in Nextcloud → Personal settings → Security. Do not enter your main password.',
                        ),
                      ),
                      TextField(
                        controller: _user,
                        enabled: !controller.signingIn,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Username or login email',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: !controller.signingIn,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'App password',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: controller.signingIn
                            ? null
                            : () => controller.passwordLogin(
                                _server.text,
                                _user.text,
                                _password.text,
                              ),
                        child: const Text('Sign in with app password'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'EARLY PREVIEW · Android + iOS',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    const titles = [
      'Your moments',
      'Your files',
      'Your favorites',
      'Your space',
    ];
    const subtitles = [
      'A little closer to everything you love.',
      'Everything you need. Right where it belongs.',
      'The things worth keeping close.',
      'Your server. Your data. Your rules.',
    ];
    final filtered = c.items
        .where((f) => f.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return PopScope(
      canPop: c.directory.isEmpty && !c.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !c.busy && c.directory.isNotEmpty) {
          _clearSearch();
          c.goTo(c.directory.sublist(0, c.directory.length - 1));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_outlined),
              SizedBox(width: 10),
              Text(
                'ncloud',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
          actions: [
            if (c.demo)
              const Chip(
                label: Text('DEMO'),
                avatar: Icon(Icons.science_outlined, size: 16),
              ),
            if (c.tab != 3)
              IconButton(
                tooltip: 'Refresh',
                onPressed: c.loading || c.busy ? null : c.load,
                icon: const Icon(Icons.refresh),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[c.tab],
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitles[c.tab], style: theme.textTheme.bodyMedium),
                    if (c.demo) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Sample illustrations · changes reset when you leave demo',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                    if (c.tab != 3) ...[
                      const SizedBox(height: 20),
                      TextField(
                        controller: _search,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          hintText: c.tab == 1
                              ? 'Filter this folder'
                              : 'Filter loaded items',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear filter',
                                  icon: const Icon(Icons.close),
                                  onPressed: _clearSearch,
                                ),
                          isDense: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (c.busy) ...[
                const LinearProgressIndicator(),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Working… Keep ncloud open until the operation finishes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              if (c.error case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: MessageCard(
                    message: error,
                    isError: true,
                    onRetry: c.loading || c.busy ? null : c.load,
                  ),
                ),
              if (c.notice case final notice?)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Text(
                    notice,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
              if (c.tab == 1) _breadcrumbs(c),
              if ((c.tab == 0 || c.tab == 2) && !c.demo)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Up to ${NextcloudClient.photoLimit} most recently modified ${c.tab == 0 ? 'photos & videos' : 'favorites'} · not capture date',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              Expanded(
                child: c.tab == 3
                    ? _settings(c)
                    : c.loading
                    ? const Center(child: CircularProgressIndicator())
                    : c.error != null && filtered.isEmpty
                    ? const Center(
                        child: Text('Could not load items. Try Refresh.'),
                      )
                    : RefreshIndicator(
                        onRefresh: c.load,
                        child: filtered.isEmpty
                            ? _empty(c)
                            : c.tab == 0
                            ? _photos(filtered, c)
                            : _files(filtered, c),
                      ),
              ),
            ],
          ),
        ),
        floatingActionButton: c.tab == 1
            ? FloatingActionButton.extended(
                onPressed: c.busy ? null : () => _add(c),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: c.tab,
          onDestinationSelected: (index) {
            _clearSearch();
            c.selectTab(index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.photo_library_outlined),
              selectedIcon: Icon(Icons.photo_library),
              label: 'Photos',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Files',
            ),
            NavigationDestination(
              icon: Icon(Icons.star_outline),
              selectedIcon: Icon(Icons.star),
              label: 'Favorites',
            ),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumbs(AppController c) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: () {
            _clearSearch();
            c.goTo([]);
          },
          icon: const Icon(Icons.home_outlined, size: 18),
          label: const Text('All files'),
        ),
        for (var i = 0; i < c.directory.length; i++) ...[
          const Icon(Icons.chevron_right, size: 16),
          TextButton(
            onPressed: () {
              _clearSearch();
              c.goTo(c.directory.take(i + 1).toList());
            },
            child: Text(c.directory[i]),
          ),
        ],
      ],
    ),
  );

  Widget _empty(AppController c) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: constraints.maxHeight * .2),
        Icon(
          _query.isNotEmpty
              ? Icons.search_off
              : c.tab == 0
              ? Icons.photo_library_outlined
              : Icons.folder_open,
          size: 56,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          _query.isNotEmpty
              ? 'No matching items'
              : c.tab == 0
              ? 'Your story starts here'
              : c.tab == 2
              ? 'Keep your favorites close'
              : 'A little room for something new',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _query.isNotEmpty
              ? 'Try another filter.'
              : c.tab == 0
              ? 'Upload photos in Files, then refresh here.'
              : c.tab == 2
              ? 'Star a photo, file, or folder to find it here.'
              : 'Tap Add to upload a file or create a folder.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  Widget _photos(List<CloudFile> files, AppController c) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 145).floor().clamp(2, 6);
      final groups = <String, List<CloudFile>>{};
      for (final file in files) {
        final date = file.modified?.toLocal();
        final label = date == null
            ? 'Date unavailable'
            : '${MaterialLocalizations.of(context).formatMediumDate(date)} · modified';
        groups.putIfAbsent(label, () => []).add(file);
      }
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          for (final group in groups.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Text(
                  group.key,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final file = group.value[index];
                  return Semantics(
                    label: file.name,
                    button: true,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => _open(file, c),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MediaTile(
                              key: ValueKey(file.key),
                              file: file,
                              controller: c,
                            ),
                            if (file.favorite)
                              const Positioned(
                                top: 8,
                                right: 8,
                                child: Icon(
                                  Icons.star,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            if (file.isVideo)
                              const Center(
                                child: Icon(
                                  Icons.play_circle_outline,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black54,
                                    ],
                                  ),
                                ),
                                child: Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }, childCount: group.value.length),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      );
    },
  );

  Widget _files(List<CloudFile> files, AppController c) => ListView.separated(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
    itemCount: files.length,
    separatorBuilder: (_, _) => const SizedBox(height: 4),
    itemBuilder: (context, index) {
      final file = files[index];
      return ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        tileColor: Theme.of(context).colorScheme.surfaceContainerLow,
        leading: file.isMedia
            ? SizedBox(
                width: 48,
                height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: MediaTile(
                    key: ValueKey(file.key),
                    file: file,
                    controller: c,
                  ),
                ),
              )
            : Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  file.isDirectory
                      ? Icons.folder_outlined
                      : Icons.description_outlined,
                ),
              ),
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(file.isDirectory ? 'Folder' : formatBytes(file.size)),
        onTap: () => _open(file, c),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (file.favorite) const Icon(Icons.star, size: 18),
            PopupMenuButton<String>(
              tooltip: 'Actions for ${file.name}',
              enabled: !c.busy,
              onSelected: (value) {
                if (value == 'favorite') c.favorite(file);
                if (value == 'download') shareFile(context, c, file);
                if (value == 'info') _info(file, c);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'favorite',
                  child: Text(
                    file.favorite ? 'Remove favorite' : 'Add favorite',
                  ),
                ),
                if (!file.isDirectory)
                  const PopupMenuItem(
                    value: 'download',
                    child: Text('Download & share'),
                  ),
                const PopupMenuItem(value: 'info', child: Text('Details')),
              ],
            ),
          ],
        ),
      );
    },
  );

  void _open(CloudFile file, AppController c) {
    if (file.isDirectory) {
      _clearSearch();
      c.openFolder(file);
    } else if (file.isMedia) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PhotoScreen(file: file, controller: c),
        ),
      );
    } else {
      _info(file, c);
    }
  }

  void _info(CloudFile file, AppController c) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(file.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('/${file.path.join('/')}'),
            const SizedBox(height: 8),
            Text(
              file.isDirectory
                  ? 'Folder'
                  : '${file.contentType}\n${formatBytes(file.size)}',
            ),
            if (file.modified case final modified?)
              Text(
                'Modified: ${MaterialLocalizations.of(context).formatMediumDate(modified.toLocal())}',
              ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: c.busy
                  ? null
                  : () {
                      Navigator.pop(context);
                      c.favorite(file);
                    },
              icon: Icon(file.favorite ? Icons.star : Icons.star_outline),
              label: Text(file.favorite ? 'Remove favorite' : 'Add favorite'),
            ),
            if (!file.isDirectory)
              FilledButton.icon(
                onPressed: c.busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        shareFile(this.context, c, file);
                      },
                icon: const Icon(Icons.ios_share),
                label: const Text('Download & share'),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _add(AppController c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload file'),
              subtitle: const Text('Keep the app open during upload'),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'folder') {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => const FolderDialog(),
      );
      if (name != null) await c.createFolder(name);
    } else {
      if (c.demo) {
        _snack(context, 'Connect a Nextcloud server to upload your files.');
        return;
      }
      try {
        final destination = [...c.directory];
        final result = await FilePicker.platform.pickFiles();
        if (result == null) return;
        // A picker can outlive navigation or an account change.
        if (!c.connected ||
            c.demo ||
            c.directory.join('/') != destination.join('/')) {
          throw const CloudException(
            'The destination changed. Select the file again.',
          );
        }
        final file = result.files.single;
        await c.upload(file.name, file.xFile.openRead(), file.size);
      } catch (e) {
        if (mounted) _snack(context, errorMessage(e));
      }
    }
  }

  Widget _settings(AppController c) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined, size: 32),
              const SizedBox(height: 12),
              Text(
                c.demo ? 'Make yourself at home' : c.account!.displayName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                c.demo
                    ? 'You are exploring a local demo. No server is connected.'
                    : c.account!.server.toString(),
              ),
              const SizedBox(height: 12),
              const Text(
                'App credentials stay in encrypted device storage. No analytics, advertisements, or ncloud proxy server.',
              ),
            ],
          ),
        ),
      ),
      const ListTile(
        leading: Icon(Icons.check_circle_outline),
        title: Text('Available in this preview'),
        subtitle: Text(
          'Photos & video previews, folders, uploads, downloads, favorites, and local filtering.',
        ),
      ),
      const ListTile(
        leading: Icon(Icons.construction_outlined),
        title: Text('Not yet implemented'),
        subtitle: Text(
          'Automatic camera backup, offline sync, albums, face recognition, semantic search, maps, shared links, trash, file editing, and in-app video playback.',
        ),
      ),
      const ListTile(
        leading: Icon(Icons.extension_outlined),
        title: Text('Nextcloud-powered, not an Immich server'),
        subtitle: Text(
          'Advanced photo intelligence depends on compatible server apps or a future indexing service. Core Nextcloud APIs do not expose every Immich or Google Drive feature.',
        ),
      ),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('ncloud 0.1.0 · early preview'),
        subtitle: Text(
          'One account · HTTPS only · transfers run in the foreground. Previews and downloads may use device cache. Disconnect clears ncloud downloads; copies shared to other apps remain there.',
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: c.busy
            ? null
            : () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(c.demo ? 'Leave demo?' : 'Disconnect account?'),
                    content: Text(
                      c.demo
                          ? 'Demo changes will be discarded.'
                          : 'This removes local credentials and downloaded cache. Your server files are unchanged. Revoke this app password in Nextcloud Security settings to remove server access.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) await c.signOut();
              },
        icon: const Icon(Icons.logout),
        label: Text(
          c.demo ? 'Leave demo & connect server' : 'Disconnect account',
        ),
      ),
    ],
  );
}

class FolderDialog extends StatefulWidget {
  const FolderDialog({super.key});
  @override
  State<FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<FolderDialog> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New folder'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Folder name'),
        onFieldSubmitted: (_) => _submit(),
        validator: (value) {
          try {
            validateName(value?.trim() ?? '');
            return null;
          } on FormatException catch (e) {
            return e.message;
          }
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Create')),
    ],
  );
}

class PhotoScreen extends StatelessWidget {
  const PhotoScreen({super.key, required this.file, required this.controller});
  final CloudFile file;
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(file.name, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Download original & share',
            onPressed: controller.busy
                ? null
                : () => shareFile(context, controller, file),
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.busy) const LinearProgressIndicator(),
            Expanded(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: MediaTile(
                      file: file,
                      controller: controller,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    controller.demo
                        ? 'Demo illustration · not a real photograph'
                        : file.isVideo
                        ? 'Video preview · download to play in another app'
                        : 'Server preview · download & share for the original',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${formatBytes(file.size)} · /${file.path.join('/')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> shareFile(
  BuildContext context,
  AppController controller,
  CloudFile file,
) async {
  try {
    final output = await controller.download(file);
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(output.path)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  } catch (e) {
    if (context.mounted) _snack(context, errorMessage(e));
  }
}

void _snack(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.isError = false,
    this.onRetry,
  });
  final String message;
  final bool isError;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(isError ? Icons.error_outline : Icons.info_outline),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        if (onRetry != null)
          IconButton(
            tooltip: 'Retry',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
  );
}
