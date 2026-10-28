# Ground Control

A macOS menu bar app for working on one screen. Your focus app gets the whole
screen except a thin strip, and every other app circles in that strip until you
need it, without swiping between desktops.

## Vocabulary

- **The pattern**: the strip along one edge (top by default) where apps wait, with their Dock badges.
- **Landing**: click an app in the strip and it comes forward, filling the screen beside the strip.
- **Fly-by**: when an app's badge gains a number (a mention or DM), its tile pulses and its real
  window slides into a corner for a few seconds without taking focus. Click it to land that app,
  or ignore it and it returns to where it was. It waits for a pause in typing, and each app gets
  at most one a minute.

Chat apps generally show `•` for plain unreads and a number for mentions and DMs,
so only numbers start a fly-by.

## Permissions

Ground Control works with no permissions: the strip hides until you push the pointer to its
edge, shows badges, switches apps, and pulses a tile when a mention arrives. Each permission
adds to that, and Settings explains what it's for next to the feature that uses it.

- **Accessibility**: the strip keeps its own slice of the screen (windows are kept out from
  under it), landed apps are sized to fit, and fly-bys move the real window.
- **Screen Recording**: window previews on the Large strip.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
scripts/bundle.sh
open "build/Ground Control.app"
```

Run `scripts/make-cert.sh` once first: it adds a self-signed "Ground Control Dev" signing
identity to your login keychain and trusts it for code signing (asks for your password).
macOS ties permissions to that identity, so they survive rebuilds; without it builds are
ad-hoc signed and every rebuild has to be granted again. When codesign first asks to use
the key, choose Always Allow.

## Settings

Open Settings from the airplane in the menu bar: the strip's edge and size (icons, icons and
names, or large tiles with optional previews), keeping windows clear, fly-by behaviour, and
which apps appear in the strip. The menu also has **Preview a Fly-by**, which plays one for
the chosen app after three seconds.
