import 'package:flutter/material.dart';

import 'core/document_store.dart';
import 'core/money_book.dart';
import 'shell/ab_host.dart';
import 'src/workspace.dart';

class AmavethApp extends StatefulWidget {
  final bool enableIm;
  final String? cachedUrl;
  final MoneyBook? book;
  final Future<MoneyBook> Function()? bookLoader;
  const AmavethApp({
    super.key,
    this.enableIm = false,
    this.cachedUrl,
    this.book,
    this.bookLoader,
  });
  @override
  State<AmavethApp> createState() => _AppState();
}

class _AppState extends State<AmavethApp> {
  MoneyBook? book;
  Object? error;
  bool disposed = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final b = widget.book ?? await (widget.bookLoader?.call() ?? openBook());
      if (disposed) {
        if (widget.book == null) b.dispose();
        return;
      }
      b.addListener(changed);
      setState(() {
        book = b;
        error = null;
      });
    } catch (e) {
      if (!disposed) setState(() => error = e);
    }
  }

  Future<MoneyBook> openBook() async {
    final b = MoneyBook(await EncryptedDocumentStore.open());
    try {
      await b.load();
      return b;
    } catch (_) {
      b.dispose();
      rethrow;
    }
  }

  // A may still be opening its private database when B is selected. Keep its
  // loader/error confined to the tool child; neither is a gate in front of B.
  Widget toolPage(BuildContext context) => error != null
      ? Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Could not open the private ledger. Your data has not been reset.',
                ),
                TextButton(onPressed: load, child: const Text('Retry')),
              ],
            ),
          ),
        )
      : book == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : const ToolWorkspace();

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    disposed = true;
    book?.removeListener(changed);
    if (widget.book == null) book?.dispose();
    super.dispose();
  }

  ThemeData theme(bool dark) => ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    scaffoldBackgroundColor: dark
        ? const Color(0xff202729)
        : const Color(0xfff2fcf3),
    appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: brand,
    debugShowCheckedModeBanner: false,
    theme: theme(false),
    darkTheme: theme(true),
    themeMode: book?.dark == true ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) =>
        book == null ? child! : BookScope(book: book!, child: child!),
    home: widget.enableIm
        ? AbHost(cachedUrl: widget.cachedUrl, toolBuilder: toolPage)
        : toolPage(context),
  );
}
