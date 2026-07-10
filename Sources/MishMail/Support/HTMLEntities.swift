import Foundation

extension String {
    /// Decodes HTML character references — numeric ("&#39;", "&#x2019;") and
    /// the common named ones ("&amp;", "&quot;", …). Gmail snippets arrive
    /// with these encoded, and stripped HTML bodies carry them too; anything
    /// the UI shows should pass through here exactly once.
    func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var rest = Substring(self)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            let body = rest.dropFirst()
            // Longest reference we accept: "&#x10FFFF;" → 8 chars + ";".
            guard let semi = body.prefix(9).firstIndex(of: ";"),
                  let decoded = Self.decodeEntity(body[..<semi]) else {
                result.append("&")
                rest = body
                continue
            }
            result.append(decoded)
            rest = rest[rest.index(after: semi)...]
        }
        result += rest
        return result
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(entity)]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        // Non-breaking and thin spaces become plain spaces: snippets are
        // single-line previews, so preserving no-break semantics only breaks
        // truncation.
        "nbsp": " ", "thinsp": " ", "ensp": " ", "emsp": " ",
        "shy": "", "zwnj": "", "zwj": "",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "sect": "\u{00A7}",
        "para": "\u{00B6}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "frasl": "\u{2044}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}",
        "prime": "\u{2032}", "Prime": "\u{2033}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
        "harr": "\u{2194}", "minus": "\u{2212}", "lowast": "\u{2217}",
        "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}", "asymp": "\u{2248}",
        "infin": "\u{221E}", "sum": "\u{2211}", "prod": "\u{220F}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}",
        "delta": "\u{03B4}", "epsilon": "\u{03B5}", "lambda": "\u{03BB}",
        "mu": "\u{03BC}", "pi": "\u{03C0}", "sigma": "\u{03C3}", "omega": "\u{03C9}",
    ]
}
