/// Google Maps API 設定
/// 
/// local.properties から読み込まれる値を保持する
class ApiKeys {
  /// Google Maps Directions API キー
  /// 
  /// 設定方法：
  /// 1. android/local.properties に `MAPS_API_KEY=<your-key>` を追加
  /// 2. ビルド実行時に build.gradle.kts がこのファイルを生成
  static const String mapsApiKey = String.fromEnvironment(
    'MAPS_API_KEY',
    defaultValue: '',
  );

  /// API キーが設定されているか
  static bool get isConfigured => mapsApiKey.isNotEmpty;
}
