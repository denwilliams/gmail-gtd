# gmail-gtd

A native macOS and iPhone Gmail client built around Getting Things Done. Google Workspace only.
Triage suggestions and summaries run on-device with Apple Foundation Models by default.
Optional Jev categorisation sends email text to TypeSafe only after explicit opt-in.

- `GmailGTD`: SwiftUI app: a Today dashboard, a three-pane In-tray/status view with label filters, a Projects section, AI suggestions, and Open in Gmail on every thread
- `iOS/`: the iPhone app, sharing the Mac app's model (see [iPhone app](#iphone-app))
- `gtd`: CLI sharing the same core, including an interactive `gtd process`
- `GTDCore`: auth, Gmail REST client, label manager and label filters, triage

## Labels

Every thread is described by five label families, all ordinary nested Gmail labels. The older `GTD/*`
labels are ignored.

| Family | Gmail labels | Per thread | Managed by |
|---|---|---|---|
| 🚦 Status | `🚦/In-tray`, `🚦/Next Action`, `🚦/Waiting For`, `🚦/Someday`, `🚦/Reference`, `🚦/Project`, `🚦/Noise`, `🚦/Junk` | exactly one | the app: sidebar and number keys |
| 🗂️ Classification | `🗂️/Newsletters`, `🗂️/Notifications`, `🗂️/Personal`… | one (or none) | Gmail filters; dropdown in the app |
| 🏢 Source | `🏢/AWS`, `🏢/Internal`, `🏢/Vendor`… | one (or none) | Gmail filters; dropdown in the app |
| 🏷️ Tags | `🏷️/Hiring`… | any number | menu in the app |
| 🎯 Projects | `🎯/Data Warehouse`… | any number | menu in the app |

### Status

**In-tray** is the processing queue (the app's name for what used to be its Inbox view, so it is not
confused with Gmail's Inbox). The In-tray view lists only threads labelled `🚦/In-tray`, so Gmail
filters decide what lands there. Filing with `1`–`7` swaps the status label:

| Key | Status | Gmail Inbox |
|---|---|---|
| `0` | In-tray | kept in Inbox |
| `1` | Next Action | kept in Inbox |
| `2` | Waiting For | kept in Inbox |
| `3` | Someday | kept in Inbox |
| `4` | Reference | archived |
| `5` | Project | archived |
| `6` | Noise | archived |
| `7` | Junk | archived |

Filing removes In-tray, Backlog and any other status, and adds or removes INBOX as above, returning
previously archived threads to the Inbox when needed. Nothing is ever trashed or deleted: Noise and Junk
are archived and stay searchable under their labels. There is no Done status: **Done** (`E`, or ticking a
Next Action on Today) files the thread as Reference. `0` puts a thread back in the In-tray and the Gmail
Inbox. The app creates any missing 🚦 status labels and `🚦/In-tray` on first connect. Existing mail is
not bulk-migrated.

### Classification, Source, Tags and Projects

The app discovers these from Gmail by their emoji prefix (with or without the emoji variation selector),
so a label you add in Gmail appears after the next Refresh. It never creates, renames or deletes them.

- **Above the open thread**: dropdowns for 🗂️ Classification and 🏢 Source (one each, or none) and menus
  for 🏷️ Tags and 🎯 Projects (tick any number). Changes appear at once and are written to Gmail in the
  background. They never change the thread's status or Inbox placement, and they are not part of `⌘Z`
  undo, which covers moves only.
- **Under each list row**: the thread's Classification, Source, Tags and Projects, where known.
- **In the toolbar**: a filter menu per family. Ticking several options in one menu matches any of them
  (OR); filters in different menus must all match (AND). Classification and Source also offer **None**,
  for mail no filter has labelled. Filters apply to every mail list (not Today or Corrections), stay set
  as you move between statuses, and are sent to Gmail as a search query, so paging works as normal.
  🎯 Projects are independent of the 🚦 Project status.

## Backlog

To keep the In-tray for new mail, manually apply the Gmail label **🚦/Backlog** to old mail (in place
of `🚦/In-tray`) and archive it in Gmail. Open **Backlog** in the sidebar (or the Go menu) to triage that
archived mail with the same status buttons, suggestions, approval and `1`–`7` shortcuts as the In-tray.
Backlog is a processing queue, not a filing destination. If the label does not exist, the view is empty;
the app does not create it or move old mail automatically.

Viewing Backlog never adds INBOX or changes labels. Explicit filing removes Backlog and applies the
normal status rules above, preserving unrelated labels. Undo restores Backlog and the original
Inbox/archive state. `0` explicitly moves the thread to the In-tray and clears Backlog.
De-noise bulk mode remains In-tray-only.

## Demo mode

No Google account or sign-in needed. Demo mode loads a fictional mailbox (20 In-tray threads plus
filed Next Actions, Waiting For, Projects, Someday, Reference, Noise and Junk, with sample
Classification, Source, Tag and Project labels) and every action works: filing, archiving,
completing, un-filing, editing labels, filtering and Open in Gmail (which shows the link instead of
opening it). The on-device model runs on the sample mail like it would on real mail.
Everything lives in memory, so relaunching resets it.

```sh
swift run GmailGTD --demo        # or press "Try Demo" on the sign-in screen
swift run gtd --demo process     # CLI; each command starts from a fresh mailbox
```

## Building the app

`swift run` gives a bare executable. To build a proper `GmailGTD.app` with an icon, use make:

```sh
make                  # build build/GmailGTD.app (release)
make install          # build and install to ~/Applications, replacing any copy, then launch it
make install OPEN=0   # the same, without launching
make demo             # open the built app on the demo mailbox
make test             # run the unit tests
make help             # list every target
```

`make install` quits a running copy first. The targets are thin wrappers around `scripts/make-app.sh` and
`scripts/install.sh`, which you can also run directly (`--debug` gives a faster build). The bundle is ad-hoc
signed, which is enough to run on this Mac. Sharing it with other Macs would need a Developer ID signature and
notarisation. The icon is drawn in code (`Sources/GmailGTD/AppIcon.swift`); the build asks the app to export it
and turns it into an `.icns`.

`GmailGTD --check-config` prints whether the app can see a saved client ID and Keychain tokens (never the values), which is the first thing to run if a built app says it isn't signed in.

## Setup

1. In Google Cloud (inside your Workspace org), create a project and enable the **Gmail API**.
2. OAuth consent screen: user type **Internal**, scope `https://www.googleapis.com/auth/gmail.modify`.
3. Create an OAuth client of type **Desktop app** (and, for the iPhone app, one of type **iOS**).
4. If API controls restrict third-party apps, have a Workspace admin trust the client.

Sign in with the client ID (and secret, if shown). Tokens go in the Keychain and are shared
by the app and the CLI.

```sh
swift run GmailGTD                                  # app: enter client ID on first launch
swift run gtd login --client-id <ID> --client-secret <SECRET>
swift run gtd setup                                 # create the 🚦 status labels and 🚦/In-tray
swift run gtd process                               # walk the In-tray
```

`GMAIL_GTD_CLIENT_ID` / `GMAIL_GTD_CLIENT_SECRET` also work.

## iPhone app

The iPhone app uses the same model as the Mac app (`AppModel` and the label code), so filing, undo, facets and
filters behave the same. Only the screens are its own:

- **Mail**: Today, In-tray, Backlog and the seven statuses. Pull down to refresh.
- **A list**: swipe right for Next Action and Waiting For (in the In-tray) or Done (inside a status); swipe left
  for Noise and Reference, or back to the In-tray. Long-press a row for every status. The filter button opens
  Classification, Source, Tags and Projects filters (OR within a family, AND across them).
- **A thread**: Classification and Source menus, Tags and Projects (tick several), the suggestion with Approve,
  Summary or Original, and a grid of status buttons. Filing moves on to the next thread, like the Mac app.

Not on iPhone yet: De-noise, Corrections and the categorisation settings (Jev). Summaries need Apple Intelligence
turned on. Mail refreshes when the app opens and every ten minutes while it is open; iOS gives no background time.

```sh
brew install xcodegen      # once: the Xcode project is generated from iOS/project.yml
make ios-sim               # build and run in the simulator on the demo mailbox
make ios-device            # open the project in Xcode; choose your team under Signing, then run on your iPhone
```

Sign-in needs an OAuth client of type **iOS** (the Mac's Desktop client won't work) in the same Google Cloud
project, with bundle ID `dev.denw.gmail-gtd.ios`. Paste its client ID on the sign-in screen. Google's page opens in
a sign-in sheet and returns to the app on the reversed client ID scheme. A free Apple ID can install on your own
phone, but the app stops opening after 7 days until you run it from Xcode again; a paid developer account avoids that.

Debug builds accept `--route intray` (or `today`, `next`, …) and `--route intray/thread` to open a screen at launch.

## Optional Jev and custom categorisation prompts

Open **Categorisation Settings…** (⌘, or the toolbar). Local-only remains the default.
You can edit and independently reset the local and Jev classification prompts. Saving a changed
local prompt invalidates cached classifications; summary and project-planning prompts are unchanged.

To use Jev, enter a TypeSafe API token and explicitly enable the toggle. The token is stored in a
separate Keychain item, never UserDefaults. Clear the token field and save to delete it. Disabling
Jev stops new provider calls; an already-sent request cannot be recalled and its result is discarded.
Sign-out deletes this mailbox’s persisted Jev cache and clears in-memory results, but retains provider settings/token, like the saved OAuth client
configuration. Turning Jev off restores local-only approval immediately.

**Privacy/cost:** when enabled, on-screen threads in In-tray, Backlog, Next Action and Waiting For are sent
automatically to TypeSafe, including sender, subject and message text (not attachments). API charges
may apply. Demo mode follows the same opt-in using fictional mail. Nothing is filed automatically.
The detail pane identifies both sources; **Approve** (also **A**) uses Jev whenever enabled, including
when the local model is unavailable. If Jev is pending, fails, lacks a token or returns an invalid
category, approval stays disabled—there is no silent local fallback. Use Retry/Regenerate, fix Settings,
disable Jev, or choose a status manually. The CLI's `suggest` and `process` share these settings and policy;
configure the token/prompts in the app. Summaries, digests and project plans remain on-device.

Integration uses [TypeSafe System One](https://docs.typesafe.ai/introduction/quickstart),
a Bearer-authenticated `POST https://api.typesafe.ai/v1/systemone` with a single typed Choice question
and the pinned model `jev-1.14.0`. It returns a 🚦 status (Next Action … Junk) and per-category probabilities,
not generated summaries/actions. The Noise estimate is the documented
[Choice probability](https://docs.typesafe.ai/primitives/choice#response-structure)
`answers.bucket.probabilities.noise`, **not** the separate `confidence` statistic or a value
inferred from the selected category. No extra provider questions/calls are needed, and custom
classification prompts and request budgets are unchanged.
The [documented standard limits](https://docs.typesafe.ai/models) are 64k tokens per request and
32k per question (email state + instructions + criteria). No experimental long-context header is used.
Local prompts allow 2,000 UTF-8 bytes alongside the existing 6,000-character thread budget; Jev
prompts allow 24,000 UTF-8 bytes with a **30,000-byte complete JSON request cap**. This deliberately
conservative byte budget avoids assuming a tokenizer ratio; it is not a claim to use the full provider
window. Jev keeps newest email first and trims older content to the remaining budget. Over-limit/empty
prompts are rejected with an error, never silently truncated. HTTP errors expose only status/actionable
advice, not provider response bodies that might contain mail or credentials.

### Local Jev cache

Successful app classifications (category plus optional Noise probability) are cached privately in
`~/Library/Application Support/GmailGTD/JevClassifications/<account-hash>.json` (up to 500 threads).
They survive relaunch and same-account reconnection. Selection, scrolling and label/folder moves
reuse the same result; concurrent requests share provider work. Account identity, full thread
content, prompt, model, request criteria/budget and response-format version guard reuse. Tokens,
message bodies, prompts, pending states and errors are not written to this cache. Unidentified
mailboxes and demo sessions remain memory-only. A corrupt/incompatible cache is a cache miss;
disk failures do not block in-session triage.

**Regenerate/Retry** discards the selected thread’s completed entry and requests a fresh result.
Changing only the local prompt or the Noise threshold does not invalidate a valid Jev result.
Sign-out deletes the active mailbox's Jev cache and prevents late requests from restoring it.
Deleting the account cache file while the app is closed also resets it safely. This cache is app-only;
the CLI still evaluates each invocation directly. No new configuration or live-provider verification
is required.

### Verification

On macOS 26 with Xcode/Swift 6:

```sh
swift build
swift test
```

The PR test workflow runs both on a macOS 26 runner. Jev tests inject mocked HTTP transport and never
need a token or send real email. A live smoke test is optional: opt in with your own token and sample
mail, verify both categories, press Approve, then disable Jev and verify local-only approval.

## De-noise confidence threshold

In the In-tray, choose a **Minimum Noise estimate** (default 90%, 0–100% in 1% steps).
De-noise Mode requires ten loaded In-tray threads whose active approval category is Noise
and whose finite, in-range score meets the threshold inclusively. It uses Jev's Noise probability
when Jev is enabled, otherwise the local AFM self-estimate. It never borrows the other source's
score or treats missing/invalid scores as high confidence, even at 0%.

AFM uses Apple's supported [guided numeric generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
with a [bounded Double](https://developer.apple.com/documentation/foundationmodels/generationguide/range(_:))
in the existing classification request. This is the model's **self-estimate**, not a native token
probability. Its reliability has not been measured on a labelled email dataset. Both sources are
**model estimates, not promises of calibrated accuracy**: 90% does not guarantee 90% correct filing.
The local classification rules and separate summary request remain unchanged.

The slider filters scores already computed; moving it does not classify again or write to Gmail.
Changing it ends any current review and dismisses its correction picker. Start a new batch, review
its ten emails and explicitly press LGTM; stale actions cannot approve the replacement. Each card
shows its snapshotted Noise estimate. Not Noise corrections still shrink the snapshot without
adding replacements. Threshold is session-only. Existing unscored local caches remain unscored
until normal Regenerate supplies a score; there is no automatic cache refresh or cache redesign.
Jev scores persist with their categories in the account-scoped cache described above; local scores follow the existing summary cache.

## Local Corrections

The **Corrections** sidebar keeps timestamped snapshots when a manual status choice differs from
its active approval suggestion: Jev when enabled and successful, otherwise AFM when Jev is disabled.
No active result means no inferred correction. Both available categories, the chosen status, and the
relevant prompts at the time are retained (older records that say Done read as Reference); subsequent classifications do not rewrite history.
This includes De-noise “Not Noise” choices and Done, but not approvals, automatic filing or moves to the In-tray.
Records are added only after Gmail confirms filing; successful undo removes the corresponding event.

Each entry offers a **possible explanation**, generated deterministically on this Mac from captured
prompt wording, not model reasoning or a verified cause. Missing results/prompts are marked unavailable.
Reviewing history makes no provider or Gmail requests (except explicitly opening a thread in Gmail).
No correction-specific Gmail labels are created. History contains thread ID, subject/sender, categories,
prompts and timestamp, not message bodies or credentials. It lives in private mailbox-keyed JSON files in
`~/Library/Application Support/GmailGTD/Corrections/`. Sign-out hides but retains
history for the same mailbox; demo history stays in memory and resets. If mailbox identity or disk access
is unavailable, filing still works and history is session-only with a warning. Unreadable history is
never overwritten. To remove retained history, quit the app and delete that local Corrections directory.

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
- The model runs automatically on the open In-tray or Backlog thread, but nothing is filed until you accept.
- Compose and reply aren't built yet; use Open in Gmail.
- Keys in the app: `1`-`7` file under a status, `0` back to the In-tray, `⌘1`-`⌘7` go to a status, `⌘0` In-tray, `⌘T` Today, `⌘Z` undo the last move, `A` accept, `E` done (files as Reference), `R` regenerate, `O` open in Gmail. Hold `⌘` for the full list. Suggestions generate automatically for the open In-tray or Backlog thread (and plans for projects); Regenerate re-runs one.
