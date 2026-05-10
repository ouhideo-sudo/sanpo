import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Manifest から API キーを取得する
class ApiKeys {
  static const MethodChannel _channel = MethodChannel('sanpo/config');

  static bool get isRouteSuggestionSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<String> getMapsApiKey() async {
    if (!isRouteSuggestionSupportedPlatform) {
      return '';
    }

    final key = await _channel.invokeMethod<String>('getMapsApiKey');
    return key?.trim() ?? '';
  }
}
