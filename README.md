# gmail-gtd

A native macOS Gmail client built around Getting Things Done. Google Workspace only.
Triage suggestions and summaries run on-device with Apple Foundation Models by default.
Optional Jev categorisation sends email text to TypeSafe only after explicit opt-in.

- `GmailGTD`: SwiftUI app: a Today dashboard, a three-pane inbox/bucket view, a Projects section, AI suggestions, and Open in Gmail on every thread
- `gtd`: CLI sharing the same core, including an interactive `gtd process`
- `GTDCore`: auth, Gmail REST client, label manager, triage

GTD buckets are Gmail labels: `GTD/Next Action`, `GTD/Waiting For`, `GTD/Someday`,
`GTD/Reference`, `GTD/Project`, `GTD/Noise` (bulk mail you probably never need; a denoise and trash step is planned), `GTD/Done`. Every thread ends in one of these, so nothing disappears into an unlabelled archive. Filing swaps the GTD label and keeps Next Action, Waiting For and Someday in the Gmail Inbox,
returning previously archived threads to the Inbox too. Reference and Noise are archived (not deleted)
and remain searchable under their GTD labels. Project and Done keep their existing archive behaviour.
These rules apply when filing a thread; existing mail is not bulk-migrated.

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

To build and install to `~/Applications` in one step (it quits a running copy first, replaces it, and launches):

```sh
scripts/install.sh               # release build, install, launch
scripts/install.sh --no-open     # install without launching
scripts/install.sh --debug       # faster debug build
```

`GmailGTD --check-config` prints whether the app can see a saved client ID and Keychain tokens (never the values), which is the first thing to run if a built app says it isn't signed in.

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

## Optional Jev and custom categorisation prompts

Open **Categorisation Settings…** (⌘, or the toolbar). Local-only remains the default.
You can edit and independently reset the local and Jev classification prompts. Saving a changed
local prompt invalidates cached classifications; summary and project-planning prompts are unchanged.

To use Jev, enter a TypeSafe API token and explicitly enable the toggle. The token is stored in a
separate Keychain item, never UserDefaults. Clear the token field and save to delete it. Disabling
Jev stops new provider calls; an already-sent request cannot be recalled and its result is discarded.
Sign-out clears in-memory results but retains provider settings/token, like the saved OAuth client
configuration. Turning Jev off restores local-only approval immediately.

**Privacy/cost:** when enabled, on-screen threads in Inbox, Next Action and Waiting For are sent
automatically to TypeSafe, including sender, subject and message text (not attachments). API charges
may apply. Demo mode follows the same opt-in using fictional mail. Nothing is filed automatically.
The detail pane identifies both sources; **Approve** (also **A**) uses Jev whenever enabled, including
when the local model is unavailable. If Jev is pending, fails, lacks a token or returns an invalid
category, approval stays disabled—there is no silent local fallback. Use Retry/Regenerate, fix Settings,
disable Jev, or choose a bucket manually. The CLI's `suggest` and `process` share these settings and policy;
configure the token/prompts in the app. Summaries, digests and project plans remain on-device.

Integration uses [TypeSafe System One](https://docs.typesafe.ai/introduction/quickstart),
a Bearer-authenticated `POST https://api.typesafe.ai/v1/systemone` with a single typed Choice question
and the pinned model `jev-1.14.0`. It returns a GTD category, not generated summaries/actions.
The [documented standard limits](https://docs.typesafe.ai/models) are 64k tokens per request and
32k per question (email state + instructions + criteria). No experimental long-context header is used.
Local prompts allow 2,000 UTF-8 bytes alongside the existing 6,000-character thread budget; Jev
prompts allow 24,000 UTF-8 bytes with a **30,000-byte complete JSON request cap**. This deliberately
conservative byte budget avoids assuming a tokenizer ratio; it is not a claim to use the full provider
window. Jev keeps newest email first and trims older content to the remaining budget. Over-limit/empty
prompts are rejected with an error, never silently truncated. HTTP errors expose only status/actionable
advice, not provider response bodies that might contain mail or credentials.

### Verification

On macOS 26 with Xcode/Swift 6:

```sh
swift build
swift test
```

The PR test workflow runs both on a macOS 26 runner. Jev tests inject mocked HTTP transport and never
need a token or send real email. A live smoke test is optional: opt in with your own token and sample
mail, verify both categories, press Approve, then disable Jev and verify local-only approval.

## Notes

- Moves are instant: the thread leaves the list and a small toast (not a system notification) confirms it, while
  Gmail is updated in the background. If Gmail refuses, the thread comes back with an error. After 15 seconds of
  inactivity the list quietly refreshes to match Gmail. Every move can be undone with `⌘Z`, up to the last 20;
  undo restores exactly the labels the thread had, and leaves unread and starred alone.

- Lists load 50 threads at a time and fetch the next page as you near the end, so you can scroll back as far
  as the folder goes (the title bar shows how many are loaded, with a `+` while there are more). Demo mail pages
  in steps of 8 so you can see it happen. Today shows the 12 newest Next Actions and Waiting For, with links to the full lists.

- Gmail bills every request against a per-user quota, so the app fetches each thread once and shares it
  between the list, the open thread and the model, only loads headers for rows on screen, and backs
  off and retries if Google rate-limits it. Refresh clears the cache.

- Requires macOS 26+ for Foundation Models. Threads are trimmed to fit the small on-device
  context window.
- The model runs automatically on the open inbox thread, but nothing is filed until you accept.
- Compose and reply aren't built yet; use Open in Gmail.
- Keys in the app: `1`-`7` file into a bucket, `0` back to inbox, `⌘1`-`⌘7` go to a bucket, `⌘0` Inbox, `⌘T` Today, `⌘Z` undo the last move, `A` accept, `E` done (finished with it), `R` regenerate, `O` open in Gmail. Hold `⌘` for the full list. Suggestions generate automatically for the open inbox thread (and plans for projects); Regenerate re-runs one.
