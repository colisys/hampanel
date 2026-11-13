import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/enrollment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final enrollment = await Enrollment.load();
  runApp(HampanelApp(initial: enrollment));
}
