# gmail-gtd

A native macOS Gmail client built around Getting Things Done. Google Workspace only.
Triage suggestions and summaries run on-device with Apple Foundation Models, so no mail
content goes to a cloud model.

- `GmailGTD`: SwiftUI app (inbox, GTD buckets, thread view, AI suggestions)
- `gtd`: CLI sharing the same core, including an interactive `gtd process`
- `GTDCore`: auth, Gmail REST client, label manager, triage

GTD buckets are Gmail labels: `GTD/Next Action`, `GTD/Waiting For`, `GTD/Someday`,
`GTD/Reference`, `GTD/Project`. Filing a thread archives it from the inbox and swaps the
label, so it works in the Gmail web UI too.

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

- Requires macOS 26+ for Foundation Models. Threads are trimmed to fit the small on-device
  context window.
- Suggestions are never applied automatically; accept them with a keypress.
- Keys in the app: `1`-`5` file into a bucket, `0` back to inbox, `⌘S` suggest.
