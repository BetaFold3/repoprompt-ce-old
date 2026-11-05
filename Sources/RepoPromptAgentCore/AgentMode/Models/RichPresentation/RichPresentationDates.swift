import Foundation

/// Exact instant parsed from an RFC 3339 timestamp; compares by actual UTC instant.
package struct RichPresentationInstant: Comparable, Hashable {
    package let secondsSince1970: Int64
    package let nanoseconds: Int32

    package var date: Date {
        Date(timeIntervalSince1970: Double(secondsSince1970) + Double(nanoseconds) / 1_000_000_000)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.secondsSince1970, lhs.nanoseconds) < (rhs.secondsSince1970, rhs.nanoseconds)
    }
}

/// Strict, allocation-light parsers for the schema's date formats. Calendar fields must be real dates.
package enum RichPresentationDateParser {
    /// RFC 3339 `date-time`: `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
    /// Accepts `T`/`t` and `Z`/`z`; fraction is 1–9 digits; leap second `60` is rejected.
    package static func instant(rfc3339 text: String) -> RichPresentationInstant? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20,
              let date = calendarDate(bytes, at: 0),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t"),
              let hour = number(bytes, at: 11, digits: 2), hour <= 23,
              bytes[13] == UInt8(ascii: ":"),
              let minute = number(bytes, at: 14, digits: 2), minute <= 59,
              bytes[16] == UInt8(ascii: ":"),
              let second = number(bytes, at: 17, digits: 2), second <= 59
        else { return nil }

        var index = 19
        var nanoseconds = 0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            var digitCount = 0
            while index < bytes.count, let digit = digitValue(bytes[index]) {
                guard digitCount < 9 else { return nil }
                nanoseconds = nanoseconds * 10 + digit
                digitCount += 1
                index += 1
            }
            guard digitCount > 0 else { return nil }
            for _ in digitCount ..< 9 {
                nanoseconds *= 10
            }
        }

        guard index < bytes.count else { return nil }
        var offsetSeconds = 0
        switch bytes[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            index += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign = bytes[index] == UInt8(ascii: "+") ? 1 : -1
            guard index + 6 == bytes.count,
                  let offsetHour = number(bytes, at: index + 1, digits: 2), offsetHour <= 23,
                  bytes[index + 3] == UInt8(ascii: ":"),
                  let offsetMinute = number(bytes, at: index + 4, digits: 2), offsetMinute <= 59
            else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
            index += 6
        default:
            return nil
        }
        guard index == bytes.count else { return nil }

        let days = daysSince1970(year: date.year, month: date.month, day: date.day)
        let seconds = Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return RichPresentationInstant(secondsSince1970: seconds, nanoseconds: Int32(nanoseconds))
    }

    /// `YYYY-MM-DD` naming a real proleptic Gregorian calendar date.
    package static func isValidCalendarDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 10 && calendarDate(bytes, at: 0) != nil
    }

    private static func calendarDate(_ bytes: [UInt8], at start: Int) -> (year: Int, month: Int, day: Int)? {
        guard bytes.count >= start + 10,
              let year = number(bytes, at: start, digits: 4),
              bytes[start + 4] == UInt8(ascii: "-"),
              let month = number(bytes, at: start + 5, digits: 2), (1 ... 12).contains(month),
              bytes[start + 7] == UInt8(ascii: "-"),
              let day = number(bytes, at: start + 8, digits: 2),
              day >= 1, day <= daysInMonth(year: year, month: month)
        else { return nil }
        return (year, month, day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days from 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func number(_ bytes: [UInt8], at start: Int, digits: Int) -> Int? {
        guard start + digits <= bytes.count else { return nil }
        var value = 0
        for offset in 0 ..< digits {
            guard let digit = digitValue(bytes[start + offset]) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }
}
