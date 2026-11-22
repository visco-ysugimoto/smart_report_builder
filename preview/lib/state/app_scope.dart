import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_state.dart';
import 'package:smart_report_preview/state/report_service.dart';

/// 画面全体へ AppState と ReportService を渡す InheritedNotifier。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({
    required AppState state,
    required this.service,
    required super.child,
    super.key,
  }) : super(notifier: state);

  final ReportService service;

  static AppState stateOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope.of called without a scope');
    return scope!.notifier!;
  }

  static ReportService serviceOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope.serviceOf called without a scope');
    return scope!.service;
  }
}
