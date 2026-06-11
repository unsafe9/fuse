import Foundation

/// Result of parsing a time expression.
enum ParseResult: Equatable {
    /// A relative duration in seconds (from `5m`, `1h30m`, `90`, etc.).
    case duration(TimeInterval)
    /// An absolute wall-clock target (from `HH:MM`).
    case deadline(Date)
}

/// Error describing why a time expression could not be parsed. `reason` is a short
/// human-readable message suitable for the custom-timer panel's inline error label
/// and for AppleScript `scriptErrorString`.
struct ParseError: Error, Equatable {
    let reason: String
}

/// Pure, unit-test-friendly parser for the time expressions accepted by the custom
/// panel and AppleScript (feature 2 / 6).
///
/// Accepted forms (trimmed, case-insensitive):
/// - Compound duration: `(\d+h)?(\d+m)?(\d+s)?` with at least one component present,
///   e.g. `1h`, `1h30m`, `90m`, `45s`, `1h30m10s` -> `.duration`.
/// - Bare integer: `25` -> 25 minutes -> `.duration`.
/// - Clock time: `HH:MM` or `H:MM` (24-hour) -> the NEXT wall-clock occurrence
///   (today if strictly in the future, else tomorrow), Calendar-based -> `.deadline`.
///
/// Rejections (throw `ParseError`): empty/garbage input, zero or negative totals,
/// and clock forms with minutes > 59 (or hours > 23).
///
/// OWNER: core. Compiling stub; the rules above are the binding contract.
enum TimeParser {
    /// Parses `s` relative to `now`. Throws `ParseError` on invalid input.
    static func parse(_ s: String, now: Date = Date()) throws -> ParseResult {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError(reason: "Enter a time, e.g. 5m, 1h30m, 90, or 14:30.")
        }
        let lower = trimmed.lowercased()

        // Clock form: HH:MM (contains a colon).
        if lower.contains(":") {
            return try parseClock(lower, now: now)
        }

        // Bare integer -> minutes.
        if let minutes = Int(lower) {
            guard minutes > 0 else {
                throw ParseError(reason: "Duration must be greater than zero.")
            }
            return .duration(TimeInterval(minutes) * 60)
        }

        // Compound duration: (\d+h)?(\d+m)?(\d+s)?
        return try parseDuration(lower)
    }

    // MARK: - Compound duration

    private static func parseDuration(_ s: String) throws -> ParseResult {
        let invalid = ParseError(reason: "Invalid time. Try 5m, 1h30m, 90, or 14:30.")

        // Match in strict h -> m -> s order; each component optional but at least one
        // required, and the whole string must be consumed.
        var index = s.startIndex
        let end = s.endIndex

        func consumeComponent(_ unit: Character) throws -> Int? {
            guard index < end else { return nil }
            var digits = ""
            var cursor = index
            while cursor < end, s[cursor].isNumber {
                digits.append(s[cursor])
                cursor = s.index(after: cursor)
            }
            guard cursor < end, s[cursor] == unit, !digits.isEmpty else { return nil }
            guard let value = Int(digits) else { throw invalid }
            index = s.index(after: cursor)
            return value
        }

        let hours = try consumeComponent("h") ?? 0
        let minutes = try consumeComponent("m") ?? 0
        let seconds = try consumeComponent("s") ?? 0

        // The whole string must be consumed and at least one component present.
        guard index == end, hours > 0 || minutes > 0 || seconds > 0 else {
            throw invalid
        }

        let total = TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60 + TimeInterval(seconds)
        guard total > 0 else {
            throw ParseError(reason: "Duration must be greater than zero.")
        }
        return .duration(total)
    }

    // MARK: - Clock time

    private static func parseClock(_ s: String, now: Date) throws -> ParseResult {
        let invalid = ParseError(reason: "Invalid clock time. Use HH:MM in 24-hour form, e.g. 14:30.")

        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              !parts[0].isEmpty, !parts[1].isEmpty else {
            throw invalid
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw invalid
        }

        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let todayTarget = calendar.date(from: comps) else { throw invalid }

        // NEXT occurrence: today if strictly in the future, else tomorrow.
        if todayTarget > now {
            return .deadline(todayTarget)
        }
        guard let tomorrowTarget = calendar.date(byAdding: .day, value: 1, to: todayTarget) else {
            throw invalid
        }
        return .deadline(tomorrowTarget)
    }
}
