import 'dart:async';

import 'package:bilimusic/services/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Existing widget/player tests use the same repository API as the app, but
/// must not depend on platform channels or share a user's database.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  sqfliteFfiInit();
  await AppDatabase.configure(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
  await AppDatabase.instance;
  tearDownAll(AppDatabase.close);
  await testMain();
}
