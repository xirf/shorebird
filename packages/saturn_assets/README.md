# Saturn assets

This Flutter package overlays `flutter_assets` for the Shorebird patch currently running on the device. The Saturn server stores one ZIP for each patch and platform. The ZIP contains changed/new asset files at their Flutter logical keys, plus the patched build's `AssetManifest.bin`.

Call `SaturnAssets.load` after `ShorebirdUpdater.readCurrentPatch()`, then pass its `bundle` to `DefaultAssetBundle` in `MaterialApp.builder`:

```dart
final patch = (await ShorebirdUpdater().readCurrentPatch())?.number ?? 0;
final assets = await SaturnAssets.load(
  server: Uri.parse('https://saturn.andka.id'),
  appId: '<shorebird app id>',
  releaseVersion: '1.0.0+1',
  channel: 'stable',
  platform: 'android',
  patchNumber: patch,
);
runApp(MaterialApp(
  builder: (context, child) => DefaultAssetBundle(
    bundle: assets.bundle,
    child: child!,
  ),
  home: const MyHome(),
));
```

Assets loaded through `DefaultAssetBundle.of(context)`, `Image.asset`, and `AssetImage` can use the overlay. Direct `rootBundle` calls and engine/native resources cannot. Images already decoded before the bundle changes may need eviction or an app restart. Call the loader before `runApp` to avoid that case.

Downloaded OTF and TTF files can be registered with Flutter before `runApp`:

```dart
await assets.loadFont(family: 'PatchedText', asset: 'assets/patched-text.ttf');
await assets.loadFont(family: 'PatchedIcons', asset: 'assets/patched-icons.ttf');
```

Use `fontFamily: 'PatchedText'` in a `TextStyle`, or construct `IconData` with `fontFamily: 'PatchedIcons'`. Updating the `fonts:` section of `pubspec.yaml` alone does not register a downloaded font; runtime registration is required.

The ZIP SHA-256 is verified against server metadata before extraction. HTTPS protects metadata in transit. A future production version should add a separate signing key for the asset metadata, matching Shorebird's signed code patch model.

