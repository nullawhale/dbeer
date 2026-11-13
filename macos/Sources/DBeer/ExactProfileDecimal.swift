import Foundation

/// Bounded base-ten arithmetic for captured integer/decimal values. Every digit
/// is retained; approximate native floating-point types use a separate policy.
struct ExactProfileDecimal: Sendable, Comparable, Equatable {
    private(set) var sign: Int
    private(set) var digits: [UInt8]
    private(set) var scale: Int
    static let maximumDigits = 4_096
    static let zero = ExactProfileDecimal(sign: 0, digits: [0], scale: 0)

    init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumDigits + 32 else { return nil }
        var cursor = 0
        var negative = false
        if bytes[cursor] == 45 || bytes[cursor] == 43 {
            negative = bytes[cursor] == 45; cursor += 1
        }
        var coefficient: [UInt8] = []
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
            coefficient.append(bytes[cursor] - 48); cursor += 1
        }
        guard !coefficient.isEmpty else { return nil }
        var fractional = 0
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1
            let start = cursor
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
                coefficient.append(bytes[cursor] - 48); cursor += 1; fractional += 1
            }
            guard cursor > start else { return nil }
        }
        var exponent = 0
        if cursor < bytes.count, bytes[cursor] == 69 || bytes[cursor] == 101 {
            cursor += 1
            var exponentSign = 1
            if cursor < bytes.count, bytes[cursor] == 45 || bytes[cursor] == 43 {
                exponentSign = bytes[cursor] == 45 ? -1 : 1; cursor += 1
            }
            let start = cursor
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
                guard exponent <= Self.maximumDigits else { return nil }
                exponent = exponent * 10 + Int(bytes[cursor] - 48); cursor += 1
            }
            guard cursor > start, exponent <= Self.maximumDigits else { return nil }
            exponent *= exponentSign
        }
        guard cursor == bytes.count, coefficient.count <= Self.maximumDigits else { return nil }
        var resultScale = fractional - exponent
        if resultScale < 0 {
            guard coefficient.count - resultScale <= Self.maximumDigits else { return nil }
            coefficient.append(contentsOf: repeatElement(0, count: -resultScale)); resultScale = 0
        }
        guard resultScale <= Self.maximumDigits else { return nil }
        self.init(sign: negative ? -1 : 1, digits: coefficient, scale: resultScale)
    }

    private init(sign: Int, digits: [UInt8], scale: Int) {
        var digits = digits
        var scale = scale
        let first = digits.firstIndex(where: { $0 != 0 }) ?? max(0, digits.count - 1)
        digits = Array(digits[first...])
        while scale > 0, digits.count > 1, digits.last == 0 { digits.removeLast(); scale -= 1 }
        if digits.allSatisfy({ $0 == 0 }) { self.sign = 0; self.digits = [0]; self.scale = 0 }
        else { self.sign = sign; self.digits = digits; self.scale = scale }
    }

    var workSize: Int { digits.count + scale }

    var text: String {
        let coefficient = String(decoding: digits.map { $0 + 48 }, as: UTF8.self)
        let magnitude: String
        if scale == 0 { magnitude = coefficient }
        else if scale >= digits.count {
            magnitude = "0." + String(repeating: "0", count: scale - digits.count) + coefficient
        } else {
            let split = coefficient.index(coefficient.endIndex, offsetBy: -scale)
            magnitude = coefficient[..<split] + "." + coefficient[split...]
        }
        return (sign < 0 ? "-" : "") + magnitude
    }

    func adding(_ other: Self) -> Self? {
        if sign == 0 { return other }
        if other.sign == 0 { return self }
        let sharedScale = max(scale, other.scale)
        let left = digits + Array(repeating: 0, count: sharedScale - scale)
        let right = other.digits + Array(repeating: 0, count: sharedScale - other.scale)
        guard max(left.count, right.count) < Self.maximumDigits * 2 else { return nil }
        if sign == other.sign {
            return Self(sign: sign, digits: Self.add(left, right), scale: sharedScale)
        }
        let order = Self.compareMagnitude(left, right)
        if order == 0 { return .zero }
        return order > 0
            ? Self(sign: sign, digits: Self.subtract(left, right), scale: sharedScale)
            : Self(sign: other.sign, digits: Self.subtract(right, left), scale: sharedScale)
    }

    /// Nonterminating averages retain an explicit exact quotient.
    func average(count: Int) -> String? {
        guard count > 0, count <= GridProfileLimits.maximumCells else { return nil }
        if sign == 0 { return "0" }
        let division = Self.divide(digits, by: count)
        var remainder = division.remainder
        var divisor = count / Self.gcd(count, remainder)
        while divisor % 2 == 0 { divisor /= 2 }
        while divisor % 5 == 0 { divisor /= 5 }
        guard divisor == 1 else { return text + " / " + String(count) }
        var result = division.digits
        var additionalScale = 0
        while remainder != 0 {
            let expanded = remainder * 10
            result.append(UInt8(expanded / count)); remainder = expanded % count
            additionalScale += 1
        }
        return Self(sign: sign, digits: result, scale: scale + additionalScale).text
    }

    static func < (left: Self, right: Self) -> Bool {
        if left.sign != right.sign { return left.sign < right.sign }
        if left.sign == 0 { return false }
        let sharedScale = max(left.scale, right.scale)
        let a = left.digits + Array(repeating: 0, count: sharedScale - left.scale)
        let b = right.digits + Array(repeating: 0, count: sharedScale - right.scale)
        let order = compareMagnitude(a, b)
        return left.sign > 0 ? order < 0 : order > 0
    }

    private static func compareMagnitude(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        if a == b { return 0 }
        return a.lexicographicallyPrecedes(b) ? -1 : 1
    }
    private static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let length = max(a.count, b.count)
        var result = Array(repeating: UInt8(0), count: length + 1)
        var carry = 0
        for offset in 0..<length {
            let x = offset < a.count ? Int(a[a.count - 1 - offset]) : 0
            let y = offset < b.count ? Int(b[b.count - 1 - offset]) : 0
            let sum = x + y + carry
            result[length - offset] = UInt8(sum % 10); carry = sum / 10
        }
        result[0] = UInt8(carry)
        return result
    }
    private static func subtract(_ larger: [UInt8], _ smaller: [UInt8]) -> [UInt8] {
        var result = larger
        var borrow = 0
        for offset in 0..<larger.count {
            let index = larger.count - 1 - offset
            let y = offset < smaller.count ? Int(smaller[smaller.count - 1 - offset]) : 0
            var difference = Int(larger[index]) - y - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += 10 }
            result[index] = UInt8(difference)
        }
        return result
    }
    private static func divide(_ value: [UInt8], by divisor: Int) -> (digits: [UInt8], remainder: Int) {
        var remainder = 0
        var quotient: [UInt8] = []
        for digit in value {
            let number = remainder * 10 + Int(digit)
            quotient.append(UInt8(number / divisor)); remainder = number % divisor
        }
        return (quotient, remainder)
    }
    private static func gcd(_ left: Int, _ right: Int) -> Int {
        var a = left, b = right
        while b != 0 { let next = a % b; a = b; b = next }
        return a
    }
}
