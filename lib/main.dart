import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine/column_mapper.dart';
import 'services/database_service.dart';
import 'services/excel_service.dart';
import 'services/log_service.dart';
import 'services/storage_manager.dart';
import 'ui/screens/crash_recovery_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Allow both landscape and portrait orientations — tablet-first design.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize core services — dependency-injected into screens via constructors.
  final dbService = DatabaseService();
  LogService.init(dbService);

  // Restore custom column mapper aliases saved in admin_config SQLite table.
  final savedAliasesJson = await dbService.getConfig('column_mapper_config');
  final columnMapper = savedAliasesJson != null
      ? ColumnMapper.fromJson(savedAliasesJson)
      : ColumnMapper();

  // If column_mapper_config in SQLite was missing keyComponentResourceId, persist updated JSON
  if (savedAliasesJson == null || !savedAliasesJson.contains(ColumnMapper.keyComponentResourceId)) {
    await dbService.setConfig('column_mapper_config', columnMapper.toJson());
  }

  // Sync all known catalogs and backfill any missing component_resource_id from raw_columns
  try {
    await dbService.syncAllKnownCatalogs(columnMapper);
  } catch (e) {
    LogService.warn('Startup', 'Failed to sync catalogs: $e');
  }

  final storageManager = StorageManager(dbService);
  final excelService = ExcelService(mapper: columnMapper);

  // Hook global Flutter error & crash handlers to LogService & CrashRecoveryScreen
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    LogService.crash(
      'FlutterError',
      details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
    );
  };

  // Custom ErrorWidget for runtime Flutter framework errors with 10-second auto-close
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return CrashRecoveryScreen(
      errorDetails: details,
      dbService: dbService,
      storageManager: storageManager,
      excelService: excelService,
      columnMapper: columnMapper,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    LogService.crash(
      'PlatformDispatcher',
      error.toString(),
      stackTrace: stack.toString(),
    );
    return true;
  };

  // Housekeeping on startup: purge expired soft-deleted units older than 30 days
  // and issued sessions older than 60 days
  try {
    await dbService.purgeExpiredDeletedUnits(retentionDays: 30);
    await dbService.purgeExpiredIssuedSessions(retentionDays: 60);
  } catch (e) {
    LogService.warn('Startup', 'Failed housekeeping purge: $e');
  }

  LogService.info('AppStartup', 'Pick List Tracker started successfully.');

  runApp(PicklistTrackerApp(
    dbService: dbService,
    storageManager: storageManager,
    excelService: excelService,
    columnMapper: columnMapper,
  ));
}

class PicklistTrackerApp extends StatelessWidget {
  final DatabaseService dbService;
  final StorageManager storageManager;
  final ExcelService excelService;
  final ColumnMapper columnMapper;

  const PicklistTrackerApp({
    super.key,
    required this.dbService,
    required this.storageManager,
    required this.excelService,
    required this.columnMapper,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pick List Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      // HomeScreen is the launch root — presents Admin / Picker role selection.
      home: HomeScreen(
        dbService: dbService,
        storageManager: storageManager,
        excelService: excelService,
        columnMapper: columnMapper,
      ),
    );
  }
}
