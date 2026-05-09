import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanpo/main.dart';

void main() {
  testWidgets('Sanpo app title smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(MyApp(prefs: prefs));

    // アプリのタイトルが表示されることを確認
    expect(find.text('Sanpo - 散歩ルート記録'), findsOneWidget);
    
    // ナビゲーションバーのタブが表示されることを確認
    expect(find.text('マップ'), findsOneWidget);
    expect(find.text('記録'), findsOneWidget);
    expect(find.text('設定'), findsOneWidget);
  });
}
