import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Errors surfaced while parsing a WebDAV multi-status body.
public enum WebDAVParseError: Error, Equatable {
    /// `XMLParser` reported a syntax error at the given line.
    case malformedXML(line: Int)
}

/// Parses an ownCloud Classic / SabreDAV `207 Multi-Status` PROPFIND body into
/// `[WebDAVItem]`, preserving document order (the server returns the requested
/// collection first, then its children).
///
/// Implemented on top of Foundation's event-driven `XMLParser` so it stays
/// available on Linux (via `FoundationXML`) for the AC-2 backend-contract tier.
/// Namespace processing is enabled, so elements are matched on
/// (namespaceURI, localName) rather than brittle `d:`/`oc:` prefixes.
public final class WebDAVMultiStatusParser: NSObject {

    private static let davNS = "DAV:"
    private static let ownCloudNS = "http://owncloud.org/ns"

    public override init() {
        super.init()
    }

    public func parse(_ data: Data) throws -> [WebDAVItem] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = MultiStatusDelegate()
        parser.delegate = delegate

        guard parser.parse(), delegate.parseError == nil else {
            let line = parser.lineNumber
            throw WebDAVParseError.malformedXML(line: line)
        }
        return delegate.items
    }
}

/// Accumulates one `WebDAVItem` per `<d:response>`. Only the `200 OK` propstat
/// carries the real properties; other propstats (e.g. `404` for absent props)
/// are ignored, matching how clients read multistatus.
private final class MultiStatusDelegate: NSObject, XMLParserDelegate {

    private(set) var items: [WebDAVItem] = []
    private(set) var parseError: Error?

    // Per-<response> accumulation.
    private var inResponse = false
    private var href = ""
    private var isDirectory = false
    private var fileID: String?
    private var etag: String?
    private var contentLength: Int?
    private var ocSize: Int?
    private var contentType: String?
    private var lastModified: Date?
    private var permissions: String?
    private var isFavorite = false

    // Character-collection state.
    private var currentValue = ""
    private var collectingChars = false

    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let ns = namespaceURI ?? ""
        switch (ns, elementName) {
        case ("DAV:", "response"):
            resetResponseState()
            inResponse = true
        case ("DAV:", "collection"):
            if inResponse { isDirectory = true }
        default:
            break
        }
        // Start collecting text for any leaf element we care about.
        currentValue = ""
        collectingChars = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingChars {
            currentValue += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let ns = namespaceURI ?? ""
        let text = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard inResponse else {
            collectingChars = false
            return
        }

        switch (ns, elementName) {
        case ("DAV:", "href"):
            href = text
        case ("DAV:", "getetag"):
            etag = text.isEmpty ? nil : text
        case ("DAV:", "getcontentlength"):
            contentLength = Int(text)
        case ("DAV:", "getcontenttype"):
            contentType = text.isEmpty ? nil : text
        case ("DAV:", "getlastmodified"):
            lastModified = Self.rfc1123Formatter.date(from: text)
        case (MultiStatusDelegate.ownCloudNSString, "id"):
            fileID = text.isEmpty ? nil : text
        case (MultiStatusDelegate.ownCloudNSString, "size"):
            ocSize = Int(text)
        case (MultiStatusDelegate.ownCloudNSString, "permissions"):
            permissions = text.isEmpty ? nil : text
        case (MultiStatusDelegate.ownCloudNSString, "favorite"):
            isFavorite = (text == "1")
        case ("DAV:", "response"):
            items.append(makeItem())
            inResponse = false
        default:
            break
        }
        collectingChars = false
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: - Helpers

    private static let ownCloudNSString = "http://owncloud.org/ns"

    private func resetResponseState() {
        href = ""
        isDirectory = false
        fileID = nil
        etag = nil
        contentLength = nil
        ocSize = nil
        contentType = nil
        lastModified = nil
        permissions = nil
        isFavorite = false
    }

    private func makeItem() -> WebDAVItem {
        WebDAVItem(
            href: href,
            isDirectory: isDirectory,
            fileID: fileID,
            etag: etag,
            contentLength: contentLength,
            ocSize: ocSize,
            contentType: contentType,
            lastModified: lastModified,
            permissions: permissions,
            isFavorite: isFavorite
        )
    }
}
