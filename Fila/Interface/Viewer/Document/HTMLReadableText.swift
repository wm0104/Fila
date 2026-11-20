import Foundation
import libxml2.HTMLparser

/// Last resort when WebContent cannot stay alive. Parse only the supplied bytes:
/// no base URL, resource loader, XML DTD processing, browser or attributed-HTML importer.
/// The cap applies *before* building the tree, not after extracting the text.
enum HTMLReadableText {
    static let byteLimit = 256 * 1024

    static func body(from bytes: Data, truncated: Bool = false) -> String {
        let head = Data(bytes.prefix(byteLimit))
        let decoded = TextEncoding.decode(head, allowingTruncation: truncated || bytes.count > byteLimit)
        let utf8 = Array(decoded.text.utf8)
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NODEFDTD.rawValue | HTML_PARSE_NOERROR.rawValue
            | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_IGNORE_ENC.rawValue
        let document = utf8.withUnsafeBytes { buffer in
            htmlReadMemory(buffer.bindMemory(to: CChar.self).baseAddress, Int32(buffer.count), nil, "UTF-8", Int32(options))
        }
        guard let document else { return "" }
        defer { xmlFreeDoc(document) }
        var result = "", separator = ""

        func appendText(_ text: String) {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 9, 10, 12, 13, 32:
                    if separator.isEmpty { separator = " " }
                default:
                    if !separator.isEmpty {
                        if !result.isEmpty { result += separator }
                        separator = ""
                    }
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        func visit(_ first: xmlNodePtr?) {
            var current = first
            while let node = current {
                current = node.pointee.next
                if node.pointee.type == XML_TEXT_NODE, let text = node.pointee.content {
                    appendText(String(cString: text))
                    continue
                }
                guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { continue }
                let tag = String(cString: name)
                guard !excluded.contains(tag), xmlHasProp(node, "hidden") == nil else { continue }
                let block = blocks.contains(tag)
                if block { separator = "\n" }
                if tag == "li" { appendText("• ") }
                visit(node.pointee.children)
                if block { separator = "\n" }
                if (tag == "td" || tag == "th"), separator.isEmpty { separator = " " }
            }
        }
        visit(xmlDocGetRootElement(document))
        return result
    }

    private static let excluded: Set<String> = ["head", "script", "style", "template", "iframe", "frameset", "frame", "object", "embed", "svg", "canvas", "audio", "video"]
    private static let blocks: Set<String> = ["address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tr", "ul"]
}
