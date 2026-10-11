# Legacy

`avatar_3d.dart.txt` — draft 3D avatar (three_js). Removed from the build on 2026-10-11:
the project uses the 2D avatar, and three_js pulled flutter_angle, which needs CMake to build the APK.
To bring it back: move it to `lib/avatar_3d.dart` and add `three_js: 0.3.0` to pubspec.yaml.
