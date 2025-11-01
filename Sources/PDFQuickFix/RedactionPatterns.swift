import Foundation

enum DefaultPatterns {
    static let iban = RedactionPattern(
        name: "IBAN",
        pattern: #"(?:\b[A-Z]{2}\d{2}[A-Z0-9]{4}\d{7}[A-Z0-9]{0,16}\b)"#
    )
    static let tckn = RedactionPattern(
        name: "TCKN (Turkey ID)",
        pattern: #"(?<!\d)\d{11}(?!\d)"#
    )
    static let pnr = RedactionPattern(
        name: "PNR (6 chars)",
        pattern: #"(?<![A-Z0-9])[A-Z0-9]{6}(?![A-Z0-9])"#
    )
    static let tail = RedactionPattern(
        name: "Aircraft Tail (TC-XYZ)",
        pattern: #"\bTC-[A-Z]{3,4}\b"#
    )
    
    static func defaults() -> [RedactionPattern] {
        [iban, tckn, pnr, tail]
    }
}
