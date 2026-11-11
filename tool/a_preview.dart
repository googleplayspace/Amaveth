// Separate development entry point; normal main.dart follows DataVerna.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yueh/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AmavethApp());
}
