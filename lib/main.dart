import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = true;
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('baseUrl') ?? '';
  runApp(ProviderScope(
    overrides: [baseUrlProvider.overrideWith(() => BaseUrlNotifier(savedUrl))],
    child: const OpenCodeMirrorApp(),
  ));
}

class OpenCodeMirrorApp extends StatelessWidget {
  const OpenCodeMirrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenCode Mirror',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const PlaceholderScreen(),
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text('OpenCode Mirror', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Phase 2 — state layer ready',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
