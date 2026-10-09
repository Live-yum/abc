import 'package:terraforge/platform/files.dart';

// Browser local inputs must use an explicitly authorized actual picker flow.
// This harness intentionally cannot inject native personal-file paths on Web.
Future<List<({String kind, PickedFile file})>> localInputs() async => [];
