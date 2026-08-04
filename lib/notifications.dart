/// Notifications + foreground keepalive for OpenCode Mirror.
///
/// The foreground task runs purely as a keepalive so the SSE socket (which
/// lives in the main isolate) isn't reaped by Android. Local notifications
/// fire a high-priority heads-up for `permission.asked` and quiet notices
/// for `session.error` / `session.idle` while the app is backgrounded.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _permissionChannel = 'permissions';
  static const _statusChannel = 'status';
  static const _keepaliveChannel = 'keepalive';
  static const _permissionNotificationId = 1001;
  static const _errorNotificationId = 1002;
  static const _idleNotificationId = 1003;
  static const _permissionPayloadPrefix = 'permission:';

  final _local = FlutterLocalNotificationsPlugin();
  final _permissionTap = ValueNotifier<String?>(null);
  String? _launchPermissionId;
  bool _initialized = false;

  /// Initializes the notifications plugin, channels and launch-details
  /// handling. Call once in `main()` before `runApp`.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _local.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
    );

    final android =
        _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _permissionChannel,
        'Permission requests',
        description: 'Approve or reject commands the agent wants to run',
        importance: Importance.max,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _statusChannel,
        'Agent status',
        description: 'Session errors and idle notices',
        importance: Importance.low,
      ),
    );

    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final payload = launch?.notificationResponse?.payload;
      if (payload != null && payload.startsWith(_permissionPayloadPrefix)) {
        _launchPermissionId = payload.substring(_permissionPayloadPrefix.length);
      }
    }
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.startsWith(_permissionPayloadPrefix)) {
      _permissionTap.value = payload.substring(_permissionPayloadPrefix.length);
    }
  }

  /// A permission-id the user tapped (from a tap callback or cold launch).
  /// Returns null when there is none pending.
  String? takePermissionTap() {
    final live = _permissionTap.value;
    if (live != null) {
      _permissionTap.value = null;
      return live;
    }
    final launch = _launchPermissionId;
    _launchPermissionId = null;
    return launch;
  }

  /// Listen for permission-notification taps (use [takePermissionTap] to
  /// consume them).
  ValueListenable<String?> get permissionTap => _permissionTap;

  Future<void> showPermission(PermissionRequest request) async {
    final detail = request.patterns.isEmpty
        ? request.permission
        : '${request.permission} — ${request.patterns.join(', ')}';
    await _local.show(
      id: _permissionNotificationId,
      title: 'Permission requested',
      body: detail,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _permissionChannel,
          'Permission requests',
          importance: Importance.max,
          priority: Priority.high,
          onlyAlertOnce: true,
        ),
      ),
      payload: '$_permissionPayloadPrefix${request.id}',
    );
  }

  Future<void> cancelPermission() async {
    await _local.cancel(id: _permissionNotificationId);
  }

  Future<void> showError(String text) async {
    await _local.show(
      id: _errorNotificationId,
      title: 'Agent error',
      body: text,
      notificationDetails: _statusDetails,
    );
  }

  Future<void> showIdle(String text) async {
    await _local.show(
      id: _idleNotificationId,
      title: 'Agent idle',
      body: text,
      notificationDetails: _statusDetails,
    );
  }

  static const NotificationDetails _statusDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _statusChannel,
      'Agent status',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
    ),
  );

  // ----------------------------------------------------- foreground keepalive

  void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _keepaliveChannel,
        channelName: 'OpenCode Mirror keepalive',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: true,
      ),
    );
  }

  /// Starts the keepalive service (called on connect). Also requests the
  /// Android 13+ notification permission the first time.
  Future<void> startKeepalive() async {
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'OpenCode Mirror',
      notificationText: 'Streaming agent output…',
      callback: _keepAliveCallback,
    );
  }

  Future<void> stopKeepalive() async {
    await FlutterForegroundTask.stopService();
  }
}

/// Runs in the service's own isolate. Keepalive only — the SSE stream lives
/// in the main isolate.
@pragma('vm:entry-point')
Future<void> _keepAliveCallback() async {
  // Intentionally empty.
}
