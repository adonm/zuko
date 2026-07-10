import Foundation

/// Accepted external representation for a one-time pairing code. QR/deep links
/// carry only this short-lived secret; the long-lived endpoint ticket still
/// travels exclusively over the encrypted handoff stream.
public enum PairingLink {
    public static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "zuko", url.host?.lowercased() == "pair" else {
            return nil
        }
        if let queryCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value,
           let code = validate(queryCode) {
            return code
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return validate(path.removingPercentEncoding ?? path)
    }

    public static func code(from payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return code(from: url)
        }
        return validate(trimmed)
    }

    private static func validate(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...128).contains(trimmed.count), trimmed.contains(where: { $0.isLetter }) else {
            return nil
        }
        let allowedSeparators = CharacterSet(charactersIn: "-_ ")
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            let isASCIILetter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            return isASCIILetter || allowedSeparators.contains(scalar)
        }) else { return nil }
        return trimmed
    }
}
