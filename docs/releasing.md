# Releasing

Installed copies follow **tagged releases** only: merges to `main` reach no one until a release
is made, and a release is made only when it's decided to make one.

1. On an up-to-date `main`, set the new version as `CFBundleShortVersionString` in
   `Resources/Info.plist` (and bump `CFBundleVersion`), and commit it.
2. Tag it and push both: `git tag v0.2.0 && git push origin main v0.2.0`.
3. Publish the release, with notes on what's new:
   `gh release create v0.2.0 --title "Ground Control 0.2.0" --notes-file notes.md`.

Installed copies see it within a day, or on **Check for Updates…**. Updating fast-forwards the
installed clone to the tag, rebuilds with `scripts/bundle.sh` and relaunches.
