# Ground Control

A macOS menu bar app for working on one screen. Instead of swiping between desktops, the apps you
use sit together in **gates** you build yourself, everything else circles in your **airspace**
along one edge, and what needs you flies by without taking your focus.

## Why

On one screen, every app you use is either covering another or a desktop swipe away. The usual
fixes trade one problem for another: full-screen apps mean swiping between desktops all day, and
tiling everything leaves each app too small to use. Meanwhile chat apps pull your focus whether
the message matters or not.

Ground Control keeps the apps you're working with arranged together, everything else one glance
away, and only lets interruptions through when they're worth it: a mention that's urgent, a build
or Claude task that's finished, never in the middle of a sentence or a call.

## What it does

- **Airspace**: the apps you're not looking at, circling along one edge (top by default) until
  they're needed, with their Dock badges coloured and shaped by urgency: **!** red for urgent, a
  number in orange for mentions and DMs, ✓ green for a terminal that finished, a blue dot for plain
  unreads. Hover a tile for a larger preview. It can hide until you need it.
- **Gates**: saved tilings of apps. Click **+** in the airspace: other apps hide and a see-through
  overlay covers the screen. Drag apps in from the airspace; dropping on an edge of an app splits it
  that way, so columns and rows nest into any pattern, and each real window follows its zone as you
  build. Opening a gate puts every window in its spot, restoring minimized and full-screen ones and
  launching apps that aren't running. While a gate is open its windows only resize together, by the
  handles on the seams between them, and the app you're using grows a little (**squish**).
  Right-click a gate to edit, park or delete it; drag it to reorder. Parked gates sit apart at the
  end of the airspace for things you need now and then: a click opens them, but swipes, step keys
  and number shortcuts pass them by.
- **Fly-bys**: when something needs you, a live preview of its window floats in a corner for a few
  seconds without taking focus. Click it or press ⌃⌥M to open its gate. What counts is a setting:
  every notification, mentions/DMs/urgent (the default), or only urgent, where urgent means a
  notification mentions one of your words or people, or mentions pile up. A terminal that was busy
  and goes still (Claude finishing a task, a build ending) flies by too.
- **Holding pattern**: fly-bys wait while you're focused (two minutes in one app, typing) and
  during calls (microphone or camera on), and come at the next break. Urgent ones never wait.
- **Suggestions**: switch back and forth between two apps often and the airspace offers to make them
  a gate.
- **Show Desktop** hides everything to reach the desktop, then returns to the gate you were in.

## Shortcuts

Hold ⌃⌥ to see every key where it applies. ⌃⌥1 to ⌃⌥9 open gates by their place in the airspace; the
rest can be changed in Settings → Shortcuts:

| | |
|---|---|
| ⌃⌥H / ⌃⌥L | gate to the left / right, wrapping around |
| ⌃⌥Tab | back to the last gate |
| ⌃⌥N / ⌃⌥⇧N | next / previous app in the open gate |
| ⌃⌥M | answer the fly-by |
| ⌃⌥0 | show the desktop |

The defaults keep clear of the ⌃⌥ keys window snappers like Magnet use. A three-, four- or five-finger
swipe can switch gates too (Settings → Gates); with more than one desktop, move macOS's own swipe
for that many fingers in Trackpad settings.

## Permissions

Ground Control works with none: the airspace hides until the pointer reaches its edge, shows badges,
switches apps and pulses a tile when something needs you. Each permission adds to that, and
Settings says what it's for next to the feature that uses it.

- **Accessibility**: moving and resizing windows (gates, keeping the airspace clear) and reading
  notification banners to tell what's urgent. Their text stays on your Mac.
- **Screen Recording**: window previews in the airspace, the hover peek and fly-bys, and noticing a
  terminal go quiet.

## Install

Requires macOS 14 or later and Apple's Swift tools. If you don't have Xcode, the Command Line
Tools are enough: run `xcode-select --install` and follow the prompt.

```sh
git clone https://github.com/bretwphillips/ground-control.git
cd ground-control
scripts/make-cert.sh        # once: a signing identity so permissions survive updates
scripts/bundle.sh
open "build/Ground Control.app"
```

`make-cert.sh` adds a self-signed "Ground Control Dev" identity to your login keychain and trusts
it for code signing (it asks for your password). macOS ties permissions to that identity, so they
carry over when the app is rebuilt. When codesign first asks to use the key, choose Always Allow.

## Updates

Ground Control follows tagged releases. Once a day, and from **Check for Updates…** in the menu,
it asks GitHub for the latest release; updating moves your clone to it, rebuilds and relaunches.
A clone with changes of its own, or not on `main`, is left alone. See
[docs/releasing.md](docs/releasing.md) for making a release.

## License

MIT, see [LICENSE](LICENSE).
