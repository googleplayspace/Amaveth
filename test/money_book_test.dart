import 'package:flutter_test/flutter_test.dart';
import 'package:Amaveth/core/document_store.dart';
import 'package:Amaveth/core/money_book.dart';

class FailingStore extends MemoryDocumentStore {
  bool fail = false;
  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) {
    if (fail) throw StateError('simulated disk failure');
    return super.put(kind, id, value);
  }
}

void main() {
  final day = DateTime(2026, 11, 11);
  Future<void> add(
    MoneyBook b, {
    String? id,
    String account = 'cash',
    int amount = 1234,
    String note = '',
    String kind = 'expense',
    String? to,
  }) => b.saveEntry(
    id: id,
    accountId: account,
    categoryId: 'food',
    amount: amount,
    kind: kind,
    date: day,
    note: note,
    toAccountId: to,
  );
  test('exact minor units, validation and CSV escaping', () async {
    expect(minor('0.01'), 1);
    expect(minor('999999999.99'), 99999999999);
    expect(() => minor('1.999'), throwsFormatException);
    final b = MoneyBook(MemoryDocumentStore());
    await add(b, note: '=SUM(1,2) "quoted"');
    expect(b.balance('cash'), -1234);
    expect(b.exportCsv(), contains("'=SUM(1,2)"));
    expect(b.exportCsv(), contains('""quoted""'));
  });
  test('failed persistence is atomic and next operation recovers', () async {
    final store = FailingStore();
    final b = MoneyBook(store);
    store.fail = true;
    await expectLater(add(b), throwsStateError);
    expect(b.entries, isEmpty);
    store.fail = false;
    await Future.wait([add(b, amount: 100), add(b, amount: 200)]);
    expect(b.entries.length, 2);
    final loaded = MoneyBook(store);
    await loaded.load();
    expect(loaded.balance('cash'), -300);
  });
  test('saved historical rate survives rate change and note edit', () async {
    final b = MoneyBook(MemoryDocumentStore());
    await b.setRate('EUR', '1.2');
    await b.addAccount('Euro cash', 'EUR', 0, 'cash');
    final a = b.accounts.last.id;
    await add(b, account: a, amount: 1000);
    final id = b.entries.single.id;
    expect(b.entries.single.baseAmount, 1200);
    await b.setRate('EUR', '1.5');
    await add(b, id: id, account: a, amount: 1000, note: 'Updated note');
    expect(b.entries.single.baseAmount, 1200);
    await add(b, id: id, account: a, amount: 2000);
    expect(b.entries.single.baseAmount, 2400);
  });
  test(
    'transfer changes accounts but is excluded from income and expense',
    () async {
      final b = MoneyBook(MemoryDocumentStore());
      await b.addAccount('Bank', 'USD', 10000, 'bank');
      final bank = b.accounts.last.id;
      await add(b, account: bank, amount: 2500, kind: 'transfer', to: 'cash');
      expect(b.balance(bank), 7500);
      expect(b.balance('cash'), 2500);
      expect(b.totalBalance, 10000);
      expect(
        b.entries.where((e) => e.kind == 'expense' || e.kind == 'income'),
        isEmpty,
      );
      await expectLater(
        add(b, account: bank, kind: 'transfer', to: bank),
        throwsFormatException,
      );
      await expectLater(b.removeAccount(bank), throwsFormatException);
    },
  );
  test(
    'cross-currency transfer keeps both rates after persistence and edit',
    () async {
      final store = MemoryDocumentStore();
      final b = MoneyBook(store);
      await b.setRate('EUR', '1.2');
      await b.addAccount('Euro', 'EUR', 0, 'cash');
      final dest = b.accounts.last.id;
      await add(b, kind: 'transfer', amount: 1200, to: dest);
      expect(b.entries.single.received, 1000);
      await b.setRate('EUR', '1.5');
      final loaded = MoneyBook(store);
      await loaded.load();
      await add(
        loaded,
        id: loaded.entries.single.id,
        kind: 'transfer',
        amount: 1200,
        to: dest,
        note: 'Changed',
      );
      expect(loaded.entries.single.received, 1000);
    },
  );
  test(
    'negative balances round symmetrically and large products stay exact',
    () async {
      final b = MoneyBook(MemoryDocumentStore());
      await add(b, amount: 2550);
      expect(b.totalBalance, -2550);
      await b.setRate('EUR', '1.2');
      expect(b.convert(-1, 'EUR', 'USD'), -1);
      expect(b.convert(1, 'EUR', 'USD'), 1);
      await b.setRate('EUR', '1000000');
      expect(b.convert(90000000, 'EUR', 'USD'), 90000000000000);
      expect(b.convert(-90000000, 'EUR', 'USD'), -90000000000000);
      expect(() => b.convert(99999999999, 'EUR', 'USD'), throwsFormatException);
    },
  );
  test(
    'account edits preserve records and guard currency and opening balance',
    () async {
      final b = MoneyBook(MemoryDocumentStore());
      await b.addAccount('Bank', 'USD', 10000, 'bank');
      final id = b.accounts.last.id;
      await expectLater(b.removeAccount(id), throwsFormatException);
      await add(b, account: id, amount: 2500);
      await b.updateAccount(id, 'Savings', 'USD', 20000, 'savings');
      expect(b.balance(id), 17500);
      await b.setRate('EUR', '1.2');
      await expectLater(
        b.updateAccount(id, 'Savings', 'EUR', 20000, 'savings'),
        throwsFormatException,
      );
      expect(b.account(id).currency, 'USD');
    },
  );
  test(
    'midmonth anchors include the entire month; daily and yearly buckets agree',
    () async {
      final b = MoneyBook(MemoryDocumentStore());
      await add(b, amount: 3000);
      final month = ledgerRange('Month', DateTime(2026, 11, 25));
      expect(month.start, DateTime(2026, 11));
      expect(calendarDays(month), 30);
      expect(b.inPeriod(month.start, month.end).length, 1);
      expect(expenseBuckets(b.entries, month, 'Month')[10], 3000);
      final year = ledgerRange('Year', DateTime(2026, 11, 25));
      expect(expenseBuckets(b.entries, year, 'Year')[10], 3000);
      expect(calendarDays(ledgerRange('Year', DateTime(2024))), 366);
      final week = ledgerRange('Week', DateTime(2026, 11, 1));
      expect(week.start, DateTime(2026, 10, 26));
      expect(calendarDays(week), 7);
      final all = ledgerRange('All', DateTime(2026, 11), entries: b.entries);
      expect(calendarDays(all), 1);
      expect(expenseBuckets(b.entries, all, 'All'), [3000]);
      final empty = MoneyBook(MemoryDocumentStore());
      await empty.updateAccount('cash', 'Cash', 'USD', 100, 'cash');
      await expectLater(empty.setCurrency('EUR'), throwsFormatException);
    },
  );
  test('period boundaries, budget and last active category guard', () async {
    final b = MoneyBook(MemoryDocumentStore());
    await add(b);
    expect(b.inPeriod(DateTime(2026, 11), DateTime(2026, 12)).length, 1);
    expect(b.inPeriod(DateTime(2026, 12), DateTime(2027)).length, 0);
    await b.setBudget('food', 5000);
    expect(b.budgets['food'], 5000);
    for (final c in b.categories.take(b.categories.length - 1).toList()) {
      await b.archiveCategory(c.id);
    }
    await expectLater(
      b.archiveCategory(b.categories.last.id),
      throwsFormatException,
    );
    await expectLater(b.setCurrency('EUR'), throwsFormatException);
  });
}
