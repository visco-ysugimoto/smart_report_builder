import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:smart_report_preview/screens/expand_screen.dart';
import 'package:smart_report_preview/screens/master_slide_screen.dart';
import 'package:smart_report_preview/screens/start_screen.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';
import 'package:smart_report_preview/state/report_service.dart';
import 'package:smart_report_preview/theme/app_theme.dart';
import 'package:smart_report_preview/widgets/step_header.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PreviewApp());
}

class PreviewApp extends StatefulWidget {
  const PreviewApp({super.key});

  @override
  State<PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<PreviewApp> {
  late final AppState _state = AppState();
  late final ReportService _service = ReportService(_state);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Report Builder',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: AppScope(
        state: _state,
        service: _service,
        child: const _RootRouter(),
      ),
    );
  }
}

class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          service.undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
          service.redo();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      body: Column(
              children: [
          const StepHeader(),
                Expanded(
            child: IndexedStack(
              index: state.step.index,
              sizing: StackFit.expand,
              children: const [
                StartScreen(),
                MasterSlideScreen(),
                ExpandScreen(),
              ],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}
