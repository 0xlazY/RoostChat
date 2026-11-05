# Getting RoostChat onto an iPhone

There are two routes. Start with the free one.

| | Free Apple ID + SideStore | Paid account + AltStore PAL |
| --- | --- | --- |
| Cost | Free | Developer Program membership |
| Who can install | You | Anyone in a supported region |
| Signature lifetime | 7 days, refreshed from the phone | No weekly refresh |
| Apple review | None | Notarization |
| Computer needed | Once, for setup | No |

AltStore PAL can't install this app with a free account. Everything it installs must be
notarized by Apple, and notarization needs a paid membership. SideStore signs apps with
your own Apple ID on the phone, so no notarization is involved.

## Route 1: free Apple ID with SideStore

From Linux, using [iloader](https://iloader.app/):

1. Install `usbmuxd` and iloader, then connect the iPhone by USB and trust the computer.
2. In iloader, sign in with your Apple ID, select the phone and install SideStore. A
   secondary Apple ID is a sensible precaution.
3. On the iPhone, enable Developer Mode if asked, then trust your Apple ID under
   Settings > General > VPN & Device Management.
4. Install LocalDevVPN from the App Store, connect it, open SideStore, sign in, and
   refresh once.
5. Download `RoostChat.ipa` from the GitHub Actions run or the release page, save it to
   Files, then in SideStore go to My Apps > + and pick it.

Limits of a free account: signatures last 7 days, three sideloaded apps at once
(SideStore counts as one), and ten new App IDs per week. Keep SideStore refreshing before
the 7 days run out. LocalDevVPN uses the iOS VPN slot, so it can conflict with another VPN.

## Route 2: paid account

### Upload to App Store Connect

1. Register a Bundle ID in your developer account, and create the app in App Store Connect.
2. Create an App Store Connect API key with the App Manager role.
3. Add these GitHub repository secrets:

   | Secret | Value |
   | --- | --- |
   | `APPLE_TEAM_ID` | Your 10-character team ID |
   | `ASC_KEY_ID` | The API key's ID |
   | `ASC_ISSUER_ID` | The API key's issuer ID |
   | `ASC_KEY_P8` | The full contents of the `.p8` file |

4. Add a repository variable `BUNDLE_ID` if yours differs from `io.github.lazy.roostchat`.
5. Run the **Upload to App Store Connect** workflow from the Actions tab.

The build is then available on TestFlight, which is the simplest way to test with a paid
account. Run the workflow once and test there before going further.

### Publish through an AltStore PAL source

Follow AltStore's current guide at [developer.altstore.io](https://developer.altstore.io/).
In outline:

1. Accept the alternative distribution terms and connect your developer account to AltStore.
2. In App Store Connect, make the app eligible for alternative distribution and submit
   it with the review type **Notarization**.
3. Once accepted, download the Alternative Distribution Package and host it.
4. Publish a `source.json` describing the app, then add it to PAL with
   `altstore://source?url=<your source URL>`.

Before submitting, review the **Stay connected in background** feature. It plays silent
audio through the audio background mode, which Apple's review may reject. Replacing it
means removing `UIBackgroundModes` from `project.yml` and adding push notifications.

Check before committing to this route: PAL is only available in certain regions, Apple
may charge a commission under its alternative terms, and the source code must be public
under the AGPL.
