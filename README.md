<img src="docs/assets/mark.png" alt="Mac Duo logo" width="96" align="right">

# Mac Duo

**Make your desktop feel physical.** Six effects that follow the movement of your MacBook lid.

[![Release](https://img.shields.io/github/v/release/DhananjayBhosale/MacDuo?color=c65a16&label=download)](https://github.com/DhananjayBhosale/MacDuo/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-333333)](#install)
[![MIT](https://img.shields.io/badge/license-MIT-c65a16)](LICENSE)

### [↓ Download for Apple silicon](https://github.com/DhananjayBhosale/MacDuo/releases/latest/download/Mac-Duo.dmg)

[Intel preview download](https://github.com/DhananjayBhosale/MacDuo/releases/latest/download/Mac-Duo-Intel.dmg) · Intended for the 2019 16-inch MacBook Pro; physical Intel verification is pending.

[Website](https://macduo.dhananjaytech.app/) · [All releases & ZIP](https://github.com/DhananjayBhosale/MacDuo/releases) · [Changelog](CHANGELOG.md) · [Build from source](docs/DEVELOPMENT.md) · [Report an issue](https://github.com/DhananjayBhosale/MacDuo/issues)

<p align="center"><a href="https://macduo.dhananjaytech.app/"><img src="docs/assets/effects-preview.gif" alt="Generated artwork showing the Duo effect closing and reopening" width="720"></a><br><sub>Generated Duo demo. Your real desktop stays on your Mac.</sub></p>

## Six ways to close

| Effect | What it feels like |
|---|---|
| **Duo** · default | The desktop expands, softens and disappears around the hinge. |
| **Ghost** | The desktop appears anchored behind the tilting lid, with gradual defocus. |
| **Roll** | A flexible display curling into a roll. |
| **Shutter** | Four rigid panels sliding behind one another. |
| **Flex** | A continuous display bowing under tension. |
| **Iris** | Precision blades closing around the desktop. |

<p><a href="https://macduo.dhananjaytech.app/#effects"><img src="docs/assets/roll.jpg" alt="Roll effect" width="24%"> <img src="docs/assets/shutter.jpg" alt="Shutter effect" width="24%"> <img src="docs/assets/flex.jpg" alt="Flex effect" width="24%"> <img src="docs/assets/iris.jpg" alt="Iris effect" width="24%"></a></p>

Hold the lid still and the screen clears after **1–5 seconds**—**2 seconds** by default. Live preview, compact floating controls, orange Light/Dark themes, menu-bar access and an opt-in **Open at login** setting are included. Login launches start paused. The menu-bar icon stays visible by default but can be hidden. Close settings or switch desktops: Mac Duo keeps following in the background, without raising its window. Press **Esc** or **⌃⌥⌘F** to pause.

## Install

**Mac Duo 0.1.15 supports macOS 13 Ventura or newer**, with six effects including Ghost. A compatible continuous lid-angle sensor is required. The native Apple-silicon build was tested on an M4 Mac; physical Ventura, clamshell/mirroring and Intel testing are still pending.

> [!NOTE]
> **MacBook compatibility · macOS 13+**<br>
> **Expected to work:** MacBook Air with M2 or newer, and 14-/16-inch MacBook Pro with M1 Pro/Max or newer.<br>
> **Intel preview:** 2019 16-inch MacBook Pro. This download compiles and packages natively for Intel, but still needs physical hardware verification.<br>
> **Unsupported:** M1 MacBook Air, 13-inch MacBook Pro with M1 or M2, and Intel models that expose only an open/closed clamshell switch.<br>
> Tested on an M4 MacBook Pro. Mac Duo checks for a compatible lid sensor; external displays are not animated.

1. Download [**Mac-Duo.dmg** for Apple silicon](https://github.com/DhananjayBhosale/MacDuo/releases/latest/download/Mac-Duo.dmg) or [**Mac-Duo-Intel.dmg** for Intel](https://github.com/DhananjayBhosale/MacDuo/releases/latest/download/Mac-Duo-Intel.dmg), open it, and drag **Mac Duo** into **Applications**.
2. Open **Mac Duo** from Applications. This release is **not notarized**, so macOS may initially block it with “cannot be opened” or “Apple could not verify” wording.
3. After trying to open it, go to **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** for **Mac Duo**, then confirm **Open**. [Apple’s instructions](https://support.apple.com/102445).
4. In Mac Duo, click **Enable Mac Duo** and allow **Screen Recording** when prompted. Reopen the app if macOS asks. Desktop frames stay in memory; nothing is recorded or uploaded.

Try **Replay** first—it works without Screen Recording permission. For manual control, turn off **Follow my lid**. Keep **Clear when the lid is still** enabled for normal use at any angle.

<details><summary><strong>Updating or using the ZIP instead</strong></summary>

In Mac Duo, choose **Check for Updates…** from the header or menu bar, then **Install & Relaunch**. The app checks the official GitHub release, selects the native Apple-silicon or Intel ZIP, and verifies the download before replacing itself. Checks run only when you ask. macOS may require **Privacy & Security → Open Anyway** for an update; the recovery dialog lets you retry or restore the previous app. Install the app in a writable Applications folder first.

For a manual update, quit Mac Duo before replacing the app in Applications. For the ZIP, unzip it and move **Mac Duo.app** into Applications, then follow steps 2–4 above. Development signatures may require granting Screen Recording again after an update. If permission appears enabled but capture fails, remove the old Mac Duo entry in Screen Recording settings, add the current app from Applications, and reopen it.

</details>

## Languages

Mac Duo supports English, Simplified Chinese, Traditional Chinese and Japanese. It follows your macOS language preferences, with English as the fallback. To choose a language just for Mac Duo, add it under **System Settings → General → Language & Region → Applications**, then quit and reopen the app.

## Small, local, open

Native **Swift + Metal**, with no third-party runtime dependencies, accounts or analytics. Effects stay entirely local; **Check for Updates** contacts GitHub only when you request it, and installation downloads the release. No screen content is sent. Settled previews stop rendering; blur is cached. Rendering is capped according to power and temperature, with up to 120 Hz requested on supported displays while plugged in. Actual frame rate and battery impact vary by Mac.

[Build & verification](docs/DEVELOPMENT.md) · [Reference credits](ATTRIBUTION.md) · [MIT license](LICENSE)

Independent software, not affiliated with Apple. Contributions and hardware reports are welcome.
