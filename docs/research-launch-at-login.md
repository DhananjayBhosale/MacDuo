# Launch at Login research

## Goal

Make Mac Duo available as a background menu-bar utility after login without
forcing a Screen Recording prompt or changing the existing manual enable flow.

## Findings

- The project targets macOS 14, so `ServiceManagement.SMAppService` is
  available. Apple documents `SMAppService.mainApp` as the service object for
  configuring the main app to launch at login.
- `SMAppService.register()` registers the main app for subsequent logins and
  may require user approval. `SMAppService.unregister()` prevents future login
  launches while leaving the currently running app alive.
- `SMAppService.mainApp.status` exposes `notRegistered`, `enabled`,
  `requiresApproval`, and `notFound`, which lets the UI explain incomplete
  registration without treating it as a capture error.
- `SMAppService.openSystemSettingsLoginItems()` is the supported route to the
  Login Items pane when macOS requires approval.
- The current app creates `AppModel` in `applicationDidFinishLaunching`, always
  calls `showSettings()`, and keeps the enabled state in memory only. The
  existing `UserDefaults` pattern is appropriate for a new opt-in preference.
- The app's capture path already distinguishes permission verification from
  enabling. Login startup must use the existing preflight state and never call
  an API that prompts for Screen Recording while the user is not present.

## Proposed behavior

1. Add an opt-in `Launch at Login` preference, defaulting to off for existing
   installs.
2. Register or unregister `SMAppService.mainApp` when the preference changes.
3. Expose the service status in Settings and the menu-bar menu.
4. If the app is launched by macOS at login, keep the app in the menu bar and
   do not open the Settings window automatically.
5. Resume following only when Screen Recording access is already granted and a
   valid lid sensor reading is available. Otherwise remain paused and show a
   non-blocking status message.
6. Keep manual launch behavior unchanged: opening Mac Duo shows Settings.

## FAQ

### Does this add a helper executable or a dependency?

No. `SMAppService.mainApp` manages the existing signed app bundle and uses a
system framework already available on the deployment target.

### Can login startup trigger a privacy prompt?

It should not. Automatic resume must be gated by a successful existing
permission preflight; the explicit Enable button remains the only path that
can lead the user through capture authorization.

### What happens if the user disables the item in System Settings?

The next launch reads `SMAppService.mainApp.status`, reflects the disabled
state, and leaves the local preference consistent with the system state after
the user changes the setting in the app.

### Is an app bundle change required?

No additional login-item helper bundle is required for `mainApp`. The existing
bundle identifier and signed application are sufficient.

### What remains outside this PR?

Automatic updates, external-display animation, and a configurable hot-key are
separate concerns and should not be coupled to login registration.
