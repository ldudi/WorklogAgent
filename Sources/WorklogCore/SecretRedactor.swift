import Foundation

public struct SecretRedactor {
    public init() {}

    public func redact(_ input: String) -> String {
        var output = input

        let rules: [(String, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"\b(?:sk|rk|pk)-[A-Za-z0-9_\-]{16,}\b"#, "[REDACTED_API_KEY]"),
            (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_AWS_ACCESS_KEY]"),
            (#"\beyJ[A-Za-z0-9_\-]+=*\.[A-Za-z0-9_\-]+=*\.[A-Za-z0-9_\-+/=]*\b"#, "[REDACTED_JWT]"),
            (#"(?i)\b(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#, "$1[REDACTED]"),
            (#"(?im)\b([A-Z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE[_-]?KEY)[A-Z0-9_]*)\s*[:=]\s*([^\s\"']{6,}|\"[^\"]{6,}\"|'[^']{6,}')"#, "$1=[REDACTED]")
        ]

        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
        }

        return output
    }
}
