import Testing
@testable import Ghostty

struct BooProgramStatusTests {
    private typealias Record = Ghostty.Action.ProgramStatus

    private func record(
        _ state: Record.State,
        kind: Record.Kind? = nil,
        progress: UInt8? = nil,
        id: String = "",
        app: String = "",
        title: String = "",
        msg: String = ""
    ) -> Record {
        .init(state: state, kind: kind, progress: progress, id: id, app: app, title: title, msg: msg)
    }

    @Test func noRecordsOrOnlyIdleShowNothing() {
        #expect(BooProgramStatus.indicator(for: []) == nil)
        #expect(BooProgramStatus.indicator(for: [record(.idle)]) == nil)
        #expect(BooProgramStatus.help(for: [record(.idle)]) == nil)
    }

    @Test func eachStateMapsToItsStyle() {
        #expect(BooProgramStatus.indicator(for: [record(.working)])?.style == .active)
        #expect(BooProgramStatus.indicator(for: [record(.blocked)])?.style == .attention)
        #expect(BooProgramStatus.indicator(for: [record(.done)])?.style == .success)
        #expect(BooProgramStatus.indicator(for: [record(.error)])?.style == .failure)
    }

    @Test func mostUrgentRecordWins() {
        // A root record that's still working while a child waits on the user,
        // like the specification's multi-region deploy example.
        let deploy = [record(.working), record(.blocked, id: "eu-west"), record(.done, id: "us-east")]
        #expect(BooProgramStatus.indicator(for: deploy)?.style == .attention)
        #expect(BooProgramStatus.indicator(for: [record(.done), record(.error, id: "a")])?.style == .failure)
        #expect(BooProgramStatus.indicator(for: [record(.done), record(.working, id: "a")])?.style == .active)
    }

    @Test func mostRecentlyUpdatedBreaksTies() {
        let records = [record(.working, progress: 10, id: "old"), record(.working, progress: 90, id: "new")]
        #expect(BooProgramStatus.mostUrgent(records)?.id == "new")
        #expect(BooProgramStatus.indicator(for: records)?.progress == 0.9)
    }

    @Test func blockedKindsGetSymbols() {
        #expect(BooProgramStatus.indicator(for: [record(.blocked, kind: .permission)])?.symbol == "hand.raised.fill")
        #expect(BooProgramStatus.indicator(for: [record(.blocked, kind: .question)])?.symbol == "questionmark.circle.fill")
        #expect(BooProgramStatus.indicator(for: [record(.blocked, kind: .auth)])?.symbol == "key.fill")
        #expect(BooProgramStatus.indicator(for: [record(.blocked)])?.symbol == nil)
        #expect(BooProgramStatus.indicator(for: [record(.error)])?.symbol == nil)
    }

    @Test func helpListsRecordsMostUrgentFirst() {
        let records = [
            record(.working, progress: 40, app: "deploy", msg: "Deploying"),
            record(.blocked, kind: .permission, id: "eu", app: "deploy", title: "EU West", msg: "Approve?"),
        ]
        #expect(BooProgramStatus.help(for: records) ==
            "deploy · EU West — Blocked (permission): Approve?\ndeploy — Working 40%: Deploying")
    }

    @Test func helpSummarizesOverflow() throws {
        let records = (0..<7).map { record(.working, id: "r\($0)") }
        let help = try #require(BooProgramStatus.help(for: records))
        #expect(help.split(separator: "\n").count == BooProgramStatus.maxHelpLines + 1)
        #expect(help.hasSuffix("+2 more"))
    }

    @Test func sanitizeRemovesInvisibleFormattingAndShortens() {
        // U+202E RIGHT-TO-LEFT OVERRIDE and U+200B ZERO WIDTH SPACE.
        #expect(BooProgramStatus.sanitize("ab\u{202E}cd\u{200B}e") == "abcde")
        let long = String(repeating: "x", count: BooProgramStatus.maxTextLength + 10)
        let short = BooProgramStatus.sanitize(long)
        #expect(short.count == BooProgramStatus.maxTextLength)
        #expect(short.hasSuffix("…"))
    }

    @Test func notificationsOnlyForStatesThatNeedTheUser() {
        #expect(BooProgramStatus.notification(for: record(.working)) == nil)
        #expect(BooProgramStatus.notification(for: record(.idle)) == nil)

        let blocked = BooProgramStatus.notification(for: record(.blocked, app: "brew", msg: "Password required"))
        #expect(blocked?.title == "brew needs your attention")
        #expect(blocked?.body == "Password required")

        let done = BooProgramStatus.notification(for: record(.done, title: "Photos"))
        #expect(done?.title == "A program finished")
        #expect(done?.body == "Photos")
    }
}
