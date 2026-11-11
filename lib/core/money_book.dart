import 'package:flutter/foundation.dart';

import 'document_store.dart';

const currencies = ['USD', 'EUR', 'GBP', 'CNY', 'HKD'];
int minor(String text) {
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(text.trim())) {
    throw const FormatException(
      'Enter a positive amount with up to two decimals.',
    );
  }
  final p = text.trim().split('.');
  final n =
      int.parse(p.first) * 100 +
      int.parse(p.length == 1 ? '0' : p[1].padRight(2, '0'));
  if (n <= 0) throw const FormatException('Amount must be greater than zero.');
  return n;
}

String money(int n, [String currency = 'USD']) =>
    '$currency ${(n / 100).toStringAsFixed(2)}';

// Use exact integer intermediates; rates can overflow a native 64-bit product.
int roundedRatio(int amount, int numerator, int denominator) {
  final value =
      (BigInt.from(amount.abs()) * BigInt.from(numerator) +
          BigInt.from(denominator ~/ 2)) ~/
      BigInt.from(denominator);
  if (value > BigInt.from(99999999999999)) {
    throw const FormatException(
      'Converted amount exceeds the supported range.',
    );
  }
  return amount.sign * value.toInt();
}

class Category {
  final String id, name;
  final int color, icon;
  final bool archived;
  const Category(
    this.id,
    this.name,
    this.color,
    this.icon, [
    this.archived = false,
  ]);
  Map<String, dynamic> json() => {
    'id': id,
    'name': name,
    'color': color,
    'icon': icon,
    'archived': archived,
  };
  factory Category.read(Map<String, dynamic> m) => Category(
    m['id'],
    m['name'],
    m['color'],
    m['icon'],
    m['archived'] ?? false,
  );
}

const defaults = [
  Category('food', 'Groceries', 0xff59a3ed, 0),
  Category('transport', 'Transport', 0xfff3bb63, 1),
  Category('leisure', 'Leisure', 0xffe89bbf, 2),
  Category('restaurant', 'Restaurant', 0xff7566c4, 3),
  Category('health', 'Health', 0xff83bc70, 4),
  Category('gifts', 'Gifts', 0xffef6563, 5),
  Category('family', 'Family', 0xffaa5ac1, 6),
  Category('shopping', 'Shopping', 0xffa48f83, 7),
  Category('pets', 'Pets', 0xffeb8b67, 8),
  Category('education', 'Education', 0xff9ab6c5, 9),
  Category('travel', 'Travel', 0xff60baa8, 10),
  Category('other', 'Other', 0xff999999, 11),
];

class Account {
  final String id, name, currency, kind;
  final int opening;
  const Account(
    this.id,
    this.name,
    this.currency,
    this.opening, [
    this.kind = 'cash',
  ]);
  Map<String, dynamic> json() => {
    'id': id,
    'name': name,
    'currency': currency,
    'opening': opening,
    'kind': kind,
  };
  factory Account.read(Map<String, dynamic> m) => Account(
    m['id'],
    m['name'],
    m['currency'],
    m['opening'],
    m['kind'] ?? 'cash',
  );
}

class Entry {
  final String id, accountId, categoryId, date, note, kind;
  final String? toAccountId;
  final int amount, baseAmount, received, rateMicros, destinationRateMicros;
  const Entry({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.date,
    required this.note,
    required this.kind,
    required this.amount,
    required this.baseAmount,
    this.toAccountId,
    this.received = 0,
    this.rateMicros = 1000000,
    this.destinationRateMicros = 1000000,
  });
  Map<String, dynamic> json() => {
    'id': id,
    'accountId': accountId,
    'categoryId': categoryId,
    'date': date,
    'note': note,
    'kind': kind,
    'amount': amount,
    'baseAmount': baseAmount,
    'toAccountId': toAccountId,
    'received': received,
    'rateMicros': rateMicros,
    'destinationRateMicros': destinationRateMicros,
  };
  factory Entry.read(Map<String, dynamic> m) => Entry(
    id: m['id'],
    accountId: m['accountId'],
    categoryId: m['categoryId'],
    date: m['date'],
    note: m['note'],
    kind: m['kind'],
    amount: m['amount'],
    baseAmount: m['baseAmount'],
    toAccountId: m['toAccountId'],
    received: m['received'] ?? 0,
    destinationRateMicros: m['destinationRateMicros'] ?? 1000000,
    rateMicros:
        m['rateMicros'] ??
        ((m['baseAmount'] as int) * 1000000 ~/ (m['amount'] as int)),
  );
}

typedef LedgerRange = ({DateTime start, DateTime end});
LedgerRange ledgerRange(
  String period,
  DateTime date, {
  Iterable<Entry> entries = const [],
}) {
  final day = DateTime(date.year, date.month, date.day);
  if (period == 'Day') {
    return (start: day, end: DateTime(day.year, day.month, day.day + 1));
  }
  if (period == 'Week') {
    final start = DateTime(day.year, day.month, day.day - day.weekday + 1);
    return (
      start: start,
      end: DateTime(start.year, start.month, start.day + 7),
    );
  }
  if (period == 'Year') {
    return (start: DateTime(day.year), end: DateTime(day.year + 1));
  }
  if (period == 'All') {
    if (entries.isEmpty) {
      return (start: day, end: DateTime(day.year, day.month, day.day + 1));
    }
    final dates = entries.map((e) => DateTime.parse(e.date)).toList()..sort();
    final last = dates.last;
    return (
      start: dates.first,
      end: DateTime(last.year, last.month, last.day + 1),
    );
  }
  return (
    start: DateTime(day.year, day.month),
    end: DateTime(day.year, day.month + 1),
  );
}

int calendarDays(LedgerRange range) =>
    DateTime.utc(range.end.year, range.end.month, range.end.day)
        .difference(
          DateTime.utc(range.start.year, range.start.month, range.start.day),
        )
        .inDays;
List<int> expenseBuckets(
  Iterable<Entry> entries,
  LedgerRange range,
  String period,
) {
  final days = calendarDays(range);
  final count = period == 'Year' ? 12 : days.clamp(1, 31);
  final values = List.filled(count, 0);
  for (final e in entries.where((e) => e.kind == 'expense')) {
    final date = DateTime.parse(e.date);
    if (date.isBefore(range.start) || !date.isBefore(range.end)) continue;
    final offset = DateTime.utc(date.year, date.month, date.day)
        .difference(
          DateTime.utc(range.start.year, range.start.month, range.start.day),
        )
        .inDays;
    final index = period == 'Year'
        ? date.month - 1
        : (offset * count ~/ days).clamp(0, count - 1);
    values[index] += e.baseAmount;
  }
  return values;
}

class MoneyBook extends ChangeNotifier {
  final DocumentStore store;
  MoneyBook(this.store);
  bool dark = false;
  String base = 'USD';
  List<Category> categories = List.of(defaults);
  List<Account> accounts = [const Account('cash', 'Cash', 'USD', 0)];
  List<Entry> entries = [];
  Map<String, int> rates = {'USD': 1000000};
  Map<String, int> budgets = {};
  Future<void> _queue = Future.value();
  Map<String, dynamic> snapshot() => {
    'dark': dark,
    'base': base,
    'categories': categories.map((x) => x.json()).toList(),
    'accounts': accounts.map((x) => x.json()).toList(),
    'entries': entries.map((x) => x.json()).toList(),
    'rates': rates,
    'budgets': budgets,
  };
  void _read(Map<String, dynamic> m) {
    dark = m['dark'] ?? false;
    base = m['base'] ?? 'USD';
    categories = (m['categories'] as List)
        .map((x) => Category.read(Map<String, dynamic>.from(x)))
        .toList();
    accounts = (m['accounts'] as List)
        .map((x) => Account.read(Map<String, dynamic>.from(x)))
        .toList();
    entries = (m['entries'] as List)
        .map((x) => Entry.read(Map<String, dynamic>.from(x)))
        .toList();
    rates = Map<String, int>.from(m['rates']);
    budgets = Map<String, int>.from(m['budgets'] ?? {});
    if (accounts.isEmpty || rates[base] != 1000000) {
      throw const FormatException('Stored ledger configuration is invalid.');
    }
  }

  Future<void> load() async {
    final records = await store.all('ledger');
    if (records.isNotEmpty) _read(records.single);
  }

  Future<void> _commit(void Function(MoneyBook draft) edit) {
    final op = _queue.then((_) async {
      final draft = MoneyBook(store).._read(snapshot());
      edit(draft);
      final data = draft.snapshot();
      await store.put('ledger', 'main', data);
      _read(data);
      notifyListeners();
    });
    _queue = op.catchError((Object _) {});
    return op;
  }

  Account account(String id) => accounts.firstWhere((a) => a.id == id);
  Category category(String id) => categories.firstWhere((a) => a.id == id);
  int convert(int amount, String from, String to) {
    final f = rates[from], t = rates[to];
    if (f == null || t == null || f <= 0 || t <= 0) {
      throw const FormatException(
        'Set an exchange rate for both currencies first.',
      );
    }
    return roundedRatio(amount, f, t);
  }

  int balance(String id) =>
      account(id).opening +
      entries.fold<int>(
        0,
        (v, e) =>
            v +
            (e.toAccountId == id ? e.received : 0) +
            (e.accountId == id
                ? (e.kind == 'income' ? e.amount : -e.amount)
                : 0),
      );
  int get totalBalance =>
      accounts.fold(0, (v, a) => v + convert(balance(a.id), a.currency, base));
  List<Entry> inPeriod(DateTime start, DateTime end, {String? accountId}) =>
      entries.where((e) {
        final day = DateTime.parse(e.date);
        return !day.isBefore(start) &&
            day.isBefore(end) &&
            (accountId == null ||
                e.accountId == accountId ||
                e.toAccountId == accountId);
      }).toList()..sort((a, b) => b.date.compareTo(a.date));
  Future<void> setDark(bool v) => _commit((d) => d.dark = v);
  Future<void> setCurrency(String currency) => _commit((d) {
    if (!currencies.contains(currency)) {
      throw const FormatException('Unsupported currency.');
    }
    if (d.entries.isNotEmpty ||
        d.accounts.length != 1 ||
        d.accounts.single.opening != 0) {
      throw const FormatException(
        'Base currency is locked once balances, records or extra accounts exist.',
      );
    }
    d.base = currency;
    d.rates = {currency: 1000000};
    final a = d.accounts.single;
    d.accounts = [Account(a.id, a.name, currency, a.opening, a.kind)];
  });
  Future<void> setRate(String currency, String text) => _commit((d) {
    if (!currencies.contains(currency) || currency == d.base) {
      throw const FormatException('Choose a different currency.');
    }
    final n = double.tryParse(text);
    if (n == null || !n.isFinite || n <= 0 || n > 1000000) {
      throw const FormatException('Enter a valid exchange rate.');
    }
    final value = (n * 1000000).round();
    if (value <= 0) throw const FormatException('Exchange rate is too small.');
    d.rates = {...d.rates, currency: value};
  });
  Future<void> addAccount(
    String name,
    String currency,
    int opening,
    String kind,
  ) => _commit((d) {
    if (name.trim().isEmpty || name.length > 60) {
      throw const FormatException(
        'Enter an account name, up to 60 characters.',
      );
    }
    if (!d.rates.containsKey(currency)) {
      throw const FormatException('Set the currency exchange rate first.');
    }
    d.accounts = [
      ...d.accounts,
      Account(newRecordId(), name.trim(), currency, opening, kind),
    ];
  });
  Future<void> updateAccount(
    String id,
    String name,
    String currency,
    int opening,
    String kind,
  ) => _commit((d) {
    final current = d.account(id);
    if (name.trim().isEmpty || name.length > 60) {
      throw const FormatException(
        'Enter an account name, up to 60 characters.',
      );
    }
    if (!d.rates.containsKey(currency)) {
      throw const FormatException('Set the currency exchange rate first.');
    }
    if (current.currency != currency &&
        d.entries.any((e) => e.accountId == id || e.toAccountId == id)) {
      throw const FormatException(
        'The currency of an account with transactions cannot be changed.',
      );
    }
    d.accounts = [
      for (final a in d.accounts)
        if (a.id == id)
          Account(id, name.trim(), currency, opening, kind)
        else
          a,
    ];
  });
  Future<void> removeAccount(String id) => _commit((d) {
    if (d.account(id).opening != 0) {
      throw const FormatException(
        'Set the opening balance to zero before removing this account.',
      );
    }
    if (d.accounts.length == 1 ||
        d.entries.any((e) => e.accountId == id || e.toAccountId == id)) {
      throw const FormatException(
        'Keep the last account and accounts used by records.',
      );
    }
    d.accounts = d.accounts.where((a) => a.id != id).toList();
  });
  Future<void> saveEntry({
    String? id,
    required String accountId,
    required String categoryId,
    required int amount,
    required String kind,
    required DateTime date,
    String note = '',
    String? toAccountId,
  }) => _commit((d) {
    if (amount <= 0 || amount > 99999999999) {
      throw const FormatException('Enter a valid positive amount.');
    }
    if (!['expense', 'income', 'transfer'].contains(kind)) {
      throw const FormatException('Invalid entry type.');
    }
    if (note.length > 500) {
      throw const FormatException('Notes can contain up to 500 characters.');
    }
    if (date.year < 2000 || date.year > 2100) {
      throw const FormatException('Choose a date between 2000 and 2100.');
    }
    if (id != null && !d.entries.any((e) => e.id == id)) {
      throw const FormatException('This record no longer exists.');
    }
    final a = d.account(accountId);
    final old = id == null ? null : d.entries.firstWhere((e) => e.id == id);
    final rate = old != null && old.accountId == accountId
        ? old.rateMicros
        : d.rates[a.currency]!;
    int received = 0;
    int destinationRate = 1000000;
    if (kind == 'transfer') {
      if (toAccountId == null || accountId == toAccountId) {
        throw const FormatException('Choose two different accounts.');
      }
      final destination = d.account(toAccountId);
      destinationRate =
          old != null &&
              old.kind == 'transfer' &&
              old.toAccountId == toAccountId &&
              old.accountId == accountId
          ? old.destinationRateMicros
          : d.rates[destination.currency]!;
      received = roundedRatio(amount, rate, destinationRate);
      if (received <= 0) {
        throw const FormatException('Transfer amount is too small.');
      }
    } else if (d.category(categoryId).archived && id == null) {
      throw const FormatException('Choose an active category.');
    }
    final e = Entry(
      id: id ?? newRecordId(),
      accountId: accountId,
      categoryId: kind == 'transfer' ? 'other' : categoryId,
      date: calendarDate(date),
      note: note.trim(),
      kind: kind,
      amount: amount,
      baseAmount: roundedRatio(amount, rate, 1000000),
      rateMicros: rate,
      destinationRateMicros: destinationRate,
      toAccountId: kind == 'transfer' ? toAccountId : null,
      received: received,
    );
    d.entries = [...d.entries.where((x) => x.id != e.id), e];
  });
  Future<void> removeEntry(String id) =>
      _commit((d) => d.entries = d.entries.where((e) => e.id != id).toList());
  Future<void> setBudget(String id, int amount) => _commit((d) {
    if (amount < 0) throw const FormatException('Budget cannot be negative.');
    if (id != 'all') d.category(id);
    d.budgets = {...d.budgets, id: amount};
  });
  Future<void> renameCategory(String id, String name) => _commit((d) {
    if (name.trim().isEmpty || name.length > 40) {
      throw const FormatException(
        'Enter a category name, up to 40 characters.',
      );
    }
    d.categories = [
      for (final c in d.categories)
        if (c.id == id)
          Category(c.id, name.trim(), c.color, c.icon, c.archived)
        else
          c,
    ];
  });
  Future<void> addCategory(String name) => _commit((d) {
    if (name.trim().isEmpty || name.length > 40) {
      throw const FormatException(
        'Enter a category name, up to 40 characters.',
      );
    }
    d.categories = [
      ...d.categories,
      Category(newRecordId(), name.trim(), 0xff8888bb, 11),
    ];
  });
  Future<void> archiveCategory(String id) => _commit((d) {
    final current = d.category(id);
    if (!current.archived &&
        d.categories.where((c) => !c.archived).length == 1) {
      throw const FormatException('Keep at least one active category.');
    }
    d.categories = [
      for (final c in d.categories)
        if (c.id == id)
          Category(c.id, c.name, c.color, c.icon, !c.archived)
        else
          c,
    ];
  });
  Future<void> clearEntries() => _commit((d) => d.entries = []);
  String exportCsv() {
    String q(String s) {
      if (RegExp(r'^[=+@\-]').hasMatch(s)) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    return 'Date,Type,Account,Currency,Amount,Category,Note\r\n${entries.map((e) => [e.date, e.kind, account(e.accountId).name, account(e.accountId).currency, (e.amount / 100).toStringAsFixed(2), e.kind == 'transfer' ? 'Transfer' : category(e.categoryId).name, e.note].map(q).join(',')).join('\r\n')}';
  }
}
