import 'dart:math';

/// Connection tuning the user can change in Settings → Connection.
class ConnectionTuning {
  /// SSH keepalive ping interval; 0 disables it.
  final int keepAliveSeconds;

  /// TCP connect + per-hop budget.
  final int connectTimeoutSeconds;

  /// Reconnect by itself after an unexpected drop.
  final bool autoReconnect;

  /// Give up after this many failed attempts in a row.
  final int maxReconnectAttempts;

  const ConnectionTuning({
    this.keepAliveSeconds = 15,
    this.connectTimeoutSeconds = 15,
    this.autoReconnect = true,
    this.maxReconnectAttempts = 5,
  });

  static const keepAliveChoices = [0, 5, 10, 15, 30, 60];
  static const timeoutChoices = [5, 10, 15, 30, 60];
  static const attemptChoices = [1, 3, 5, 10, 20];

  Duration? get keepAlive =>
      keepAliveSeconds <= 0 ? null : Duration(seconds: keepAliveSeconds);
  Duration get connectTimeout => Duration(seconds: connectTimeoutSeconds);

  ConnectionTuning copyWith({
    int? keepAliveSeconds,
    int? connectTimeoutSeconds,
    bool? autoReconnect,
    int? maxReconnectAttempts,
  }) =>
      ConnectionTuning(
        keepAliveSeconds: keepAliveSeconds ?? this.keepAliveSeconds,
        connectTimeoutSeconds:
            connectTimeoutSeconds ?? this.connectTimeoutSeconds,
        autoReconnect: autoReconnect ?? this.autoReconnect,
        maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
      );
}

/// Exponential backoff with jitter: 1 s, 2 s, 4 s, 8 s… capped at [cap],
/// each multiplied by a random factor in [1 - jitter, 1 + jitter] so several
/// sessions dropped by the same outage don't hammer the server in lockstep.
Duration reconnectDelay(int attempt,
    {Duration base = const Duration(seconds: 1),
    Duration cap = const Duration(seconds: 60),
    double jitter = 0.2,
    Random? random}) {
  final exp = base.inMilliseconds * pow(2, attempt.clamp(0, 16));
  final capped = min(exp.toDouble(), cap.inMilliseconds.toDouble());
  final r = (random ?? Random()).nextDouble() * 2 - 1; // -1..1
  return Duration(milliseconds: (capped * (1 + jitter * r)).round());
}
