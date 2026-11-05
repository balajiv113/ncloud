import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'local_cache.dart';
import 'screens.dart';
import 'library_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    NcloudApp(
      controller: AppController(
        store: SecureSessionStore(),
        cache: LocalCache.platform(),
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

class _NcloudAppState extends State<NcloudApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
  }

  @override
  void dispose() {
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
        return widget.controller.connected
            ? LibraryScreen(controller: widget.controller)
            : LoginScreen(controller: widget.controller);
      },
    ),
  );
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5670DF),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFFAFAFD)
        : const Color(0xFF101116),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
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
