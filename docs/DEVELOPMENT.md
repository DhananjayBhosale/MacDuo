# Build and verify Mac Duo

## Build

Use **Xcode 16 or newer / Swift 6** on a supported build host. The app itself targets **macOS 13 Ventura or newer** on Apple silicon and Intel; a compatible continuous lid-angle sensor is required for automatic following. A newer build SDK does not raise the app's deployment target.

```sh
git clone https://github.com/DhananjayBhosale/MacDuo.git
cd MacDuo
./build.sh
open "build/Mac Duo.app"
```

The default build uses ad-hoc signing. For a stable Screen Recording identity across rebuilds, provide your own Apple Development certificate:

```sh
MACDUO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
```

The default app remains a native ARM64 build for M-series Macs. Build the separately packaged Intel app explicitly:

```sh
./build.sh
MACDUO_ARCH=x86_64 MACDUO_BUILD_DIR=.build-intel ./build.sh
```

The commands write to `build/Mac Duo.app` and `build-intel/Mac Duo.app` respectively, so one build cannot overwrite the other. Set `MACDUO_OUTPUT_DIR` only when a different destination is needed. Do not combine the slices for distribution. Keep the M-series downloads named `Mac-Duo.dmg` and `Mac-Duo-mac.zip`; use `Mac-Duo-Intel.dmg` and `Mac-Duo-Intel.zip` for Intel. Both are native builds and neither requires Rosetta.

You can also store that identity in a local `signing-identity.txt`, which is ignored by Git. Keep using the same identity for updates. An ad-hoc signature changes with the executable, so macOS may require granting access again after a rebuild. No certificate, private key, signing identity file, or personal validation log is included in this repository.

The app packaging step strips debug symbols before signing so local build-folder paths are not included in the distributed executable. Keep debug symbols in your local build directory, and use ad-hoc signing for public development downloads if you do not intend to publish your certificate identity. Check the final DMG and ZIP contents as well as source files before uploading a release.

## Privacy and implementation

ScreenCaptureKit excludes this app from its own capture. Audio capture is disabled. Desktop frames remain in bounded memory; they are not saved, uploaded or analyzed. The live effect uses no network service, account, analytics or third-party runtime dependency. User-initiated update checks and downloads contact GitHub; they never include desktop frames.

The HID reader runs off the main thread. A Metal fragment shader and reusable blur pyramid render the effect. Reduce Motion uses a simple fade. Capture stops when the effect clears, and sensor/capture failures restore the desktop.

macOS owns sleep and the secure login screen. Mac Duo deliberately stops capture when the user session locks and never renders captured desktop content over the secure login screen. Animation cannot be guaranteed while the display is asleep, during login or with protected content. Capture may take a moment to warm up; the desktop and live preview remain clear until a fresh frame is ready.

## Verify

```sh
swift test
swift build
.build/debug/MacDuo --render-check validation
```

The render check uses generated artwork only; it does not capture the desktop. It verifies all six effects: pixel identity when open/reopened, black closure, opacity, blur, practical geometry, distinct intermediate frames, smooth onset, Reduce Motion, cache freshness and GPU timing. Add `--animation` to export generated closing/reopening frames for every effect. GPU measurements exclude capture and display composition. Physical lid sweeps, sustained energy use and platform lifecycle transitions still need testing on more hardware.

## Version 0.1.15

Display topology changes are fail-clear and preserve the user's enabled state. A missing or mirrored built-in display stops capture, invalidates the cached ScreenCaptureKit display, and waits for an active unmirrored built-in display before resuming. Stream-stop and in-flight start failures use the same generation-guarded decision so stale failures cannot disable a newly restored display.

ScreenCaptureKit shareable content is cached after access verification and refreshed on topology changes or once after a cached start failure. Launch work defers the SwiftUI/Metal settings content by one main-queue turn, hashes the executable only when pending update jobs exist, and records launch/capture timing. Package-check output distinguishes archive integrity and internal signature consistency from publisher authenticity. Capture stops while the macOS user session is locked.

The ARM64 and x86_64 downloads remain separate native builds. The renderer and shader path are unchanged. Source tests, localization coverage, all six generated GPU checks, package extraction, the LaunchServices ready handshake, replacement/rollback, and a packaged app launch passed on an M4 Mac. Physical clamshell/mirroring, Ventura and Intel confirmation remain pending.

## Version 0.1.14

The normal packaged executable remains ARM64-only. A separate x86_64 preview build is produced without changing the renderer, UI or M-series runtime. The updater selects `Mac-Duo-mac.zip` on ARM64 and `Mac-Duo-Intel.zip` on Intel, while using the shared checksum manifest. The continuous sensor is undocumented and model-dependent: the intended Intel target is the 2019 16-inch MacBook Pro. Intel machines with only an open/closed clamshell switch correctly remain in the sensor-unavailable state. A physical Intel Mac is still required to verify HID reports, ScreenCaptureKit, Metal rendering and Screen Recording permission end to end.

## Version 0.1.13

Ghost transforms a fixed keyboard-space viewer into the resting screen plane using the absolute reference angle. Projection references below 90° use an upright virtual plane to avoid placing the viewer behind the panel. The reference travels with the animated tilt and remains fixed throughout a clear transition; interrupted clears retarget both together. An exact critically damped tilt response smooths whole-degree HID reports while keeping the rendered panel within one degree of motion. The Metal uniform remains 48 bytes. Blur grows from zero at the hinge and uses a lower maximum radius.

World-space ray tests cover multiple resting angles and viewing distances. This is still an assumed viewpoint, not head tracking; subjective physical feel needs confirmation on the actual Mac.

The app follows macOS language selection for English, Simplified Chinese, Traditional Chinese and Japanese. `SMAppService.mainApp` provides opt-in launch at login; it does not enable the live effect or request Screen Recording access. The optional menu-bar icon remains enabled by default. Lid HID polling follows the same power-, temperature- and display-aware 30/60/120 Hz cap as motion rendering.

## Version 0.1.12

This release gathers the locally tested 0.1.7–0.1.11 changes and adds an in-app updater and Ghost perspective compensation. Both the executable and bundle target macOS 13; the Metal shaders use the Metal 3.0 baseline. Physical Ventura testing remains pending.

Ghost intersects a stationary viewer’s ray through the tilted panel with the last resting desktop plane. Physical tilt is carried separately from eased fold progress and cleared on the same 0.6-second animation clock as blur and coverage. The Perspective slider uses a bounded viewing distance of 1.6–2.6 screen heights, so low settings retain a convincing stationary desktop. Counter-rotation tracks faster than optical softening to reduce the feeling that content follows the lid. A small geometric filter also limits minification shimmer when Softness is zero. The illusion assumes a stationary viewer; the app does not track head position. Generated tests check that landmarks remain at their reference positions under the simulated viewing geometry, blur builds gradually, and clearing restores exact source pixels.

Small movements stay gentle even at low resting angles. The response uses a minimum 20-degree geometry span and a minimum 10-degree late-blur span. At very low angles the virtual fold may not finish before macOS sleeps; sleep behavior is unchanged. Flex’s hinge shadow and Iris’s rim defocus grow gradually.

Stopped effects release their blur pyramid, imported capture texture and drawables. Immutable Metal pipelines are shared; queues and mutable textures remain per renderer. Capture callbacks update a locked, bounded frame store directly, rejecting frames from stopped or replaced streams. Repeated imports, main-thread callbacks and identical window/sensor updates are skipped. Freshness, stillness, native capture resolution and existing power caps remain intact.

The performance work was checked with generated images, resource-retirement/rebuild checks, frame freshness and concurrent capture-stop tests. Shader timings exclude screen capture and composition. Physical lid feel, sustained energy use and controlled end-to-end CPU/RAM comparisons still need measurement; do not infer a battery-life or 120 FPS guarantee from GPU timings.

### Updates

**Check for Updates** is user initiated. It reads the latest stable release from `DhananjayBhosale/MacDuo` on GitHub. ARM64 installation uses `Mac-Duo-mac.zip`; x86_64 installation uses `Mac-Duo-Intel.zip`; both use `Mac-Duo-SHA256SUMS.txt`, with download, archive and bundle validation before replacement. Keep these stable asset names in future releases. A writable installation folder is required; the updater does not request administrator access or bypass Gatekeeper. User preferences are preserved. Ad-hoc builds can require **Privacy & Security → Open Anyway** approval and reapproving Screen Recording. A helper startup acknowledgment prevents quitting into a failed installer. Relaunch acknowledgment matches the approved bundle identity, version and executable hash, including isolated macOS launch paths. The recovery dialog keeps the verified candidate and previous app safe while offering Open Privacy & Security, Try Opening Again, or Restore Previous. No security prompt is bypassed.

Update checks and downloads use HTTPS to GitHub. SHA-256 detects corrupt or mismatched downloads; an ad-hoc code signature does not prove publisher identity. Trust still depends on the official repository and GitHub HTTPS. There is no background update polling, telemetry or screen upload.

## Version 0.1.6 background fix

Capture discovery includes offscreen windows and retains the process identity used to exclude Mac Duo. Desktop changes clear old frames and resume capture without changing the enabled state. Settings rise above the effect only when the user is actively using that window, and return to normal when focus leaves. The old 45-second auto-pause was removed; Esc, the pause shortcut, and stillness clearing remain available.

The optimized build and 19 tests pass. The old build was observed auto-disabling at 45 seconds; the update remained enabled for 214 seconds until deliberately quit for a relaunch. Live logs confirmed desktop changes with following still enabled, fresh capture and presentation while inactive, and the settings window at its normal level. Renderer and shader files are unchanged from the measurements below.

## Version 0.1.5 renderer validation

The optimized arm64 build and 19 Swift tests passed on an Apple M4 MacBook Pro. All five GPU render checks passed at 3024 × 1964; per-effect GPU time at the 95th percentile ranged from 1.94 to 2.30 ms. These are offscreen shader measurements, not a 120 FPS or battery-life claim. This is an early, unnotarized release; a full physical lid sweep and sustained battery/latency measurements remain unverified.

## Contributing

Issues and focused pull requests are welcome. Include macOS version, Mac model, whether its lid sensor is detected, reproduction steps and relevant test results. Do not attach private desktop recordings or signing credentials. Run the checks above for renderer or motion changes. Keep the app dependency-free and respect Reduce Motion and existing power limits.

## Credits

Mac Duo combines its own renderer and controls with a credited adaptation of the resting-plane projection. Public demonstrations and hardware research helped guide it; see [ATTRIBUTION.md](../ATTRIBUTION.md). Mac Duo is independent and is not affiliated with Apple, Bendy or the reference projects.

## Localization

User-facing text lives in `Sources/MacDuo/Resources/{en,zh-Hans,zh-Hant,ja}.lproj`. English source strings are the keys. `L10n` explicitly loads the packaged resource bundle inside an app and falls back to `Bundle.main` during SwiftPM development so an absolute build path is not linked into release executables. Both SwiftUI and AppKit use the same lookup; missing keys fall back to English. Effect persistence identifiers remain unchanged.

To add a language, copy the English `Localizable.strings` and `InfoPlist.strings` into a new `.lproj` folder, translate the values while preserving format placeholders, and add the language to `CFBundleLocalizations` in `build.sh` and the localization test language list. The packaging script copies the SwiftPM bundle and the localized privacy descriptions into the app before signing.

Run `swift test` for key coverage and format-placeholder checks, and `./build.sh` for release packaging and signature verification. For a language smoke test, quit the app and launch it with a temporary process-only language override:

```sh
open -n "build/Mac Duo.app" --args -AppleLanguages '("ja")'
```

Repeat for `en`, `zh-Hans`, and `zh-Hant`; check the settings, effect and appearance menus, tooltips, and status messages. Also test an unsupported language such as `fr` for English fallback. Do not enable desktop capture just to verify translations. Check a copy of the packaged app outside the checkout with the build resource bundle temporarily unavailable to verify that it is self-contained.
