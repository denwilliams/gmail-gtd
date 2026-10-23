import Foundation

/// Fictional mailbox for demo mode. All people and companies are made up.
enum DemoData {
    private static let me = "Alex Morgan <alex@example.com>"

    private static func t(_ id: String, inbox: Bool = false, bucket: GTDBucket? = nil, unread: Bool = false,
                          _ messages: [DemoMessage]) -> DemoThreadSeed {
        DemoThreadSeed(id: id, inbox: inbox, bucket: bucket, unread: unread, messages: messages)
    }

    private static func m(_ from: String, _ hoursAgo: Double, subject: String? = nil, _ body: String) -> DemoMessage {
        DemoMessage(from: from, hoursAgo: hoursAgo, body: body, subject: subject)
    }

    static let threads: [DemoThreadSeed] = inbox + nextActions + waitingFor + projects + someday + reference

    // MARK: Inbox (unprocessed)

    private static let inbox: [DemoThreadSeed] = [
        t("in01", inbox: true, unread: true, [m("Priya Nair <priya@brightfield.example>", 2, subject: "Q4 pricing deck: can you review by Thursday?",
            "Hi Alex,\n\nI've put together the Q4 pricing deck and would love your eyes on slides 6 to 9 before it goes to the leadership team on Friday. Mainly I'm unsure about the enterprise tier numbers.\n\nCould you leave comments by end of day Thursday?\n\nThanks,\nPriya")]),
        t("in02", inbox: true, unread: true, [
            m("Sam Okafor <sam@brightfield.example>", 30, subject: "Venue booking for the offsite",
              "Hey, I've asked the Lakeside Lodge for a quote for 24 people over two nights. They said they'd get back to us by Wednesday. I'll forward it as soon as it lands.\n\nSam"),
            m("Sam Okafor <sam@brightfield.example>", 4, "Quote is in: $14,200 all-in including catering. Need a yes or no from you today to hold the dates.")]),
        t("in03", inbox: true, [m("Billing <billing@cloudharbor.example>", 5, subject: "Your invoice INV-20418 is ready",
            "Your invoice for October is now available. Amount due: $312.40. Payment is due on 15 November.\n\nNo action is needed if you have automatic payments on.")]),
        t("in04", inbox: true, unread: true, [m("Swift Weekly Brief <hello@swiftbrief.example>", 9, subject: "Swift Weekly Brief: structured concurrency tips",
            "This week: five patterns for structured concurrency, a deep dive on actors, and a look at what's new in on-device language model APIs. Read online or reply to unsubscribe.")]),
        t("in05", inbox: true, unread: true, [m("Jordan Lee <jordan@fernhill.example>", 6, subject: "Intro: Maya from Northwind",
            "Alex, meet Maya Chen. She runs partnerships at Northwind and is keen to talk about a possible integration. Maya, Alex is who I mentioned.\n\nI'll let you two take it from here. Maya's free most afternoons next week.\n\nJordan")]),
        t("in06", inbox: true, [m("People Team <people@brightfield.example>", 20, subject: "Reminder: submit timesheets by Friday 5pm",
            "A quick reminder that timesheets for this fortnight are due Friday at 5pm. Late submissions roll into the next pay cycle.")]),
        t("in07", inbox: true, unread: true, [
            m("Dana Whitfield <dana@whitfieldlaw.example>", 52, subject: "Contract redlines attached",
              "Alex,\n\nAttached are our redlines on the services agreement. The main changes are in clauses 7 (liability cap) and 12 (termination notice). Everything else is as discussed.\n\nPlease let me know if you're comfortable, and I'll send a clean copy for signature.\n\nDana"),
            m(me, 40, "Thanks Dana. I'm fine with 12. Can we talk through the liability cap? I'd like to get my CFO's view first."),
            m("Dana Whitfield <dana@whitfieldlaw.example>", 3, "Of course. Can you get back to me by Monday? The counterparty wants to sign this week.")]),
        t("in08", inbox: true, [m("CI Bot <ci@buildlane.example>", 1, subject: "[tidepool/api] Review requested on PR #214",
            "Marcus Webb requested your review on pull request #214: 'Add retry with backoff to the sync worker'. 3 files changed, +88 -12.")]),
        t("in09", inbox: true, unread: true, [m("Lina Park <lina@brightfield.example>", 7, subject: "Lunch next week?",
            "Hey! It's been ages. Free for lunch Tuesday or Thursday next week? There's a new ramen place near the office I've been wanting to try.")]),
        t("in10", inbox: true, [m("SkyPath Travel <noreply@skypath.example>", 26, subject: "Your itinerary: MEL to SYD, 12 November",
            "Booking reference K7QX2M. Outbound: Thursday 12 November, 07:10 departing Melbourne, arriving Sydney 08:50. Return: Friday 13 November, 18:30. Check-in opens 24 hours before departure.")]),
        t("in11", inbox: true, unread: true, [m("Marcus Webb <marcus@tidepool.example>", 11, subject: "Quick question about API rate limits",
            "Hi Alex, quick one. Our integration is hitting 429s around 100 requests a minute. Is that the documented limit, or is there a higher tier we can request? We're planning to roughly triple our volume next month.\n\nMarcus")]),
        t("in12", inbox: true, unread: true, [m("Accounts Payable <ap@brightfield.example>", 14, subject: "Overdue: PO 4471 needs your approval",
            "Purchase order 4471 (Halcyon Print, $2,860) has been waiting for your approval for 6 days. The supplier's payment terms expire on Friday. Please approve or reject in the finance portal.")]),
        t("in13", inbox: true, [m("Nora Silva <nora@brightfield.example>", 34, subject: "All-hands notes",
            "Notes from this week's all-hands are in the shared drive. Highlights: Q3 numbers were ahead of plan, the new support rota starts 1 December, and the office will be closed from 24 December to 2 January.")]),
        t("in14", inbox: true, [m("Account Security <security@cloudharbor.example>", 18, subject: "New sign-in to your account",
            "We noticed a new sign-in to your account from Chrome on macOS in Melbourne, Australia. If this was you, there's nothing to do. If not, reset your password.")]),
        t("in15", inbox: true, unread: true, [
            m(me, 120, subject: "Proposal for the Rosewood engagement", "Hi Elena, attached is our proposal for the Rosewood engagement. Happy to walk through it whenever suits."),
            m("Elena Rossi <elena@rosewood.example>", 9, "Hi Alex, thanks for sending this over. We've had a read and have a few questions on timeline and pricing. Could we find 30 minutes this week?")]),
        t("in16", inbox: true, [m("Tom Brandt <tom@fernhill.example>", 70, subject: "Idea: a CLI for expense reports",
            "Random thought from the weekend: someone should build a command line tool that turns a folder of receipts into a tidy expense report. No rush, just thought you might find it fun for a hack day.")]),
        t("in17", inbox: true, [m("Facilities <facilities@brightfield.example>", 22, subject: "Office kitchen closed Monday",
            "The kitchen will be closed on Monday for deep cleaning. The coffee machine on level 2 will remain available.")]),
        t("in18", inbox: true, unread: true, [
            m("Hana Ito <hana@marlowe.example>", 16, subject: "Bug report: export fails on large files",
              "Hi team, exporting a report with more than about 50,000 rows fails with a generic error. It worked fine last month. We need this for our board pack on the 18th. Happy to share a sample file if that helps.\n\nHana"),
            m("Hana Ito <hana@marlowe.example>", 2, "Following up: any update on the export problem? We're getting a bit nervous about the 18th.")]),
        t("in19", inbox: true, [m("Riley at Brightwave <riley@brightwave.example>", 48, subject: "Senior engineering role at Brightwave",
            "Hi Alex, I came across your profile and thought you might be a great fit for a senior engineering role on our platform team. Fully remote, strong comp. Open to a quick chat?")]),
        t("in20", inbox: true, [m("Noah Fischer <noah@brightfield.example>", 8, subject: "Re: Budget approval", "Approved, go ahead. Please keep the spend under the amount we discussed.")]),
    ]

    // MARK: Next Actions

    private static let nextActions: [DemoThreadSeed] = [
        t("na01", bucket: .nextAction, [m("Priya Nair <priya@brightfield.example>", 60, subject: "Onboarding checklist for our new hire",
            "Can you draft the onboarding checklist for Jamie, who starts on the 3rd? Use last quarter's template. Include laptop setup, access requests and the first-week schedule.")]),
        t("na02", bucket: .nextAction, [m("Legal <legal@halcyon.example>", 90, subject: "Signed NDA needed",
            "Before we share the technical specs, please send us the signed mutual NDA. The PDF is attached; sign on page 4 and return it by reply.")]),
        t("na03", bucket: .nextAction, [m("Westside Auto <service@westsideauto.example>", 100, subject: "Your car is due for a service",
            "Your vehicle is due for its 15,000 km service. Book online or call us to choose a time that suits you.")]),
        t("na04", bucket: .nextAction, [m("Nora Silva <nora@brightfield.example>", 50, subject: "Agenda for Monday planning",
            "Could you pull together the agenda for Monday's planning session? Last time we ran out of time on the roadmap, so maybe put that first.")]),
        t("na05", bucket: .nextAction, [m("Conf Committee <cfp@devsummit.example>", 80, subject: "Reviewers needed for the CFP",
            "Thanks for volunteering to review talk proposals. You've been assigned 12 submissions. Please enter scores in the review portal by 20 November.")]),
    ]

    // MARK: Waiting For

    private static let waitingFor: [DemoThreadSeed] = [
        t("wf01", bucket: .waitingFor, [
            m(me, 150, subject: "Quote request: 6 sit-stand desks", "Hi Kestrel team, could you send a quote for six electric sit-stand desks in oak, delivered to our Collingwood office? Thanks, Alex"),
            m("Kestrel Furniture <sales@kestrel.example>", 148, "Thanks Alex, we'll have a quote to you within a few days.")]),
        t("wf02", bucket: .waitingFor, [m(me, 110, subject: "Homepage mockups", "Hi Ines, could you send the homepage mockups when they're ready? I'd like to review them before the Thursday sync. Alex")]),
        t("wf03", bucket: .waitingFor, [
            m(me, 220, subject: "Laptop replacement request #8812", "Hi IT, my laptop's battery is failing. Can I get a replacement? Alex"),
            m("IT Helpdesk <it@brightfield.example>", 218, "Ticket #8812 logged. Procurement will be in touch with a delivery date.")]),
        t("wf04", bucket: .waitingFor, [m(me, 75, subject: "Reference check for the backend candidate", "Hi Omar, thanks for agreeing to be a referee. Could you send your reference by Friday? A few lines on their strengths is plenty. Alex")]),
    ]

    // MARK: Projects

    private static let projects: [DemoThreadSeed] = [
        t("pr01", bucket: .project, [
            m("Priya Nair <priya@brightfield.example>", 400, subject: "Website redesign", "Kicking off the website redesign. Goals: faster pages, clearer pricing, and a new case studies section. Target launch is end of January. We need a content owner and a designer."),
            m(me, 390, "Great. I'll own content. Ines can lead design. Let's get a sitemap draft first."),
            m("Ines Duarte <ines@brightfield.example>", 300, "Sitemap draft attached. Open questions: do we keep the blog, and where do case studies live in the navigation?"),
            m(me, 120, "Keep the blog for now. Case studies can sit under Customers. I'll write the first three by the 20th.")]),
        t("pr02", bucket: .project, [
            m("Sam Okafor <sam@brightfield.example>", 350, subject: "Q1 offsite planning", "Starting to plan the Q1 offsite. 24 people, two nights, somewhere within three hours of the city. I'll start collecting venue options."),
            m(me, 340, "Thanks Sam. Please include accessibility details for each venue, and keep the budget under $15k."),
            m("Sam Okafor <sam@brightfield.example>", 200, "Shortlist: Lakeside Lodge, Hillcrest Retreat and the Old Mill. I'll put pros and cons together.")]),
        t("pr03", bucket: .project, [
            m("Noah Fischer <noah@brightfield.example>", 500, subject: "Migrate billing to the new provider", "We're moving off our current billing provider by the end of Q1 because of fees and reporting limits. Needs: data export, parallel run for one cycle, and customer comms."),
            m(me, 480, "I'll scope the data migration. Can finance confirm the parallel run is acceptable?"),
            m("Noah Fischer <noah@brightfield.example>", 260, "Finance is fine with one parallel cycle. We need a cutover date by mid-December.")]),
        t("pr04", bucket: .project, [
            m("People Team <people@brightfield.example>", 600, subject: "Hiring: backend engineer", "We've opened a backend engineer role. Stages: screening call, take-home, technical interview, culture chat. Alex, you're the hiring manager."),
            m(me, 590, "Thanks. I'll draft the take-home and find two interviewers."),
            m("People Team <people@brightfield.example>", 180, "Five candidates passed screening. We need take-home reviewers lined up for next week.")]),
    ]

    // MARK: Someday/Maybe

    private static let someday: [DemoThreadSeed] = [
        t("sd01", bucket: .someday, [m("Tom Brandt <tom@fernhill.example>", 800, subject: "Reading list: systems programming", "Collected a few good articles on systems programming, including a long one on memory allocators. Not urgent, but a nice weekend read if you ever fancy it.")]),
        t("sd02", bucket: .someday, [m("Lina Park <lina@brightfield.example>", 900, subject: "Podcast guest ideas", "If you ever start that podcast, I'd suggest inviting the founders of Fernhill and Marlowe. They both have great stories about the early days.")]),
        t("sd03", bucket: .someday, [m("Nora Silva <nora@brightfield.example>", 700, subject: "Standing desk conversion idea", "Thinking about trialling a standing desk converter in the quiet room. No budget yet, but worth considering once the new desks sort themselves out.")]),
    ]

    // MARK: Reference

    private static let reference: [DemoThreadSeed] = [
        t("rf01", bucket: .reference, [m("Facilities <facilities@brightfield.example>", 1000, subject: "Office wifi and door codes", "Guest wifi: Brightfield-Guest. Password rotates monthly and is on the reception board. Door code for after-hours access is held by team leads.")]),
        t("rf02", bucket: .reference, [m("Harbor Insurance <policies@harborins.example>", 1200, subject: "Your policy documents", "Your business insurance renews on 1 March. Policy documents and the certificate of currency are attached for your records.")]),
        t("rf03", bucket: .reference, [m("People Team <people@brightfield.example>", 1100, subject: "Expense policy 2026", "Updated expense policy attached. Meals up to $60 per day while travelling. Receipts required for anything over $25. Submit within 30 days.")]),
    ]
}
