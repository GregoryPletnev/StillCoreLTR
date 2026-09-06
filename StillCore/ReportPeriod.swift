import Foundation

/// The four report spans the app offers.
enum ReportPeriodKind: String, CaseIterable, Identifiable, Sendable {
    case day
    case month
    case quarter
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .month: return "Month"
        case .quarter: return "Quarter"
        case .year: return "Year"
        }
    }

    /// How the period is split into table rows and chart bars.
    var granularity: ReportGranularity {
        switch self {
        case .day: return .hour
        case .month: return .day
        case .quarter: return .week
        case .year: return .month
        }
    }

    fileprivate var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .month: return .month
        case .quarter: return .quarter
        case .year: return .year
        }
    }
}

/// Row granularity inside a report.
enum ReportGranularity: Sendable {
    case hour
    case day
    case week
    case month

    fileprivate var calendarComponent: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// One report span, anchored on a date and resolved against the user calendar.
struct ReportPeriod: Equatable, Sendable {
    var kind: ReportPeriodKind
    /// Any date inside the period.
    var anchor: Date

    static func current(_ kind: ReportPeriodKind, now: Date = Date()) -> ReportPeriod {
        ReportPeriod(kind: kind, anchor: now)
    }

    /// Half-open interval covered by the period.
    func interval(calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: kind.calendarComponent, for: anchor)
            ?? DateInterval(start: anchor, duration: 0)
    }

    func shifted(by steps: Int, calendar: Calendar = .current) -> ReportPeriod {
        let shifted =
            calendar.date(byAdding: kind.calendarComponent, value: steps, to: anchor) ?? anchor
        return ReportPeriod(kind: kind, anchor: shifted)
    }

    /// True when the period contains the given moment, so the report is still
    /// filling up and its coverage cannot reach 100%.
    func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        interval(calendar: calendar).contains(now)
    }

    /// Keeps the anchor meaningful when the user switches span, for example
    /// from a day in March to the quarter that day belongs to.
    func converted(to kind: ReportPeriodKind) -> ReportPeriod {
        ReportPeriod(kind: kind, anchor: anchor)
    }

    // MARK: - Titles

    func title(calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone

        switch kind {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM y")
            return formatter.string(from: interval(calendar: calendar).start)
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("LLLL y")
            return formatter.string(from: interval(calendar: calendar).start)
        case .quarter:
            let start = interval(calendar: calendar).start
            let quarter = (calendar.component(.month, from: start) - 1) / 3 + 1
            return "Q\(quarter) \(calendar.component(.year, from: start))"
        case .year:
            return String(calendar.component(.year, from: interval(calendar: calendar).start))
        }
    }

    /// Explicit date range, printed under the title so a report stays readable
    /// on paper without knowing which calendar produced it.
    func subtitle(calendar: Calendar = .current, locale: Locale = .current) -> String {
        let periodInterval = interval(calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = kind == .day ? .none : .none

        let lastMoment = periodInterval.end.addingTimeInterval(-1)
        if kind == .day {
            return formatter.string(from: periodInterval.start)
        }
        return "\(formatter.string(from: periodInterval.start)) – "
            + formatter.string(from: lastMoment)
    }
}

/// Splits a period into the buckets that become table rows and chart bars.
struct ReportBucketPlan {
    let starts: [Date]
    let interval: DateInterval
    private let calendar: Calendar
    private let granularity: ReportGranularity

    init(period: ReportPeriod, calendar: Calendar = .current) {
        self.calendar = calendar
        self.granularity = period.kind.granularity
        self.interval = period.interval(calendar: calendar)

        var starts: [Date] = []
        var cursor =
            calendar.dateInterval(of: granularity.calendarComponent, for: interval.start)?.start
            ?? interval.start
        // A week bucket can start before the quarter it belongs to. Clip the
        // first bucket so no row reports time outside the period.
        while cursor < interval.end {
            starts.append(max(cursor, interval.start))
            guard
                let next = calendar.date(
                    byAdding: granularity.calendarComponent, value: 1, to: cursor)
            else { break }
            cursor = next
        }
        self.starts = starts
    }

    /// Half-open range of the bucket at the given index, clipped to the period.
    func range(at index: Int) -> DateInterval {
        let start = starts[index]
        let unclippedEnd =
            index + 1 < starts.count
            ? starts[index + 1]
            : calendar.date(byAdding: granularity.calendarComponent, value: 1, to: start)
                ?? interval.end
        return DateInterval(start: start, end: min(unclippedEnd, interval.end))
    }

    /// Index of the bucket a moment falls into, or nil when it is outside.
    func index(for date: Date) -> Int? {
        guard interval.contains(date) else { return nil }
        // Buckets are ordered, so a binary search keeps a year of hour rows cheap.
        var low = 0
        var high = starts.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if date < starts[middle] {
                high = middle - 1
            } else if middle + 1 < starts.count, date >= starts[middle + 1] {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    func label(at index: Int, locale: Locale = .current) -> String {
        let start = starts[index]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone

        switch granularity {
        case .hour:
            formatter.setLocalizedDateFormatFromTemplate("j")
            return formatter.string(from: start)
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            return formatter.string(from: start)
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            let end = range(at: index).end.addingTimeInterval(-1)
            return "\(formatter.string(from: start))–\(formatter.string(from: end))"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("LLL")
            return formatter.string(from: start)
        }
    }

    /// Short label for a chart axis, where space is tight.
    func axisLabel(at index: Int, locale: Locale = .current) -> String {
        let start = starts[index]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone

        switch granularity {
        case .hour:
            formatter.setLocalizedDateFormatFromTemplate("j")
            return formatter.string(from: start)
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("d")
            return formatter.string(from: start)
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            return formatter.string(from: start)
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("LLL")
            return formatter.string(from: start)
        }
    }
}
