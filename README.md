# gmail-gtd

A native macOS Gmail client built around Getting Things Done. Google Workspace only.
Triage suggestions and summaries run on-device with Apple Foundation Models, so no mail
content goes to a cloud model.

- `GmailGTD`: SwiftUI app: a Today dashboard, a three-pane inbox/bucket view, a Projects section, AI suggestions, and Open in Gmail on every thread
- `gtd`: CLI sharing the same core, including an interactive `gtd process`
- `GTDCore`: auth, Gmail REST client, label manager, triage

GTD buckets are Gmail labels: `GTD/Next Action`, `GTD/Waiting For`, `GTD/Someday`,
`GTD/Reference`, `GTD/Project`, `GTD/Noise` (bulk mail you probably never need; a denoise and trash step is planned). Filing a thread archives it from the inbox and swaps the
label, so it works in the Gmail web UI too.

## Demo mode

No Google account or sign-in needed. Demo mode loads a fictional mailbox (20 inbox threads plus
filed Next Actions, Waiting For, Projects, Someday and Reference) and every action works:
filing, archiving, completing, un-filing and Open in Gmail (which shows the link instead of
opening it). The on-device model runs on the sample mail like it would on real mail.
Everything lives in memory, so relaunching resets it.

```sh
swift run GmailGTD --demo        # or press "Try Demo" on the sign-in screen
swift run gtd --demo process     # CLI; each command starts from a fresh mailbox
```

## Building the app

`swift run` gives a bare executable. Its Dock icon is drawn at launch, but it isn't a real app. To build
a proper `GmailGTD.app` with an icon you can double-click or drag to Applications:

```sh
scripts/make-app.sh            # release build, writes build/GmailGTD.app
scripts/make-app.sh debug      # faster, for development
open build/GmailGTD.app --args --demo
```

The icon is drawn in code (`Sources/GmailGTD/AppIcon.swift`); the script asks the app to export it and
turns it into an `.icns`. The bundle is ad-hoc signed, which is enough to run on this Mac. Sharing it
with other Macs would need a Developer ID signature and notarisation.

## Setup

1. In Google Cloud (inside your Workspace org), create a project and enable the **Gmail API**.
2. OAuth consent screen: user type **Internal**, scope `https://www.googleapis.com/auth/gmail.modify`.
3. Create an OAuth client of type **Desktop app**.
4. If API controls restrict third-party apps, have a Workspace admin trust the client.

Sign in with the client ID (and secret, if shown). Tokens go in the Keychain and are shared
by the app and the CLI.

```sh
swift run GmailGTD                                  # app: enter client ID on first launch
swift run gtd login --client-id <ID> --client-secret <SECRET>
swift run gtd setup                                 # create GTD/* labels
swift run gtd process                               # walk the inbox
```

`GMAIL_GTD_CLIENT_ID` / `GMAIL_GTD_CLIENT_SECRET` also work.

## Notes

- Gmail bills every request against a per-user quota, so the app fetches each thread once and shares it
  between the list, the open thread and the model, only loads headers for rows on screen, and backs
  off and retries if Google rate-limits it. Refresh clears the cache.

- Requires macOS 26+ for Foundation Models. Threads are trimmed to fit the small on-device
  context window.
- The model runs automatically on the open inbox thread, but nothing is filed until you accept.
- Compose and reply aren't built yet; use Open in Gmail.
- Keys in the app: `1`-`6` file into a bucket, `0` back to inbox, `⌘1`-`⌘6` go to a bucket, `⌘0` Inbox, `⌘T` Today, `A` accept, `E` archive (finished with it), `R` regenerate, `O` open in Gmail. Hold `⌘` for the full list. Suggestions generate automatically for the open inbox thread (and plans for projects); Regenerate re-runs one.
