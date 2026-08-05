import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'host/host_controller.dart';
import 'theme.dart';
import 'ui/app_scope.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required for the foreground service to talk to the app isolate.
  FlutterForegroundTask.initCommunicationPort();
  // Edge-to-edge with transparent system bars; each screen pads its content
  // past the status/gesture bars (see the per-scrollview viewPadding insets).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const MtgTourneyApp());
}

class MtgTourneyApp extends StatefulWidget {
  const MtgTourneyApp({super.key});

  @override
  State<MtgTourneyApp> createState() => _MtgTourneyAppState();
}

class _MtgTourneyAppState extends State<MtgTourneyApp> {
  // One controller for the whole app: owns the server, the foreground service,
  // and the durable store. Created here so it survives tab/screen changes and
  // backs the history/stats screens.
  final HostController _controller = HostController();

  @override
  void initState() {
    super.initState();
    _controller.init(); // attach storage + resume any in-progress event
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: _controller,
      child: MaterialApp(
        title: 'MTG Tournament',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: const RootGate(),
      ),
    );
  }
}
