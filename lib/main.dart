import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'core/storage/local_cache.dart';
import 'features/account/login_screen.dart';
import 'features/library/library_screen.dart';
import 'features/library/warm_start_screen.dart';
import 'app/provider_factory.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep scrolled-past thumbnails decoded so returning to them is instant.
  PaintingBinding.instance.imageCache
    ..maximumSize = 3000
    ..maximumSizeBytes = 256 * 1024 * 1024;
  runApp(
    NcloudApp(
      controller: AppController(
        store: SecureSessionStore(),
        client: createCloudBackend(),
        cache: LocalCache.platform(),
        pathlessTimeline: true,
      ),
    ),
  );
}

class NcloudApp extends StatefulWidget {
  const NcloudApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<NcloudApp> createState() => _NcloudAppState();
}

class _NcloudAppState extends State<NcloudApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.setBrowsingActive(state == AppLifecycleState.resumed);
    widget.controller.setSyncForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ncloud',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (widget.controller.starting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (widget.controller.warming) {
          return WarmStartScreen(controller: widget.controller);
        }
        return widget.controller.connected
            ? LibraryScreen(controller: widget.controller)
            : LoginScreen(controller: widget.controller);
      },
    ),
  );
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0082C9),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFF8FBFF)
        : const Color(0xFF101418),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      selectedColor: scheme.primaryContainer,
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
  );
}
