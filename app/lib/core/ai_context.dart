/// Marks API requests issued while an AI tool is executing so the daemon can
/// report "AI executed an operation" notifications.
class AiRequestContext {
  AiRequestContext._();

  static bool active = false;

  static Future<T> run<T>(Future<T> Function() action) async {
    active = true;
    try {
      return await action();
    } finally {
      active = false;
    }
  }
}
