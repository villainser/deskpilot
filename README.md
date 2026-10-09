<p align="center"><img src="Resources/AppIcon.png" width="150" alt="DeskPilot icon"></p>

# DeskPilot

A native macOS desktop manager built with Swift, SwiftUI and AppKit. Keep each app and Chrome profile on its own desktop, bring windows together when needed, and save layouts for your displays.

## Features

- **Automatic desktops.** An unassigned app or Chrome profile gets a newly created macOS desktop. Its other windows join the same desktop; reopening it reuses the saved assignment while that desktop exists.
- **Stable assignments.** Moving an individual window does not redefine its home. Automation returns it to its assigned desktop; reordering or moving a whole desktop preserves its identity.
- **Chrome profiles.** Match profiles by their stable profile directories and the profile information exposed by Chrome's native accessibility window title. Windows belonging to different profiles are kept separate.
- **Summon windows.** Bring successive windows from a numbered desktop to your active desktop. Return each window separately to its original desktop and size, while keeping permanent assignments intact.
- **Explicit sharing.** Choose **Share desktop** to place apps together. Two visible windows from different apps or profiles are arranged side by side after sharing or summoning. Additional windows keep their positions.
- **Focus follows the pointer.** Hover briefly over a visible window to activate it before clicking. Turn this off in Settings if you prefer click-to-focus.
- **Quick window picker.** Press **Control-Space**, then a desktop number or click a row. Use the same picker to return individual summoned windows.
- **Display layouts.** Save assignments and window geometry for a display setup. Restore a matching layout when displays change, with a default layout for one display.
- **Native integration.** Keep macOS Spaces, Mission Control, gestures and manual desktop ordering. Access DeskPilot from the Dock, menu bar or keyboard.
- **Event-based updates.** Window and workspace events trigger reads. Startup retries are bounded; unresolved live windows can resume when their title or profile information changes.

Labels appear in DeskPilot and its menu bar. Apple's Mission Control labels are unchanged. Mission Control name overlays and their background checks are disabled in this build.

Desktop creation, switching and routing guards use macOS Mission Control. Discovery reads WindowManager first on macOS 27 and the Dock first on earlier systems. Empty or ambiguous accessibility trees do not authorize movement.

## Build

Requirements: an Apple Silicon Mac, macOS 14 or later, and Apple Command Line Tools.

```sh
sh build.sh
sh test.sh
open .build/DeskPilot.app
```

The build produces `.build/DeskPilot.app`, including standard and Retina icon sizes. The source is organized into `Sources/`, `Tests/`, `Resources/`, `Tools/` and `ThirdPartyNotices/`. The build packages validated PNG icon representations with a small Swift tool.

## Set up

1. Open DeskPilot and choose **Grant access**. On macOS 27, enable the app in **Privacy & Security → Device Control and Data Access**. Earlier macOS versions call this permission **Accessibility**. Return to DeskPilot to check access.
2. In **System Settings → Desktop & Dock**, disable automatic Space reordering and enable **Displays have separate Spaces**.
3. Choose **Enable automation** to assign your open standard windows and handle new windows automatically. **Organize now** runs the same assignment rules on demand.
4. Use **Share desktop** to explicitly add another app. Automatic side-by-side placement is enabled by default for two visible windows; you can disable it in Settings.
5. Save a layout for your laptop and mark it as the single-display default. Save another layout with external displays connected.

Closing the panel keeps DeskPilot running. **Quit DeskPilot** or **Command-Q** terminates the app. Only one instance can manage the same settings directory. Opening a different copy while one is running shows its version and location instead of silently appearing to launch the new copy.

Local builds use an ad hoc signature by default, so a rebuild can invalidate macOS privacy permissions. For repeated development builds, set `DESKPILOT_SIGNING_IDENTITY` to the name or hash of your existing code-signing identity and keep using the same certificate. This build option does not create a certificate or change privacy settings. If window access stops working after a rebuild, remove the existing permission entry and add the exact application you are running. **Show this app in Finder** identifies that file. Chrome catalog access is separate from window management access.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Control–Space | Open the quick summon and return picker |
| 1…9, while the picker is open | Bring the next window from that desktop |
| Escape, while the picker is open | Close the picker |
| Control–Option–Space | Show or hide the main panel |
| Control–Option–1…9 | Switch desktop |
| Control–Option–Shift–1…9 | Assign the focused app or Chrome profile to a desktop |
| Control–Option–Command–1…9 | Summon the next window from that desktop |
| Control–Option–Command–Delete (Backspace) | Return the focused summoned window home |
| Control–Option–Left / Right | Place the focused window on the left or right half |
| Control–Option–P | Pause or resume automation |
| Command-Q | Quit while DeskPilot is focused |

Desktop shortcut numbers are unique across all displays, following the display list and Space order shown in the panel and menu. The first nine regular desktops have number shortcuts; fullscreen Spaces are excluded. Assignments and names follow the Space's identity when it is reordered or moved to another display.

## Summon and return

Focus a window on the display where you want to work, then press **Control-Space**. Click a source desktop or press its number. The picker shows its captured destination and accepts the first click without activating DeskPilot or switching to its desktop. It stays open while moving a window, closes after a confirmed result, and displays failures in place. Disabled desktops explain whether they are the current destination, have no accessible windows, or need a Chrome profile choice. Refresh windows retries discovery. **Control–Option–Command–N** remains available as a direct advanced shortcut, where N is the source desktop number. Each press brings one more window; rapid presses queue in order. The first choice is the most recently focused eligible window, then the remaining windows. If multiple apps or Chrome profiles share the source desktop, their windows participate in the same sequence. Unknown Chrome profiles, fullscreen windows and windows on all Spaces are excluded. Once the source is empty, DeskPilot says there are no more windows instead of cycling windows back unexpectedly.

Two eligible windows from different apps or profiles are arranged side by side automatically when their shared destination is explicitly authorized. **Control–Option–Left / Right** remains available for manual placement. Focus any summoned window and press **Control–Option–Command–Delete** to return just that window. It restores the original size and minimized state without switching to the home desktop. A returned window becomes available for another summon. The panel provides **Summon next**, a list of **Summoned windows**, and individual **Return home** buttons.

The destination is the active desktop containing the focused window. With no focused application window, DeskPilot uses the display under the pointer. The destination must remain active; fullscreen destinations are refused. Moving between displays adapts the saved geometry to the destination's visible area.

Temporary moves are recorded before movement and survive restarting DeskPilot. Records contain window/process identifiers, the app's start time, the home Space identity and geometry; they do not store window titles. Closed windows and restarted apps lose their old records. Automation, Organize now and layout restoration exclude summoned windows; saving a layout keeps their home assignments and original geometry. **Move to** is an explicit permanent assignment for the whole app/profile and clears its temporary records after a successful move. An occupied destination is labeled **Share**. The permanent-assignment keyboard shortcut refuses an occupied destination and directs you to the explicit sharing control.

If the home desktop disappears, return stops with an explanation. It never substitutes another desktop with the same number. Reconnect the display or choose a new permanent home. If the original Space moves to another monitor, return follows its identity. Display changes and locking cancel queued commands. Movement, geometry and focus failures remain visible; a partial return retains its record so **Return home** can retry. Summon checks the actual focused window and WindowServer visibility on the active destination before reporting success, with a bounded settling period. An accepted move request by itself is insufficient.

## Assignment and focus behavior

Each application and each recognized Chrome profile receives its own desktop unless sharing is explicitly approved. Sharing consent is saved by desktop identity and group identifiers. Legacy assignments that place unrelated groups on one desktop without recorded consent are separated on the next organize or automation pass. Saved layouts preserve their explicit grouping when restored.

Dragging an individual window does not change its permanent assignment. While automation is enabled, DeskPilot returns it home. Use **Move to**, **Share desktop**, or **Summon next** for intentional moves. Moving or reordering an entire desktop in Mission Control preserves its assignments.

Focus follows the pointer uses mouse-move events, a throttled window hit test, and a short dwell. It has no repeating idle timer, does not capture screenshots, and refuses windows on inactive or fullscreen Spaces. Dragging, modifier keys, a visible active DeskPilot panel, and in-flight moves suppress it. **Settings → Activate windows under the pointer** disables the monitor.

Sharing or summoning can arrange exactly two visible recognized windows side by side. It does not continuously enforce geometry while you resize windows. Returning a summoned window restores its recorded original size; the resident window keeps its current size.

## Chrome profile matching

DeskPilot reads profile names and directory identifiers from Chrome's local profile catalog. Before reading Chrome's windows, it queries the application's accessibility role. Chromium uses this request to initialize its native accessibility interface; reading the window list alone can leave profile information unavailable. DeskPilot then checks the window and its native root containers, with a depth and node limit. It does not request VoiceOver mode or descend into page content, tabs or toolbars. With one regular Chrome profile, Chrome can omit the profile suffix; DeskPilot handles that case. Profile names with Unicode formatting or nonbreaking spaces are normalized before matching.

Incognito, guest windows, duplicate profile names and conflicting identity information are not assigned by guessing. If Chrome does not expose enough information, use **Choose profile…**. An explicit choice takes priority for that window and immediately queues it for assignment when automation is enabled. No tabs are detached, and page contents are not traversed to identify a profile.

Names are matched according to Chromium's [accessible window title](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/views/frame/browser_view.cc) and [native accessibility activation](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/chrome_browser_application_mac.mm) behavior. Matching and routing regressions are covered by local tests with synthetic windows and profiles. Diagnostics shows separate counts for profiles in the catalog, native Chrome windows found, and windows with a known profile. Browser tabs are not counted as profiles.

If the catalog cannot be read, Diagnostics shows **Unavailable** and the actual file error, rather than claiming there are zero profiles. Choose **Connect Chrome profiles…** and select `~/Library/Application Support/Google/Chrome/Local State` in the system file picker. The picker is attached to the app window, and Diagnostics distinguishes waiting, cancellation, selection failure and success. DeskPilot validates the catalog before replacing a previous connection and saves a file bookmark for future launches.

DeskPilot retains only profile names and directory identifiers already read with permission, never the full catalog. If a later read fails, these entries are marked **saved**; matching then requires an explicit profile suffix or a manual choice. It never assumes a sole saved profile is Chrome's only current profile. An unavailable saved bookmark requests reconnection instead of silently reading a different catalog. Failed reads are retried at most every 30 seconds when window events occur, and **Refresh and check access** retries immediately. Discovery runs even when macOS temporarily fails to expose its desktops.

The app includes Apple's [other-application-data purpose message](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappdatausagedescription) to explain its use of profile metadata when macOS asks for access. The purpose message does not grant access or repair a permission invalidated by a changed code signature.

**Refresh and check access** updates the local runtime report with counts, file-read status and event types, without page titles or URLs. Per-app discovery counters report native window-read errors, missing IDs, rejected nonstandard windows and accepted window counts. The last window-operation results distinguish position, resize and activation failures; they add no window titles or page contents. Completed operations and automation toggles also write their result, pause reason and last detected Mission Control host. Meaningful changes in the routing queue, readable windows and Mission Control waiting state update the report automatically. Counter changes alone do not trigger disk writes. Activating DeskPilot's own panel is excluded from managed-window events.

## Reliability and privacy

- A desktop assignment is saved only after macOS confirms the window's destination.
- Locking the Mac or changing displays cancels in-flight work without disabling automation. After displays settle or the session resumes, open windows are queued again even when automatic layout restoration is off.
- A failed automatic creation or movement pauses automation and preserves the reason across panel activation and app restart. Enabling automation explicitly clears the previous reason. Retrying a failed move reuses the desktop already created in that session.
- Late native window IDs, delayed Chrome titles and windows created while another operation is running stay queued until they can be processed. Existing windows whose Accessibility records first appear after automation is enabled also enter the queue, even if WindowServer already listed their IDs at startup.
- Saved names take priority over temporary window titles. Clearing a custom name restores the app or profile name.
- Settings stay on this Mac. No screenshots are captured and no network service is used by the app. Layouts store window-title hashes rather than full titles or tab URLs.
- Settings are stored in `~/Library/Application Support/DeskPilot Native/state.json`. Invalid settings files are preserved rather than overwritten.

## Verification and limitations

Version 0.3.5 is a development build. See [VERIFICATION.json](VERIFICATION.json) for the exact checks and remaining manual tests.

The local suite includes policy tests and tests of the real routing engine against a simulated desktop service. It covers desktop creation, app and Chrome grouping, late metadata, busy queues, failure recovery and automatic/custom names. These tests do not substitute for a live multi-display test.

Space management uses private macOS functions and Accessibility. Compatibility must be checked after macOS updates. Standard windows and regular desktops are managed; native fullscreen and windows on all Spaces are excluded. Closed documents and tabs are not recreated. Desktops are never automatically deleted.

Useful diagnostics:

```sh
.build/DeskPilot.app/Contents/MacOS/DeskPilotNative --diagnose
.build/DeskPilot.app/Contents/MacOS/DeskPilotNative --verify-move
```

`--diagnose` only reads system capabilities. `--verify-move` creates its own temporary window, moves it between two existing regular desktops, checks the destination and return, then closes it. It requires window management access. A tool-launched diagnostic process can have a different permission context from the normally opened app; verify access in the actual app as well.

`--data-dir /path` isolates settings for development. `--background` starts with the panel hidden, and `--smoke` exits after three seconds.

Third-party attribution and license notices are retained in [ThirdPartyNotices](ThirdPartyNotices).
