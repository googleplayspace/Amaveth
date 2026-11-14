import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/money_book.dart';
import '../core/platform_services.dart';
import '../core/legal_links.dart';
import 'amount_calculator.dart';

const modern = false;
const brand = 'Amaveth';
const accent = Color(0xff45a978);
const icons = [
  Icons.shopping_basket_outlined,
  Icons.directions_bus_outlined,
  Icons.local_activity_outlined,
  Icons.restaurant_outlined,
  Icons.favorite_border,
  Icons.card_giftcard,
  Icons.people_outline,
  Icons.shopping_bag_outlined,
  Icons.pets,
  Icons.school_outlined,
  Icons.flight,
  Icons.more_horiz,
];

class BookScope extends InheritedNotifier<MoneyBook> {
  const BookScope({super.key, required MoneyBook book, required super.child})
    : super(notifier: book);
  static MoneyBook of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<BookScope>()!.notifier!;
}

void notice(BuildContext c, Object error) {
  if (c.mounted) {
    ScaffoldMessenger.of(c).showSnackBar(
      SnackBar(
        content: Text(
          error is FormatException
              ? error.message
              : 'The operation could not be completed. Please try again.',
        ),
      ),
    );
  }
}

Future<String?> input(
  BuildContext c,
  String title, {
  String initial = '',
  bool amount = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: amount
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        maxLength: amount ? 20 : 60,
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // The closing dialog still owns its input until its route animation completes.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}

Future<bool> confirm(BuildContext c, String title, String message) async =>
    await showDialog<bool>(
      context: c,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

class ToolWorkspace extends StatefulWidget {
  final VoidCallback? onOpenIm;
  final ValueChanged<bool>? onThemeChanged;
  const ToolWorkspace({super.key, this.onOpenIm, this.onThemeChanged});
  @override
  State<ToolWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<ToolWorkspace> {
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  String period = 'Month', query = '';
  String? selectedAccount;
  bool exportBusy = false;
  MoneyBook get book => BookScope.of(context);
  LedgerRange get range => ledgerRange(
    period,
    month,
    entries: book.entries.where(
      (e) =>
          selectedAccount == null ||
          e.accountId == selectedAccount ||
          e.toAccountId == selectedAccount,
    ),
  );
  List<Entry> get rows =>
      book.inPeriod(range.start, range.end, accountId: selectedAccount);

  int total(String kind, Iterable<Entry> values) =>
      values.where((e) => e.kind == kind).fold(0, (v, e) => v + e.baseAmount);
  List<Entry> get monthly => book.inPeriod(
    DateTime(month.year, month.month),
    DateTime(month.year, month.month + 1),
    accountId: selectedAccount,
  );
  Map<String, int> grouped(Iterable<Entry> values) => {
    for (final c in book.categories)
      c.id: values
          .where((e) => e.kind == 'expense' && e.categoryId == c.id)
          .fold(0, (v, e) => v + e.baseAmount),
  };
  Future<void> edit({
    Entry? entry,
    String kind = 'expense',
    Category? category,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => EntryEditor(
          entry: entry,
          initialKind: kind,
          initialCategory: category?.id,
          accountId: selectedAccount,
        ),
      ),
    );
  }

  Widget dateBar() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: 'Previous period',
        onPressed: () {
          setState(() {
            if (period == 'Day' || period == 'Week') {
              month = month.subtract(Duration(days: period == 'Day' ? 1 : 7));
            } else {
              month = DateTime(
                month.year - (period == 'Year' ? 1 : 0),
                month.month - (period == 'Month' ? 1 : 0),
              );
            }
            if (month.isBefore(DateTime(2000))) month = DateTime(2000);
            if (month.isAfter(DateTime(2100, 12, 31))) {
              month = DateTime(2100, 12, 31);
            }
          });
        },
        icon: const Icon(Icons.chevron_left),
      ),
      TextButton.icon(
        onPressed: () async {
          final day = await showDatePicker(
            context: context,
            initialDate: month,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100, 12, 31),
          );
          if (day != null && mounted) setState(() => month = day);
        },
        icon: const Icon(Icons.calendar_month, size: 18),
        label: Text(
          '${month.year}-${month.month.toString().padLeft(2, '0')}${period == 'Day' || period == 'Week' ? '-${month.day.toString().padLeft(2, '0')}' : ''}',
        ),
      ),
      IconButton(
        tooltip: 'Next period',
        onPressed: () {
          setState(() {
            if (period == 'Day' || period == 'Week') {
              month = month.add(Duration(days: period == 'Day' ? 1 : 7));
            } else {
              month = DateTime(
                month.year + (period == 'Year' ? 1 : 0),
                month.month + (period == 'Month' ? 1 : 0),
              );
            }
            if (month.isBefore(DateTime(2000))) month = DateTime(2000);
            if (month.isAfter(DateTime(2100, 12, 31))) {
              month = DateTime(2100, 12, 31);
            }
          });
        },
        icon: const Icon(Icons.chevron_right),
      ),
      PopupMenuButton<String>(
        tooltip: 'Period',
        initialValue: period,
        onSelected: (v) => setState(() => period = v),
        itemBuilder: (_) => [
          for (final v in ['Day', 'Week', 'Month', 'Year', 'All'])
            PopupMenuItem(value: v, child: Text(v)),
        ],
        child: Padding(padding: const EdgeInsets.all(10), child: Text(period)),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final b = book;
    final title = modern
        ? [
            'Categories',
            'Activity',
            'Budgets',
            'Accounts',
            'Settings',
            'Statistics',
          ][tab]
        : ['Overview', 'Entries', 'Statistics', 'Settings'][tab];
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(
              brand,
              style: TextStyle(
                fontFamily: modern ? null : 'serif',
                fontStyle: modern ? FontStyle.normal : FontStyle.italic,
                fontWeight: FontWeight.w700,
              ),
            ),
            GestureDetector(
              onTap: () => accountPicker(),
              child: Text(
                selectedAccount == null
                    ? 'All accounts'
                    : b.account(selectedAccount!).name,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (modern)
            IconButton(
              tooltip: 'Statistics',
              icon: const Icon(Icons.bar_chart),
              onPressed: () => setState(() => tab = 5),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => setState(() => tab = modern ? 4 : 3),
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: Text(brand, style: const TextStyle(fontSize: 28)),
              ),
              for (final (i, label)
                  in (modern
                          ? [
                              'Categories',
                              'Activity',
                              'Budgets',
                              'Accounts',
                              'Settings',
                            ]
                          : ['Overview', 'Entries', 'Statistics', 'Settings'])
                      .indexed)
                ListTile(
                  title: Text(label),
                  selected: tab == i,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => tab = i);
                  },
                ),
            ],
          ),
        ),
      ),
      body: KeyedSubtree(
        key: ValueKey(title),
        child: modern
            ? switch (tab) {
                0 => overview(),
                1 => activity(),
                2 => budgets(),
                3 => accounts(),
                5 => statistics(),
                _ => settings(),
              }
            : switch (tab) {
                0 => overview(),
                1 => activity(),
                2 => statistics(),
                _ => settings(),
              },
      ),
      bottomNavigationBar: modern
          ? NavigationBar(
              selectedIndex: tab > 3 ? 0 : tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.donut_large),
                  label: 'Categories',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.speed),
                  label: 'Budgets',
                ),
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  label: 'Accounts',
                ),
              ],
            )
          : null,
      floatingActionButton: tab == 1 || (!modern && tab == 2)
          ? FloatingActionButton(
              tooltip: 'Add entry',
              onPressed: () => edit(),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Future<void> accountPicker() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('All accounts'),
              onTap: () => Navigator.pop(c, 'all'),
            ),
            for (final a in book.accounts)
              ListTile(
                title: Text(a.name),
                subtitle: Text(a.currency),
                onTap: () => Navigator.pop(c, a.id),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      setState(() => selectedAccount = value == 'all' ? null : value);
    }
  }

  Widget overview() {
    final g = grouped(rows),
        inc = total('income', rows),
        exp = total('expense', rows);
    final cats = book.categories.where((c) => !c.archived).take(12).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (modern)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              children: [
                const Text('Account balance'),
                Text(
                  money(
                    selectedAccount == null
                        ? book.totalBalance
                        : book.convert(
                            book.balance(selectedAccount!),
                            book.account(selectedAccount!).currency,
                            book.base,
                          ),
                    book.base,
                  ),
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        dateBar(),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final height = w * 1.12;
            const positions = [
              (.12, .08),
              (.37, .08),
              (.63, .08),
              (.88, .08),
              (.1, .4),
              (.9, .4),
              (.1, .69),
              (.9, .69),
              (.12, .94),
              (.37, .94),
              (.63, .94),
              (.88, .94),
            ];
            return SizedBox(
              height: height + 48,
              child: Stack(
                children: [
                  Positioned(
                    left: w * .23,
                    top: height * .23,
                    width: w * .54,
                    height: w * .54,
                    child: CustomPaint(
                      painter: RingPainter(book.categories, g),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Expenses'),
                            Text(
                              money(exp, book.base),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.redAccent,
                                fontSize: 18,
                              ),
                            ),
                            Text(
                              money(inc, book.base),
                              style: const TextStyle(
                                color: Colors.teal,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final (i, c) in cats.indexed)
                    Positioned(
                      left: w * positions[i].$1 - 36,
                      top: height * positions[i].$2 - 14,
                      width: 72,
                      child: InkWell(
                        key: ValueKey('category-${c.id}'),
                        onTap: () => edit(category: c),
                        child: Column(
                          children: [
                            if (modern)
                              CircleAvatar(
                                backgroundColor: Color(c.color),
                                child: Icon(icons[c.icon], color: Colors.white),
                              )
                            else
                              Icon(
                                icons[c.icon],
                                color: Color(c.color),
                                size: 30,
                              ),
                            Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                            Text(
                              g[c.id] == 0 ? '' : money(g[c.id]!, book.base),
                              style: TextStyle(
                                fontSize: 9,
                                color: Color(c.color),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
          child: FilledButton.tonal(
            onPressed: () => setState(() => tab = 1),
            child: Text('Balance ${money(inc - exp, book.base)}'),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [actionCircle(false), actionCircle(true)],
        ),
        if (modern)
          TextButton(
            onPressed: () => setState(() => tab = 2),
            child: const Text('Plan your monthly budget'),
          ),
      ],
    );
  }

  Widget actionCircle(bool income) => Column(
    children: [
      SizedBox(
        width: 84,
        height: 84,
        child: OutlinedButton(
          key: ValueKey(income ? 'add-income' : 'add-expense'),
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            side: BorderSide(
              color: income ? Colors.teal : Colors.redAccent,
              width: 4,
            ),
            padding: EdgeInsets.zero,
          ),
          onPressed: () => edit(kind: income ? 'income' : 'expense'),
          child: Icon(
            income ? Icons.add : Icons.remove,
            size: 42,
            color: income ? Colors.teal : Colors.redAccent,
          ),
        ),
      ),
      const SizedBox(height: 5),
      Text(income ? 'Income' : 'Expense'),
    ],
  );
  Widget activity() {
    final filtered = rows
        .where(
          (e) =>
              query.isEmpty ||
              e.note.toLowerCase().contains(query.toLowerCase()) ||
              book
                  .category(e.categoryId)
                  .name
                  .toLowerCase()
                  .contains(query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        dateBar(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search category or note',
            ),
            onChanged: (v) => setState(() => query = v),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No transactions in this period.'))
              : ListView(
                  children: [
                    for (final (i, e) in filtered.indexed) ...[
                      if (i == 0 || filtered[i - 1].date != e.date)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                          child: Text(
                            e.date,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Color(
                            book.category(e.categoryId).color,
                          ).withValues(alpha: .15),
                          child: Icon(
                            e.kind == 'transfer'
                                ? Icons.swap_horiz
                                : icons[book.category(e.categoryId).icon],
                          ),
                        ),
                        title: Text(
                          e.kind == 'transfer'
                              ? 'Transfer'
                              : book.category(e.categoryId).name,
                        ),
                        subtitle: Text(
                          '${book.account(e.accountId).name}${e.note.isEmpty ? '' : ' · ${e.note}'}',
                        ),
                        trailing: Text(
                          '${e.kind == 'income' ? '+' : '−'}${money(e.amount, book.account(e.accountId).currency)}',
                          style: TextStyle(
                            color: e.kind == 'income'
                                ? Colors.teal
                                : Colors.redAccent,
                          ),
                        ),
                        onTap: () => edit(entry: e),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget statistics() {
    final g = grouped(rows), sum = total('expense', rows);
    final sorted = g.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        dateBar(),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                const Text('Expenses'),
                Text(
                  money(sum, book.base),
                  style: const TextStyle(fontSize: 22, color: Colors.redAccent),
                ),
              ],
            ),
            Column(
              children: [
                const Text('Income'),
                Text(
                  money(total('income', rows), book.base),
                  style: const TextStyle(fontSize: 22, color: Colors.teal),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 140,
          child: CustomPaint(
            painter: BarsPainter(expenseBuckets(rows, range, period)),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Daily average: ${money((sum + calendarDays(range) ~/ 2) ~/ calendarDays(range), book.base)}',
        ),
        if (sorted.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Text('Add an expense to see its distribution.'),
          ),
        for (final r in sorted)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Color(book.category(r.key).color),
              child: Icon(
                icons[book.category(r.key).icon],
                color: Colors.white,
              ),
            ),
            title: Text(book.category(r.key).name),
            subtitle: LinearProgressIndicator(
              value: sum == 0 ? 0 : r.value / sum,
              color: Color(book.category(r.key).color),
            ),
            trailing: Text(
              '${money(r.value, book.base)}\n${(r.value * 100 / sum).toStringAsFixed(1)}%',
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CategoryRecords(
                  categoryId: r.key,
                  rows: () => rows
                      .where(
                        (e) => e.categoryId == r.key && e.kind == 'expense',
                      )
                      .toList(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget budgets() {
    final g = grouped(monthly), sum = total('expense', monthly);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        dateBar(),
        const Text(
          'Monthly budgets',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const Text('Limits repeat each month and use the base currency.'),
        budgetRow('all', 'Total expenses', sum),
        for (final c in book.categories.where((c) => !c.archived))
          budgetRow(c.id, c.name, g[c.id] ?? 0),
      ],
    );
  }

  Widget budgetRow(String id, String label, int spent) {
    final limit = book.budgets[id] ?? 0;
    return Card(
      child: ListTile(
        title: Text(label),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${money(spent, book.base)} spent · ${limit == 0 ? 'No limit' : money(limit, book.base)}',
            ),
            if (limit > 0)
              LinearProgressIndicator(
                value: (spent / limit).clamp(0, 1),
                color: spent > limit ? Colors.redAccent : accent,
              ),
            if (limit > 0) Text('${money(limit - spent, book.base)} remaining'),
          ],
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () async {
          final v = await input(
            context,
            'Monthly limit',
            initial: (limit / 100).toStringAsFixed(2),
            amount: true,
          );
          if (v == null || !mounted) return;
          try {
            await book.setBudget(
              id,
              v.trim() == '0' || v.trim() == '0.00' ? 0 : minor(v),
            );
          } catch (e) {
            if (mounted) notice(context, e);
          }
        },
      ),
    );
  }

  Widget accounts() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Accounts',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
      ),
      Text(
        'Total ${money(book.totalBalance, book.base)}',
        style: const TextStyle(fontSize: 24),
      ),
      for (final a in book.accounts)
        Card(
          child: ListTile(
            leading: Icon(
              a.kind == 'debt'
                  ? Icons.credit_card
                  : a.kind == 'savings'
                  ? Icons.savings_outlined
                  : Icons.account_balance_wallet_outlined,
            ),
            title: Text(a.name),
            subtitle: Text('${a.kind} · ${a.currency}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(money(book.balance(a.id), a.currency)),
                IconButton(
                  tooltip: 'Edit account',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AccountEditor(account: a),
                    ),
                  ),
                ),
              ],
            ),
            onTap: () {
              setState(() {
                selectedAccount = a.id;
                tab = 1;
              });
            },
            onLongPress: () async {
              if (await confirm(
                    context,
                    'Remove account?',
                    'Only empty, unused accounts can be removed.',
                  ) &&
                  mounted) {
                try {
                  await book.removeAccount(a.id);
                  if (selectedAccount == a.id) {
                    setState(() => selectedAccount = null);
                  }
                } catch (e) {
                  if (mounted) notice(context, e);
                }
              }
            },
          ),
        ),
      FilledButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AccountEditor()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
      OutlinedButton.icon(
        onPressed: () => edit(kind: 'transfer'),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Transfer between accounts'),
      ),
      TextButton(onPressed: rateDialog, child: const Text('Exchange rates')),
    ],
  );
  Future<void> rateDialog() async {
    String currency = currencies.firstWhere((c) => c != book.base);
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Manual exchange rate'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Rates are entered manually, not fetched online. Existing transaction totals keep their saved rate.',
              ),
              DropdownButton<String>(
                value: currency,
                isExpanded: true,
                items: [
                  for (final c in currencies.where((c) => c != book.base))
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => update(() => currency = v!),
              ),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '1 $currency equals (${book.base})',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await book.setRate(currency, controller.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) notice(ctx, e);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Widget settings() => ListView(
    children: [
      SwitchListTile(
        title: const Text('Dark mode'),
        value: book.dark,
        onChanged: (v) async {
          try {
            await book.setDark(v);
          } catch (e) {
            if (mounted) notice(context, e);
          }
        },
      ),
      ListTile(
        title: const Text('Base currency'),
        subtitle: Text(book.base),
        onTap: () async {
          final c = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Base currency'),
              children: [
                for (final c in currencies)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, c),
                    child: Text(c),
                  ),
              ],
            ),
          );
          if (c != null) {
            try {
              await book.setCurrency(c);
            } catch (e) {
              if (mounted) notice(context, e);
            }
          }
        },
      ),
      ListTile(
        title: const Text('Categories'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CategoryManager()),
        ),
      ),
      if (!modern)
        ListTile(
          title: const Text('Accounts'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Accounts')),
                body: accounts(),
              ),
            ),
          ),
        ),
      ListTile(
        title: const Text('Export transactions (CSV)'),
        enabled: !exportBusy,
        onTap: exportBusy ? null : export,
      ),
      ListTile(
        title: const Text('Privacy Policy'),
        onTap: () => policy(LegalLinks.privacyPolicy),
      ),
      ListTile(
        title: const Text('Terms of Use'),
        onTap: () => policy(LegalLinks.termsOfUse),
      ),
      const ListTile(
        title: Text('Support'),
        subtitle: SelectableText('raincofarri@gmail.com'),
      ),
      const ListTile(
        title: Text('Operator'),
        subtitle: Text('AFRICAN PROVERBS PAGE LLC'),
      ),
      const ListTile(title: Text('About'), subtitle: Text('$brand · 1.0.1')),
      ListTile(
        title: const Text('Delete all transactions'),
        textColor: Colors.redAccent,
        onTap: () async {
          if (await confirm(
                context,
                'Delete all transactions?',
                'This removes your transactions. Categories, accounts and settings are kept.',
              ) &&
              mounted) {
            try {
              await book.clearEntries();
            } catch (e) {
              if (mounted) notice(context, e);
            }
          }
        },
      ),
    ],
  );
  Future<void> policy(Uri url) async {
    try {
      final ok = await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      if (!ok && mounted) {
        notice(
          context,
          const FormatException('Could not open the policy link.'),
        );
      }
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  Future<void> export() async {
    setState(() => exportBusy = true);
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      file = File(
        '${dir.path}/$brand-${DateTime.now().microsecondsSinceEpoch}.csv',
      );
      await file.writeAsString(book.exportCsv());
      await AppPlatform.exportTemporaryFile(
        file,
        name: '$brand-transactions.csv',
        mime: 'text/csv',
        onNotice: (s) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(s)));
          }
        },
      );
    } catch (e) {
      if (mounted) notice(context, e);
    } finally {
      if (file != null && await file.exists()) await file.delete();
      if (mounted) setState(() => exportBusy = false);
    }
  }
}

class RingPainter extends CustomPainter {
  final List<Category> categories;
  final Map<String, int> values;
  RingPainter(this.categories, this.values);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2),
        radius = math.min(size.width, size.height) / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22;
    final total = values.values.fold(0, (a, b) => a + b);
    if (total == 0) {
      canvas.drawCircle(
        center,
        radius,
        paint..color = Colors.grey.withValues(alpha: .2),
      );
      return;
    }
    double angle = -math.pi / 2;
    for (final c in categories) {
      final value = values[c.id] ?? 0;
      if (value <= 0) continue;
      final sweep = value / total * math.pi * 2;
      canvas.drawArc(
        rect,
        angle,
        sweep - .015,
        false,
        paint..color = Color(c.color),
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant RingPainter old) => true;
}

class BarsPainter extends CustomPainter {
  final List<int> sums;
  BarsPainter(this.sums);
  @override
  void paint(Canvas canvas, Size size) {
    final max = sums.fold<int>(1, math.max);
    final width = size.width / sums.length;
    for (int i = 0; i < sums.length; i++) {
      final h = sums[i] / max * (size.height - 16);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * width + 1, size.height - h, width - 2, h),
          const Radius.circular(3),
        ),
        Paint()..color = Color(defaults[i % defaults.length].color),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BarsPainter old) => true;
}

class EntryEditor extends StatefulWidget {
  final Entry? entry;
  final String initialKind;
  final String? initialCategory, accountId;
  const EntryEditor({
    super.key,
    this.entry,
    this.initialKind = 'expense',
    this.initialCategory,
    this.accountId,
  });
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  final amount = TextEditingController(), note = TextEditingController();
  late String kind;
  String? categoryId, accountId, toAccountId;
  late DateTime day;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    kind = e?.kind ?? widget.initialKind;
    categoryId = e?.categoryId ?? widget.initialCategory;
    accountId = e?.accountId ?? widget.accountId;
    toAccountId = e?.toAccountId;
    day = e == null ? DateTime.now() : DateTime.parse(e.date);
    if (e != null) {
      amount.text = (e.amount / 100).toStringAsFixed(2);
      note.text = e.note;
    }
  }

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = BookScope.of(context);
    categoryId ??= b.categories.firstWhere((c) => !c.archived).id;
    accountId ??= b.accounts.first.id;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry == null ? 'Add transaction' : 'Edit transaction',
        ),
        actions: [
          if (widget.entry != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: saving
                  ? null
                  : () async {
                      if (await confirm(
                            context,
                            'Delete transaction?',
                            'This record will be removed.',
                          ) &&
                          mounted) {
                        setState(() => saving = true);
                        try {
                          await b.removeEntry(widget.entry!.id);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (mounted && context.mounted) {
                            setState(() => saving = false);
                            notice(context, e);
                          }
                        }
                      }
                    },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'expense', label: Text('Expense')),
              const ButtonSegment(value: 'income', label: Text('Income')),
              if (modern || kind == 'transfer')
                const ButtonSegment(value: 'transfer', label: Text('Transfer')),
            ],
            selected: {kind},
            onSelectionChanged: saving
                ? null
                : (v) => setState(() => kind = v.first),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('entry-amount'),
            controller: amount,
            enabled: !saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 30),
            decoration: InputDecoration(
              labelText: 'Amount (${b.account(accountId!).currency})',
              suffixIcon: IconButton(
                tooltip: 'Calculator',
                onPressed: saving
                    ? null
                    : () async {
                        final result = await showDialog<int>(
                          context: context,
                          builder: (_) =>
                              AmountCalculator(initial: amount.text),
                        );
                        if (result != null) {
                          amount.text = (result / 100).toStringAsFixed(2);
                        }
                      },
                icon: const Icon(Icons.calculate_outlined),
              ),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: accountId,
            decoration: const InputDecoration(labelText: 'Account'),
            items: [
              for (final a in b.accounts)
                DropdownMenuItem(
                  value: a.id,
                  child: Text('${a.name} · ${a.currency}'),
                ),
            ],
            onChanged: saving
                ? null
                : (v) => setState(() {
                    accountId = v;
                    if (toAccountId == v) toAccountId = null;
                  }),
          ),
          const SizedBox(height: 16),
          if (kind == 'transfer')
            DropdownButtonFormField<String>(
              key: ValueKey('destination-$accountId'),
              initialValue: toAccountId,
              decoration: const InputDecoration(labelText: 'To account'),
              items: [
                for (final a in b.accounts.where((a) => a.id != accountId))
                  DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: saving ? null : (v) => setState(() => toAccountId = v),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in b.categories.where(
                  (c) => !c.archived || c.id == categoryId,
                ))
                  ChoiceChip(
                    label: Text(c.name),
                    avatar: Icon(
                      icons[c.icon],
                      size: 18,
                      color: Color(c.color),
                    ),
                    selected: categoryId == c.id,
                    onSelected: saving
                        ? null
                        : (_) => setState(() => categoryId = c.id),
                  ),
              ],
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Date'),
            subtitle: Text(
              '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
            ),
            trailing: const Icon(Icons.calendar_month),
            onTap: saving
                ? null
                : () async {
                    final v = await showDatePicker(
                      context: context,
                      initialDate: day,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100, 12, 31),
                    );
                    if (v != null) setState(() => day = v);
                  },
          ),
          TextField(
            key: const ValueKey('entry-note'),
            controller: note,
            enabled: !saving,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('save-entry'),
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    try {
                      await b.saveEntry(
                        id: widget.entry?.id,
                        accountId: accountId!,
                        categoryId: categoryId!,
                        amount: minor(amount.text),
                        kind: kind,
                        date: day,
                        note: note.text,
                        toAccountId: toAccountId,
                      );
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (mounted && context.mounted) {
                        setState(() => saving = false);
                        notice(context, e);
                      }
                    }
                  },
            child: Text(saving ? 'Saving…' : 'Save transaction'),
          ),
        ],
      ),
    );
  }
}

class AccountEditor extends StatefulWidget {
  final Account? account;
  const AccountEditor({super.key, this.account});
  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final name = TextEditingController(),
      opening = TextEditingController(text: '0');
  String? currency;
  String kind = 'cash';
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final account = widget.account;
    if (account != null) {
      name.text = account.name;
      opening.text = (account.opening / 100).toStringAsFixed(2);
      currency = account.currency;
      kind = account.kind;
    }
  }

  @override
  void dispose() {
    name.dispose();
    opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = BookScope.of(context);
    currency ??= b.base;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.account == null ? 'Add account' : 'Edit account'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Account name'),
          ),
          DropdownButtonFormField<String>(
            initialValue: currency,
            decoration: const InputDecoration(labelText: 'Currency'),
            items: [
              for (final c in b.rates.keys)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: saving ? null : (v) => setState(() => currency = v),
          ),
          DropdownButtonFormField<String>(
            initialValue: kind,
            decoration: const InputDecoration(labelText: 'Account type'),
            items: [
              for (final k in ['cash', 'bank', 'savings', 'debt'])
                DropdownMenuItem(value: k, child: Text(k)),
            ],
            onChanged: saving ? null : (v) => setState(() => kind = v!),
          ),
          TextField(
            controller: opening,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Opening balance'),
          ),
          const Text(
            'For a debt, enter a negative opening balance. Set extra currency rates in Accounts first.',
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    try {
                      final raw = opening.text.trim();
                      final n = raw == '0' || raw == '0.00'
                          ? 0
                          : minor(
                                  raw.startsWith('-') ? raw.substring(1) : raw,
                                ) *
                                (raw.startsWith('-') ? -1 : 1);
                      if (widget.account == null) {
                        await b.addAccount(name.text, currency!, n, kind);
                      } else {
                        await b.updateAccount(
                          widget.account!.id,
                          name.text,
                          currency!,
                          n,
                          kind,
                        );
                      }
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (mounted && context.mounted) {
                        setState(() => saving = false);
                        notice(context, e);
                      }
                    }
                  },
            child: Text(saving ? 'Saving…' : 'Save account'),
          ),
        ],
      ),
    );
  }
}

class CategoryManager extends StatelessWidget {
  const CategoryManager({super.key});
  @override
  Widget build(BuildContext context) {
    final b = BookScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          IconButton(
            tooltip: 'Add category',
            onPressed: () async {
              final v = await input(context, 'New category');
              if (v != null && context.mounted) {
                try {
                  await b.addCategory(v);
                } catch (e) {
                  if (context.mounted) notice(context, e);
                }
              }
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: b,
        builder: (context, _) => ListView(
          children: [
            for (final c in b.categories)
              ListTile(
                leading: Icon(icons[c.icon], color: Color(c.color)),
                title: Text(c.name),
                subtitle: c.archived ? const Text('Archived') : null,
                onTap: () async {
                  final v = await input(
                    context,
                    'Category name',
                    initial: c.name,
                  );
                  if (v != null && context.mounted) {
                    try {
                      await b.renameCategory(c.id, v);
                    } catch (e) {
                      if (context.mounted) notice(context, e);
                    }
                  }
                },
                trailing: IconButton(
                  tooltip: c.archived ? 'Restore' : 'Archive',
                  onPressed: () async {
                    try {
                      if (!c.archived &&
                          b.categories.where((c) => !c.archived).length == 1) {
                        throw const FormatException(
                          'Keep at least one active category.',
                        );
                      }
                      await b.archiveCategory(c.id);
                    } catch (e) {
                      if (context.mounted) notice(context, e);
                    }
                  },
                  icon: Icon(
                    c.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CategoryRecords extends StatelessWidget {
  final String categoryId;
  final List<Entry> Function() rows;
  const CategoryRecords({
    super.key,
    required this.categoryId,
    required this.rows,
  });
  @override
  Widget build(BuildContext context) {
    final b = BookScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(b.category(categoryId).name)),
      body: ListView(
        children: [
          for (final e in rows())
            ListTile(
              title: Text(money(e.amount, b.account(e.accountId).currency)),
              subtitle: Text('${e.date} ${e.note}'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => EntryEditor(entry: e)),
              ),
            ),
        ],
      ),
    );
  }
}
