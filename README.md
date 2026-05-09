# Sanpo（散歩）

散歩ルート記録・可視化アプリケーション

バージョン: 1.0.1

## 概要

Sanpo は、GPS を使用して散歩ルートをリアルタイムで記録し、Google Maps 上に表示するFlutter アプリです。
ユーザーが歩いた経路を可視化し、距離・時間・平均速度などの統計情報を自動計算します。

## 機能

- **マップベースUI**: Google Maps を統合した直感的なインターフェース
- **ルート記録**: GPS を使用したリアルタイムルート追跡
- **自動計算**: 距離、所要時間、平均速度の自動計算
- **ルート履歴**: 記録したルートを日付別に管理・表示
- **永続化**: 記録内容を デバイスに永続保存

## 技術スタック

- **フレームワーク**: Flutter 3.41.9
- **言語**: Dart 3.11.5
- **状態管理**: SetState
- **永続化**: shared_preferences
- **地図**: google_maps_flutter
- **位置情報**: geolocator
- **プラットフォーム**: Android（メイン）

## ビルド・実行

### 前提条件
- Flutter SDK 3.41.9 以上
- Android SDK API 34 以上
- Google Maps API キー（AndroidManifest.xml に設定）

### 依存関係インストール
```bash
flutter pub get
```

### コード解析
```bash
flutter analyze
```

### テスト実行
```bash
flutter test
```

### デバッグAPKビルド
```bash
flutter build apk --debug
```

## ファイル構成

```
lib/
├── main.dart              # メイン画面・ナビゲーション
├── models/
│   └── walk_route.dart    # ルートデータモデル
└── services/
    └── route_service.dart # ルート永続化・管理ロジック
```

## バージョン履歴

### v1.0.1 (2026-05-09)
- 初版リリース
- Google Maps統合
- GPS ルート記録機能
- ルート履歴管理

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
