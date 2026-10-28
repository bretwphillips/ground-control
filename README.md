# Ground Control

A macOS menu bar app for working on one screen. Your focus app gets the whole
screen except a thin strip, and every other app circles in that strip until you
need it, without swiping between desktops.

## Vocabulary

- **The pattern**: the strip along one edge (top by default) where apps wait, with their Dock badges.
- **Landing**: click an app in the strip and it comes forward, filling the screen beside the strip.
- **Gate**: a saved tiling of apps, built in place. Click **+** in the strip (or New Gate… in
  the menu): other apps hide, and a see-through overlay covers the space beside the strip.
  Drag apps in from the strip (it lists every app while you build); dropping on an edge of an
  app splits it that way, so columns and rows nest into any pattern. Drag the borders to
  resize, and × removes an app. With Accessibility each app's real window follows its zone as
  you go; Cancel puts them back. Clicking a gate, or pressing ⌃⌥1 to ⌃⌥9, puts each window in
  its spot and brings them forward, launching any app that isn't running. Right-click a gate to
  edit or delete it. Apps in a gate leave the strip's app list.
- **Shortcuts**: ⌃⌥1 to ⌃⌥9 open gates 1 to 9, ⌃⌥[ and ⌃⌥] step to the gate on either side
  (wrapping around), ⌃⌥Tab flips back to the gate before, and ⌃⌥` / ⌃⌥⇧` switch to the next or
  previous app in the open gate, and ⌃⌥\\ answers a fly-by (or the last app to call in the past
  minute) without clicking. (⌃⌥ with the arrows is left to window snappers like Magnet.)
- **Fly-by**: when an app's badge gains a number (a mention or DM), its tile pulses and a live
  preview of its window floats in a corner for a few seconds without taking focus. Click it to land that app,
  or ignore it and it goes away. Each app gets
  at most one a minute.

Chat apps generally show `•` for plain unreads and a number for mentions and DMs,
so only numbers start a fly-by.

## Permissions

Ground Control works with no permissions: the strip hides until you push the pointer to its
edge, shows badges, switches apps, and pulses a tile when a mention arrives. Each permission
adds to that, and Settings explains what it's for next to the feature that uses it.

- **Accessibility**: the strip keeps its own slice of the screen (windows are kept out from
  under it), landed apps are sized to fit, and gates put windows back in place. Without it,
  a gate only brings its apps forward.
- **Screen Recording**: window previews on the Large strip, and the live preview in fly-bys.

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
