import Foundation

struct FindReplaceRule: Identifiable, Hashable {
    let id = UUID()
    var find: String
    var replace: String
}

struct RedactionPattern: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var regex: NSRegularExpression
    
    init(name: String, pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
        self.name = name
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }
}

struct QuickFixOptions {
    var doOCR: Bool = true
    var dpi: CGFloat = 300
    var redactionPadding: CGFloat = 2.0
}
