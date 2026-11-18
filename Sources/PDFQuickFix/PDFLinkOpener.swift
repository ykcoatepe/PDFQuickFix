import AppKit
import Foundation

/// Decides what a click on a link inside a PDF may do. PDFKit's default hands
/// any URL the document names to the system, which reaches every URL scheme an
/// installed app registers and local files.
enum PDFLinkPolicy {
    enum Decision: Equatable {
        case confirm
        case block
    }

    static func decision(for url: URL) -> Decision {
        switch url.scheme?.lowercased() {
        case "http", "https":
            webHost(of: url) == nil ? .block : .confirm
        case "mailto":
            mailRecipient(of: url) == nil ? .block : .confirm
        default:
            .block
        }
    }

    /// The part of the link a person should judge it by.
    static func destinationSummary(for url: URL) -> String {
        if url.scheme?.lowercased() == "mailto" { return mailRecipient(of: url) ?? "" }
        return webHost(of: url) ?? ""
    }

    /// The host as it will be contacted, and only when it is plain ASCII.
    /// `URL.host` decodes percent-escapes, so `%D0%B0pple.com` would be shown
    /// with a Cyrillic letter that reads as "apple.com"; international domains
    /// stay in their `xn--` form.
    private static func webHost(of url: URL) -> String? {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost,
              !host.isEmpty, !host.contains("%"), host.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !isDisguisedAddress(host)
        else { return nil }
        return host
    }

    /// `0x7f.1`, `2130706433` or `0177.0.0.1` all reach 127.0.0.1 without
    /// looking like it. A host made only of numbers must be a plain dotted quad.
    private static func isDisguisedAddress(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: true)
        func isNumber(_ label: Substring) -> Bool {
            let digits = label.hasPrefix("0x") ? label.dropFirst(2) : label
            return !label.isEmpty && digits.allSatisfy(\.isHexDigit) && (label.hasPrefix("0x") || label.allSatisfy(\.isNumber))
        }
        guard !labels.isEmpty, labels.allSatisfy(isNumber) else { return false }
        let isDottedQuad = labels.count == 4 && labels.allSatisfy { label in
            label.allSatisfy(\.isNumber) && (label == "0" || !label.hasPrefix("0")) && (Int(label) ?? 256) <= 255
        }
        return !isDottedQuad
    }

    /// The one recipient before the query. Recipients added through the query
    /// would not be named in the confirmation, so such links are refused.
    private static func mailRecipient(of url: URL) -> String? {
        let address = url.absoluteString.dropFirst("mailto:".count).prefix { $0 != "?" }
        guard !address.isEmpty, let decoded = address.removingPercentEncoding,
              decoded.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { return nil }
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !parameters.contains(where: { ["to", "cc", "bcc"].contains($0.name.lowercased()) }) else { return nil }
        return decoded
    }
}

@MainActor
enum PDFLinkOpener {
    enum Outcome: Equatable {
        case opened
        case declined
        case blocked
    }

    @discardableResult
    static func handleClick(on url: URL,
                            confirm: (URL) -> Bool = PDFLinkOpener.confirmOpening,
                            open: (URL) -> Void = { NSWorkspace.shared.open($0) },
                            reportBlocked: (URL) -> Void = { _ in NSSound.beep() }) -> Outcome
    {
        guard PDFLinkPolicy.decision(for: url) == .confirm else {
            reportBlocked(url)
            return .blocked
        }
        guard confirm(url) else { return .declined }
        open(url)
        return .opened
    }

    static func blockedMessage(for url: URL) -> String {
        let scheme = url.scheme.map { " (\($0):)" } ?? ""
        return "Blocked a link in this PDF\(scheme). PDFQuickFix opens only ordinary web and mail links."
    }

    /// Asked every time: a remembered "yes" would let any later document reach
    /// web hosts, local services included, with one click.
    static func confirmOpening(_ url: URL) -> Bool {
        let isWebLink = url.scheme?.lowercased() != "mailto"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isWebLink
            ? "Open the link to \(PDFLinkPolicy.destinationSummary(for: url))?"
            : "Write an email to \(PDFLinkPolicy.destinationSummary(for: url))?"
        let address = url.absoluteString
        alert.informativeText = address.count > 600 ? String(address.prefix(600)) + "…" : address
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
