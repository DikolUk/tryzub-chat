import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<String?> downloadTextFile({required String filename, required String content}) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {}
  dir ??= await getApplicationDocumentsDirectory();

  final file = File('${dir.path}/$filename');
  await file.writeAsString(content);
  return file.path;
}
