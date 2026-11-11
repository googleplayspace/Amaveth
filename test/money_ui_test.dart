import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yueh/app.dart';
import 'package:yueh/core/document_store.dart';
import 'package:yueh/core/money_book.dart';
import 'package:yueh/src/workspace.dart';

void main() {
  testWidgets(
    'create, edit and delete refresh dashboard; root route stays dark',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final b = MoneyBook(MemoryDocumentStore());
      await b.setDark(true);
      await tester.pumpWidget(AmavethApp(book: b));
      await tester.pumpAndSettle();
      final homeContext = tester.element(find.byType(ToolWorkspace));
      expect(Theme.of(homeContext).brightness, Brightness.dark);
      Navigator.of(homeContext)
          .push(MaterialPageRoute<void>(builder: (_) => const EntryEditor()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        Theme.of(tester.element(find.byType(EntryEditor))).brightness,
        Brightness.dark,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('entry-amount')),
        '12.34',
      );
      await tester.scrollUntilVisible(
        find.text('Save transaction'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(EntryEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();
      expect(b.entries.length, 1);
      expect(find.textContaining('12.34'), findsWidgets);
      final entry1 = b.entries.single;
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(builder: (_) => EntryEditor(entry: entry1)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('entry-amount')), '20');
      await tester.scrollUntilVisible(
        find.text('Save transaction'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(EntryEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();
      expect(b.entries.single.amount, 2000);
      expect(find.textContaining('20.00'), findsWidgets);
      final entry2 = b.entries.single;
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(builder: (_) => EntryEditor(entry: entry2)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(b.entries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
