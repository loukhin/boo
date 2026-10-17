import Foundation

/// Translates Ghostty's program status records (OSC 7501) into Boo's UI:
/// the tab and workspace status marks, their tooltips, and notifications.
///
/// The core already keeps the records and applies the specification's
/// lifetime rules; this only decides how to present them.
enum BooProgramStatus {
    typealias Record = Ghostty.Action.ProgramStatus

    /// The most help lines shown before summarizing the rest.
    static let maxHelpLines = 5

    /// The longest program-supplied text shown outside the terminal.
    static let maxTextLength = 200

    // MARK: - Indicator

    /// The status mark for a set of records, or nil if nothing is worth
    /// showing (no records, or only `idle` ones).
    static func indicator(for records: [Record]) -> TabStatusIndicator? {
        guard let top = mostUrgent(records) else { return nil }
        return TabStatusIndicator(
            style: style(for: top.state),
            symbol: symbol(for: top),
            progress: top.progress.map { Double($0) / 100 },
            help: help(for: records)
        )
    }

    /// The record that decides the mark: the most urgent state wins, and
    /// among equals the most recently updated (records arrive least
    /// recently updated first). `idle` never wins.
    static func mostUrgent(_ records: [Record]) -> Record? {
        records.enumerated()
            .filter { urgency($0.element.state) != nil }
            .max { lhs, rhs in
                let l = urgency(lhs.element.state) ?? 0
                let r = urgency(rhs.element.state) ?? 0
                return (l, lhs.offset) < (r, rhs.offset)
            }?
            .element
    }

    /// Higher is more urgent. A program waiting on the user beats one that
    /// failed, which beats running work, which beats finished work.
    static func urgency(_ state: Record.State) -> Int? {
        switch state {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle: nil
        }
    }

    static func style(for state: Record.State) -> TabStatusIndicator.Style {
        switch state {
        case .blocked: .attention
        case .error: .failure
        case .done: .success
        case .working, .idle: .active
        }
    }

    /// Blocked records say what the user needs to do with a symbol.
    static func symbol(for record: Record) -> String? {
        guard record.state == .blocked else { return nil }
        switch record.kind {
        case .permission: return "hand.raised.fill"
        case .question: return "questionmark.circle.fill"
        case .auth: return "key.fill"
        case nil: return nil
        }
    }

    // MARK: - Text

    /// One line per non-idle record, most urgent first.
    static func help(for records: [Record]) -> String? {
        let lines = records.enumerated()
            .filter { urgency($0.element.state) != nil }
            .sorted { lhs, rhs in
                let l = urgency(lhs.element.state) ?? 0
                let r = urgency(rhs.element.state) ?? 0
                return (l, lhs.offset) > (r, rhs.offset)
            }
            .map { describe($0.element) }
        guard !lines.isEmpty else { return nil }

        var shown = Array(lines.prefix(maxHelpLines))
        if lines.count > maxHelpLines {
            shown.append("+\(lines.count - maxHelpLines) more")
        }
        return shown.joined(separator: "\n")
    }

    /// For example "terraform · Plan — Blocked (permission): Apply?".
    static func describe(_ record: Record) -> String {
        let name = [record.app, sanitize(record.title)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let status = stateDescription(record)
        let head = name.isEmpty ? status : "\(name) — \(status)"
        let msg = sanitize(record.msg)
        return msg.isEmpty ? head : "\(head): \(msg)"
    }

    static func stateDescription(_ record: Record) -> String {
        let progress = record.progress.map { " \($0)%" } ?? ""
        switch record.state {
        case .idle: return "Idle"
        case .working: return "Working\(progress)"
        case .done: return "Done"
        case .error: return "Error"
        case .blocked:
            let kind = switch record.kind {
            case .permission: " (permission)"
            case .question: " (question)"
            case .auth: " (sign-in)"
            case nil: ""
            }
            return "Blocked\(kind)\(progress)"
        }
    }

    /// The core already rejects control characters. The specification also
    /// asks terminals to disarm text direction overrides and other invisible
    /// formatting when showing program text outside the grid, which are all
    /// in the Unicode "format" category. Long text is shortened.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter {
            $0.properties.generalCategory != .format
        })
        let clean = String(scalars).trimmingCharacters(in: .whitespaces)
        guard clean.count > maxTextLength else { return clean }
        return String(clean.prefix(maxTextLength - 1)) + "…"
    }

    // MARK: - Notifications

    /// The desktop notification for a record that just started needing the
    /// user, or nil if this state doesn't warrant one.
    static func notification(for record: Record) -> (title: String, body: String)? {
        let name = record.app.isEmpty ? "A program" : record.app
        let title: String
        switch record.state {
        case .blocked: title = "\(name) needs your attention"
        case .done: title = "\(name) finished"
        case .error: title = "\(name) failed"
        case .idle, .working: return nil
        }

        let msg = sanitize(record.msg)
        let body = msg.isEmpty ? sanitize(record.title) : msg
        return (title, body)
    }
}
