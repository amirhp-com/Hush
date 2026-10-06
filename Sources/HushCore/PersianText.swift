import Foundation

public enum PersianText {
    /// Conservative cleanup for Persian transcripts: Arabic letter forms, spacing around
    /// punctuation and the zero-width non-joiner after the «می» / «نمی» verb prefix.
    public static func normalize(_ input: String) -> String {
        var t = input.precomposedStringWithCanonicalMapping
        let map: [String: String] = ["ي": "ی", "ى": "ی", "ك": "ک", "ة": "ه", "٤": "۴", "٥": "۵", "٦": "۶"]
        for (a, b) in map { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " +([،؛؟.!:])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "([،؛؟])(?=[^\\s\\n])", with: "$1 ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(^|[\\s«(])(ن?می) (?=[\\u0600-\\u06FF])", with: "$1$2\u{200C}", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    public static func normalizeForSearch(_ input: String) -> String {
        normalize(input).replacingOccurrences(of: "\u{200C}", with: " ").lowercased()
    }
}

public enum Versions {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let clean: (String) -> [Int] = { v in
            (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = clean(candidate), b = clean(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
