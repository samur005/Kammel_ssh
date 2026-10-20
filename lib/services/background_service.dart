import 'dart:io';

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Thin bridge to the native Android foreground service that keeps the app
/// process — and therefore every running PTY/SSH shell — alive while the app is
/// in the background, the way Termux does.
///
/// On any non-Android platform the methods are no-ops, so callers don't need to
/// branch on the platform themselves.
class BackgroundService {
  BackgroundService._();

  static const MethodChannel _channel =
      MethodChannel('com.antigravity.terminalagent/background');

  static bool _running = false;
  static bool get isRunning => _running;

  /// Starts the persistent foreground service + notification. Safe to call
  /// repeatedly; the native side just refreshes the notification.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startBackgroundService');
      _running = true;
    } catch (_) {
      // Service couldn't start (e.g. notifications blocked, or the native
      // handler wasn't ready yet). The app keeps working; it just won't survive
      // aggressive background kills. Caught broadly to also swallow
      // MissingPluginException, which isn't a PlatformException.
    }
  }

  /// Stops the service and fully closes the app (mirrors the notification's
  /// "Salir" action).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopBackgroundService');
      _running = false;
    } catch (_) {
      // Ignore — nothing actionable.
    }
  }

  /// Native notification texts in the app's current language. Keys match
  /// android/app/src/main/res/values*/strings.xml.
  static Map<String, String> nativeStrings() => {
        'fg_title': tr('ABSssh activo'),
        'fg_text': tr('Las sesiones siguen ejecutándose en segundo plano'),
        'fg_text_wakelock': tr('Wakelock activo · las tareas siguen con la pantalla apagada'),
        'fg_acquire': tr('Adquirir wakelock'),
        'fg_release': tr('Liberar wakelock'),
        'fg_exit': tr('Salir'),
        'fg_channel_name': tr('Sesiones en segundo plano'),
        'fg_channel_desc': tr('Mantiene las terminales activas mientras la app está minimizada'),
        'alert_question': tr('El agente pregunta'),
        'alert_question_desc': tr('El agente terminó'),
        'alert_done': tr('El agente espera una respuesta, un permiso o una selección'),
        'alert_done_desc': tr('El agente dejó de escribir sin pedir nada'),
        'alert_bell': tr('Campana del programa'),
        'alert_bell_desc': tr('El programa pidió atención explícitamente (campana u OSC 9/777)'),
        'alert_disconnect': tr('Sesión caída'),
        'alert_disconnect_desc': tr('Se perdió la conexión SSH de una sesión'),
        'alert_default': tr('Avisos de agente'),
        'alert_default_desc': tr('Una sesión de terminal pide tu atención'),
        'alert_summary': tr('%d sesiones piden tu atención'),
      };

  /// Sends [nativeStrings] to Android so the foreground notification, its
  /// actions and the channel names follow the in-app language (including
  /// "System"). Called at startup and on every language change.
  static Future<void> pushStrings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setNativeStrings', {'strings': nativeStrings()});
    } catch (_) {
      // Older native side / no engine: resources fallback still applies.
    }
  }
}
