import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_screen.dart';
import 'dashboard_screen.dart';
import 'notifications.dart';
import 'providers.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = true;
  NotificationService.instance.initForegroundTask();
  await NotificationService.instance.init();
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
      home: const HomeGate(),
    );
  }
}

/// Routes by connection phase:
/// - disconnected → connect screen
/// - connecting (auto-connect from saved URL) → splash
/// - connected → dashboard
/// - error → connect screen with the failure prefilled
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    return switch (connection.phase) {
      ConnectionPhase.disconnected => const ConnectScreen(),
      ConnectionPhase.connecting => _ConnectingSplash(url: connection.baseUrl),
      ConnectionPhase.connected => const DashboardScreen(),
      ConnectionPhase.error => ConnectScreen(
          initialUrl: connection.baseUrl ?? '',
          initialError: connection.error,
        ),
    };
  }
}

class _ConnectingSplash extends StatelessWidget {
  const _ConnectingSplash({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text('Connecting…', style: textTheme.titleMedium),
            if (url != null && url!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                url!,
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
