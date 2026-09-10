# Build and verify Mac Duo

## Build

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

You can also store that identity in a local `signing-identity.txt`, which is ignored by Git. Keep using the same identity for updates. An ad-hoc signature changes with the executable, so macOS may require granting access again after a rebuild. No certificate, private key, signing identity file, or personal validation log is included in this repository.

The app packaging step strips debug symbols before signing so local build-folder paths are not included in the distributed executable. Keep debug symbols in your local build directory, and use ad-hoc signing for public development downloads if you do not intend to publish your certificate identity. Check the final DMG and ZIP contents as well as source files before uploading a release.

## Privacy and implementation

ScreenCaptureKit excludes this app from its own capture. Audio capture is disabled. Desktop frames remain in bounded memory; they are not saved, uploaded or analyzed. The live effect uses no network service, account, analytics or third-party runtime dependency.

The HID reader runs off the main thread. A Metal fragment shader and reusable blur pyramid render the effect. Reduce Motion uses a simple fade. Capture stops when the effect clears, and sensor/capture failures restore the desktop.

Launch-at-login uses macOS `SMAppService.mainApp`; it does not add a helper executable. The setting is opt-in and its status is read from Service Management so changes made in System Settings are reflected. Background startup only resumes following when Screen Recording access is already authorized and a valid lid reading arrives; it never requests permission without an explicit user action.

macOS owns sleep and the secure login screen. Animation cannot be guaranteed while the display is asleep, during login or with protected content. Capture may take a moment to warm up; the desktop and live preview remain clear until a fresh frame is ready.

## Verify

```sh
swift test
swift build
.build/debug/MacDuo --render-check validation
```

The render check uses generated artwork only; it does not capture the desktop. It verifies all five effects: pixel identity when open/reopened, black closure, opacity, blur, practical geometry, distinct intermediate frames, smooth onset, Reduce Motion, cache freshness and GPU timing. Add `--animation` to export generated closing/reopening frames for every effect. GPU measurements exclude capture and display composition. Physical lid sweeps, sustained energy use and platform lifecycle transitions still need testing on more hardware.

## Version 0.1.6 background fix

Capture discovery includes offscreen windows and retains the process identity used to exclude Mac Duo. Desktop changes clear old frames and resume capture without changing the enabled state. Settings rise above the effect only when the user is actively using that window, and return to normal when focus leaves. The old 45-second auto-pause was removed; Esc, the pause shortcut, and stillness clearing remain available.

The optimized build and 19 tests pass. The old build was observed auto-disabling at 45 seconds; the update remained enabled for 214 seconds until deliberately quit for a relaunch. Live logs confirmed desktop changes with following still enabled, fresh capture and presentation while inactive, and the settings window at its normal level. Renderer and shader files are unchanged from the measurements below.

## Version 0.1.5 renderer validation

The optimized arm64 build and 19 Swift tests passed on an Apple M4 MacBook Pro. All five GPU render checks passed at 3024 × 1964; per-effect GPU time at the 95th percentile ranged from 1.94 to 2.30 ms. These are offscreen shader measurements, not a 120 FPS or battery-life claim. This is an early, unnotarized release; a full physical lid sweep and sustained battery/latency measurements remain unverified.

## Contributing

Issues and focused pull requests are welcome. Include macOS version, Mac model, whether its lid sensor is detected, reproduction steps and relevant test results. Do not attach private desktop recordings or signing credentials. Run the checks above for renderer, motion, or lifecycle changes. Keep the app dependency-free and respect Reduce Motion and existing power limits.

## Credits

The implementation is original. Public demonstrations and hardware research helped guide it; see [ATTRIBUTION.md](../ATTRIBUTION.md). Mac Duo is independent and is not affiliated with Apple, Bendy or the reference projects.
