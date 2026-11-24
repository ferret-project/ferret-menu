# Ferret Menu

[Ferret](https://github.com/ferret-project/ferret) in your Mac's menu bar: find anything you own, see what needs
doing, ask about your things, and add new ones by dropping their photos and receipts on the paw.

- **Search** with ⌃⌥⌘F from any app (change it in Settings): by name, brand, what it's for, or what's in its photos
  and documents. ↑ ↓ and Return open a thing in Ferret; right-click copies where it is or a link to it.
- **The bell**: warranties ending, maintenance due, recalls and the rest of Ferret's bell. The paw shows how many are
  urgent, and macOS tells you when something new becomes urgent. Mark maintenance done (when, a note, what it cost,
  the counter's reading) or a loan returned right there.
- **Shopping list**: what's run out or running low. **Bought** adds to its count (with Undo); **Copy List** for the
  shop.
- **Ask Ferret**: "how often should I descale the kettle?" answered from your things and their manuals, with where
  the answer came from (when your Ferret has an AI model).
- **Add**: a name and a place, plus any photos, receipts or manuals: drop files on the paw, on the Add screen, or on
  a thing in the search results to add them to it. Everything else is filled in in Ferret.

Things open in your browser, in Ferret itself, where your own sign-in is. ⌘1, ⌘2… switch between the screens.

## Signing in

Ferret Menu signs in through your Ferret's own sign-in page: you pick the household and whether it may add and
change things (or only search and ask). It never sees your password and takes no API keys. Each Mac shows up in
Ferret under **Settings → Claude & API → Connected apps**, where you can disconnect it; signing out of Ferret Menu
ends its sign-in on the server too. The sign-in is kept in your Mac's Keychain.

Works with the hosted Ferret and your own: type its address (`ferret.example.com`). An address is HTTPS unless you
type `http://`, so a Ferret on plain HTTP on your home network is `http://192.168.1.20:8787`. A Ferret behind Cloudflare Access needs a service token (under **Cloudflare Access** on the sign-in
screen).

Needs **macOS 26** and **Ferret 2026.11.28 or newer**.

## Installing

Download `Ferret-Menu.zip` from [Releases](https://github.com/ferret-project/ferret-menu/releases), unzip it and move
**Ferret Menu** to Applications.

Ferret Menu isn't notarized by Apple, so the first time macOS says it can't check it. Open it once with
**System Settings → Privacy & Security → Open Anyway** (after trying to open it), or in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Ferret Menu.app"
```

Or build it yourself (below): a build of your own opens without any of that.

**Updates** come by themselves: once a day Ferret Menu looks at its latest release and offers the update in its
window (or **More → Check for Updates…**). Turn on **Settings → Install updates automatically** to have them download
in the background and install the next time Ferret Menu quits. Updates install only when they're signed with Ferret
Menu's update key ([Sparkle](https://sparkle-project.org)), and only the first install needs Open Anyway.

After an update, macOS may ask once whether Ferret Menu may use its saved sign-in in your Keychain: choose
**Always Allow**. (Until Ferret Menu is signed with an Apple Developer ID, macOS treats each version as a new app.)

**Can't see the paw?** On a Mac with a notch, a full menu bar hides the newest icons. ⌃⌥⌘F still opens Ferret Menu
(from the middle of the menu bar), or make room by ⌘-dragging other icons out of the menu bar.

## Building

Needs Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/ferret-project/ferret-menu
cd ferret-menu
xcodegen
open FerretMenu.xcodeproj   # or:
xcodebuild -scheme FerretMenu -configuration Release -derivedDataPath build build
```

The app is `build/Build/Products/Release/Ferret Menu.app`. Tests: `xcodebuild -scheme FerretMenu test`.

Releases: `scripts/release.sh <version>` builds the zip and the signed update feed into `dist/`; a `v<version>` tag
runs it on GitHub (`.github/workflows/release.yml`), which also signs with a Developer ID and notarizes once those
secrets are set.

Talking to Ferret (sign-in, the API, the Keychain) is [FerretKit](https://github.com/ferret-project/ferret-kit),
shared with Ferret's other Apple apps.

Debug builds can be driven from a script for checking changes without clicking (`scripts/drive.swift`,
`FerretMenu/Support/DebugHooks.swift`); release builds leave that out.

## Privacy

Ferret Menu talks to your Ferret server, and once a day asks GitHub whether there's a newer Ferret Menu (nothing
about you or your Ferret is sent; switch it off in Settings). It keeps the sign-in in the Keychain and a few settings
on your Mac, and nothing else: no analytics, no crash reports.

MIT licensed.
