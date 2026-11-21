import 'package:flutter/services.dart' show rootBundle;

Future<String> loadAppConfigAsset(String assetPath) =>
    rootBundle.loadString(assetPath);
