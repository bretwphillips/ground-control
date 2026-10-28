# Ground Control

A macOS menu bar app for working on one screen. Your focus app gets the whole
screen except a thin strip, and every other app circles in that strip until you
need it, without swiping between desktops.

## Vocabulary

- **The pattern**: the strip along one edge (top by default) where apps wait, with their Dock badges.
- **Landing**: click an app in the strip and it comes forward, filling the screen beside the strip.
- **Fly-by** *(planned)*: when a chat app's badge becomes a number (a mention or DM), a live
  preview slides out of the strip for a few seconds without taking focus. Click it to land
  that app, or ignore it and it climbs back up.
- **Ground stop** *(planned)*: do not disturb.

Chat apps generally show `•` for plain unreads and a number for mentions and DMs,
so only numbers will trigger a fly-by.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
scripts/bundle.sh
open "build/Ground Control.app"
```

On first launch, grant Accessibility access in System Settings → Privacy & Security.
Ground Control needs it to move windows and to read Dock badges; until then the strip
shows a warning that opens that pane.

Run `scripts/make-cert.sh` once first: it adds a self-signed "Ground Control Dev"
signing identity to your login keychain, and builds signed with it keep the
Accessibility grant. Without it builds are ad-hoc signed and macOS forgets the grant
on every rebuild (remove the old entry and add the new one).

## Settings

The airplane in the menu bar sets the strip's edge (top, bottom, left, right) and
picks which apps appear in the strip (or right-click a tile → Hide from Strip). Windows are kept out from under the strip: any window that reaches under it is trimmed to the space beside it.
