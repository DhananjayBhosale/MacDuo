# Changelog

## 0.1.15 · 21 September 2026

- **Clamshell and mirroring recovery.** When the built-in display becomes unavailable or mirrored, Mac Duo now clears the overlay without switching itself off. Following resumes automatically when an active, unmirrored built-in display returns.
- **Faster capture restarts.** ScreenCaptureKit display discovery is reused between capture starts, invalidated when the display layout changes, and refreshed once if a cached start fails.
- **More resilient launches.** The settings renderer is initialized after the initial app-launch handshake, pending update jobs share one executable validation pass, and launch/capture timing is logged for diagnostics.
- **Clearer update security wording.** Package checks now state that checksums and internal code-signature consistency verify integrity, not publisher authenticity.
- **Secure lock-screen behavior.** Desktop capture deliberately stops when the macOS user session locks and never renders captured desktop content over the secure login screen.

The Apple-silicon renderer and native ARM64 download remain unchanged in architecture and performance path. All source tests, six GPU effects, package validation, update replacement/rollback, and an M4 app launch passed. Clamshell/mirroring behavior and the Intel preview still need confirmation on affected physical hardware.

## 0.1.14 · 11 September 2026

- **Separate native Intel preview.** The normal Mac Duo build and downloads remain ARM64-only for M-series Macs. Independently packaged x86_64 downloads are available for Intel models that expose the continuous lid-angle HID sensor, notably the 2019 16-inch MacBook Pro. Older models with only an open/closed clamshell switch remain unsupported.
- **Architecture-aware updates.** M-series Macs keep using `Mac-Duo-mac.zip`; Intel builds select `Mac-Duo-Intel.zip`. Neither architecture needs Rosetta to run Mac Duo.

The Apple-silicon build was verified on an M4 Mac. Physical Intel hardware verification remains pending, so the Intel download is a preview.

## 0.1.13 · 11 September 2026

- **Four interface languages.** Mac Duo now follows macOS in English, Simplified Chinese, Traditional Chinese or Japanese, with English fallback. Settings, menus, status messages, update dialogs and the Screen Recording description are localized.
- **Open at login.** A new opt-in system Login Item starts Mac Duo paused. The menu-bar icon remains on by default and can now be hidden; reopening Mac Duo brings its settings back.
- **More responsive lid tracking.** Sensor polling now follows the existing power-, temperature- and display-aware motion refresh cap.
- **A steadier Ghost.** Ghost keeps its assumed viewing position fixed relative to the keyboard at different starting angles. Whole-degree sensor steps are smoothed without adding a degree of lag. Shallow angles use a stable fallback, the reference plane stays paired through clearing or resumed movement, and lighter progressive blur keeps content near the hinge clearer.

Public builds remain ad-hoc signed and not notarized. First launch or an update may require **System Settings → Privacy & Security → Open Anyway**, and Screen Recording permission may need approval again.

## 0.1.12 · 11 September 2026

- **Ghost joins the effects.** A new second option that keeps the desktop at an apparent resting plane while the lid tilts. Perspective compensation and gradual blur make the display feel like moving glass. Duo remains the default; all six effects are available.
- **macOS 13 Ventura support.** Both the app and executable now target macOS 13 or newer. Compatible MacBook lid hardware is still required.
- **Check for Updates.** Check the official GitHub release from the app or menu bar, then download, verify, install and relaunch. No background polling or account needed.
- **Gentler movement.** Small bends introduce less blur, with stronger defocus after about 15°. After resting, the next movement starts from that angle.
- **Smoother clearing.** After the selected 1–5 second pause, the desktop and preview animate back to clear together. Low resting angles, Flex shadows and Iris blur also respond more gradually.
- **Less redundant work.** Retire unused effect buffers, reuse captured frame imports and Metal pipelines, and reduce repeated main-thread work while retaining native capture resolution and existing power limits.

This release includes the changes developed in local builds 0.1.7–0.1.11. Physical Ventura testing and controlled battery/CPU comparisons are still pending; no specific performance gain or frame rate is promised.

Public builds are ad-hoc signed and not notarized. First launch may require **System Settings → Privacy & Security → Open Anyway**; Screen Recording permission may need to be granted again after updating. See [installation instructions](README.md#install).

## 0.1.6 · 10 September 2026

- Keep following the lid when settings close or desktops change.
- Avoid bringing an inactive settings window to the front.
- Remove the old 45-second automatic pause.

For earlier releases, see [GitHub Releases](https://github.com/DhananjayBhosale/MacDuo/releases).
