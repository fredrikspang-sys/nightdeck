import Foundation

public struct NetworkShare: Sendable, Equatable, Identifiable {
    public var path: String
    public var label: String

    public var id: String { path }

    public init(path: String, label: String) {
        self.path = path
        self.label = label
    }
}

public struct NetworkSharePage: Sendable, Equatable {
    public var shares: [NetworkShare]
    public var actionURL: String
    public var submitName: String
    public var submitValue: String

    public init(shares: [NetworkShare], actionURL: String, submitName: String, submitValue: String) {
        self.shares = shares
        self.actionURL = actionURL
        self.submitName = submitName
        self.submitValue = submitValue
    }
}

public struct AddShareForm: Sendable, Equatable {
    public var url: String
    public var shareField: String
    public var userField: String
    public var passwordField: String
    public var pattern: String
    public var patternError: String

    public init(
        url: String,
        shareField: String,
        userField: String,
        passwordField: String,
        pattern: String,
        patternError: String
    ) {
        self.url = url
        self.shareField = shareField
        self.userField = userField
        self.passwordField = passwordField
        self.pattern = pattern
        self.patternError = patternError
    }

    /// Used when the player omits a field. The pattern is the one BluOS puts on `sharename`.
    public static let fallback = AddShareForm(
        url: "/cp/AddShare",
        shareField: "sharename",
        userField: "username",
        passwordField: "password",
        pattern: #"^\\\\(.*?)\\(.*)$"#,
        patternError: #"Share URL must be in the form \\computer\share"#
    )
}

public enum ShareName {
    /// Whole-string match. An unusable pattern falls back to `AddShareForm.fallback.pattern`.
    public static func matches(_ name: String, pattern: String) -> Bool {
        let primary = pattern.isEmpty ? AddShareForm.fallback.pattern : pattern
        if let matched = wholeMatch(name, pattern: primary) { return matched }
        guard primary != AddShareForm.fallback.pattern else { return false }
        return wholeMatch(name, pattern: AddShareForm.fallback.pattern) ?? false
    }

    private static func wholeMatch(_ name: String, pattern: String) -> Bool? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard range.location != NSNotFound, let match = expression.firstMatch(in: name, range: range) else {
            return false
        }
        return match.range.location == range.location && match.range.length == range.length
    }
}

public enum ShareForm {
    /// `application/x-www-form-urlencoded`. Spaces are `%20`, not `+`.
    public static func body(_ fields: [(String, String)]) -> String {
        fields.map { BluOSURL.queryEncode($0.0) + "=" + BluOSURL.queryEncode($0.1) }.joined(separator: "&")
    }

    /// Removes a submitted password from text we might show. Short strings are left alone
    /// so a one-letter password does not punch holes in an ordinary sentence.
    public static func redact(_ text: String, secret: String) -> String {
        guard secret.count >= 4, text.contains(secret) else { return text }
        return text.replacingOccurrences(of: secret, with: "••••")
    }
}

public enum ShareURL {
    /// Keeps scheme, port, path, and query. A host other than the player's is replaced.
    /// Userinfo is dropped so a crafted action cannot carry a secret.
    public static func pin(_ url: URL, toHost host: String) -> URL? {
        var player = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if player.hasPrefix("["), player.hasSuffix("]"), player.count >= 2 {
            player = String(player.dropFirst().dropLast())
        }
        guard !player.isEmpty, !player.contains("@"), !player.contains("/") else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let current = parts.host ?? ""
        if current.isEmpty || current.compare(player, options: .caseInsensitive) != .orderedSame {
            parts.host = player
        }
        parts.user = nil
        parts.password = nil
        return parts.url
    }
}

public enum ShareXML {
    public static func parseSharePage(_ xml: String) -> NetworkSharePage? {
        guard let root = parse(xml), root.name == "settings" else { return nil }
        guard let group = root.first(name: "menuGroup", id: "networkShares") else { return nil }
        guard let setting = group.first(name: "setting", id: "shares") else { return nil }
        return parseForm(html: setting.attrs["value"] ?? "")
    }

    public static func parseAddShareForm(_ xml: String) -> AddShareForm? {
        guard let root = parse(xml), root.name == "settings" else { return nil }
        guard let group = root.first(name: "menuGroup", id: "addShare") else { return nil }
        var url = group.attrs["url"] ?? ""
        var shareField = ""
        var userField = ""
        var passwordField = ""
        var pattern = ""
        var patternError = ""
        for setting in group.children where setting.name == "setting" {
            let id = setting.attrs["id"] ?? ""
            let name = setting.attrs["name"] ?? id
            guard !name.isEmpty else { continue }
            let style = (setting.attrs["style"] ?? "").lowercased()
            let fieldPattern = setting.attrs["pattern"] ?? ""
            if style == "password" || id == "password" || name == "password" {
                passwordField = name
            } else if id == "sharename" || name == "sharename" || !fieldPattern.isEmpty {
                shareField = name
                if pattern.isEmpty { pattern = fieldPattern }
                if patternError.isEmpty { patternError = setting.attrs["patternError"] ?? "" }
            } else if userField.isEmpty {
                userField = name
            }
        }
        let fallback = AddShareForm.fallback
        if url.isEmpty { url = fallback.url }
        if shareField.isEmpty { shareField = fallback.shareField }
        if userField.isEmpty { userField = fallback.userField }
        if passwordField.isEmpty { passwordField = fallback.passwordField }
        if pattern.isEmpty { pattern = fallback.pattern }
        if patternError.isEmpty { patternError = fallback.patternError }
        return AddShareForm(
            url: url,
            shareField: shareField,
            userField: userField,
            passwordField: passwordField,
            pattern: pattern,
            patternError: patternError
        )
    }

    private static func parseForm(html: String) -> NetworkSharePage {
        let source = stripStyle(html)
        let form = firstTag("form", in: source)?.attrs ?? [:]
        var shares: [NetworkShare] = []
        var labels: [String: String] = [:]
        for label in tags("label", in: source) {
            let key = label.attrs["for"] ?? ""
            if !key.isEmpty { labels[key] = htmlDecode(label.inner).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var submitName = ""
        var submitValue = ""
        for input in tags("input", in: source) {
            let type = (input.attrs["type"] ?? "").lowercased()
            if type == "submit" {
                if submitName.isEmpty { submitName = input.attrs["name"] ?? "" }
                if submitValue.isEmpty { submitValue = input.attrs["value"] ?? "" }
                continue
            }
            guard type == "checkbox" else { continue }
            let path = input.attrs["name"] ?? ""
            guard !path.isEmpty else { continue }
            let id = input.attrs["id"] ?? ""
            let label = labels[id] ?? ""
            shares.append(NetworkShare(path: path, label: label.isEmpty ? path : label))
        }
        if submitName.isEmpty { submitName = "remove" }
        if submitValue.isEmpty { submitValue = "Remove selected shares" }
        return NetworkSharePage(
            shares: shares,
            actionURL: form["action"] ?? "",
            submitName: submitName,
            submitValue: submitValue
        )
    }

    private static func stripStyle(_ html: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<style\b[^>]*>.*?</style>"#
        ) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private struct Tag {
        var attrs: [String: String]
        var inner: String
    }

    private static func firstTag(_ name: String, in html: String) -> Tag? {
        tags(name, in: html).first
    }

    private static func tags(_ name: String, in html: String) -> [Tag] {
        let pattern = "<\(name)\\b([^>]*)>(?:([^<]*)</\(name)>)?"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        return expression.matches(in: html, range: range).map { match in
            let rawAttrs = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let inner = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            return Tag(attrs: attributes(rawAttrs), inner: inner)
        }
    }

    private static func attributes(_ source: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = source as NSString
        var attrs: [String: String] = [:]
        for match in expression.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 5 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let valueRange: NSRange
            if match.range(at: 2).location != NSNotFound {
                valueRange = match.range(at: 2)
            } else if match.range(at: 3).location != NSNotFound {
                valueRange = match.range(at: 3)
            } else if match.range(at: 4).location != NSNotFound {
                valueRange = match.range(at: 4)
            } else {
                continue
            }
            attrs[key] = htmlDecode(ns.substring(with: valueRange))
        }
        return attrs
    }

    static func htmlDecode(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "&" {
                let rest = raw[raw.index(after: index)...]
                if let semi = rest.firstIndex(of: ";"), raw.distance(from: index, to: semi) <= 16 {
                    let token = String(raw[raw.index(after: index)..<semi])
                    if let decoded = entity(token) {
                        result.append(decoded)
                        index = raw.index(after: semi)
                        continue
                    }
                }
            }
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return result
    }

    private static func entity(_ token: String) -> String? {
        switch token {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        if token.hasPrefix("#x") || token.hasPrefix("#X"), let value = UInt32(token.dropFirst(2), radix: 16),
           let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if token.hasPrefix("#"), let value = UInt32(token.dropFirst()), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        return nil
    }

    private static func parse(_ xml: String) -> XNode? {
        guard xml.utf8.count <= 8_000_000 else { return nil }
        if xml.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil { return nil }
        if xml.range(of: "<!ENTITY", options: .caseInsensitive) != nil { return nil }
        let collector = XCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = collector.root else { return nil }
        return root
    }
}

private final class XNode {
    var name: String
    var attrs: [String: String]
    var children: [XNode] = []

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func first(name: String, id: String) -> XNode? {
        if self.name == name && attrs["id"] == id { return self }
        for child in children {
            if let found = child.first(name: name, id: id) { return found }
        }
        return nil
    }
}

private final class XCollector: NSObject, XMLParserDelegate {
    var stack: [XNode] = []
    var root: XNode?

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(XNode(name: name, attrs: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {}

    func parser(
        _ parser: XMLParser,
        didEndElement name: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let node = stack.popLast() else { return }
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }
}
