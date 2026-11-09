import Foundation

/// XML ⇄ modello comune.
/// Convenzioni: gli attributi diventano chiavi "@nome", il testo misto a elementi figli diventa "#text",
/// gli elementi con lo stesso nome ripetuti diventano un array.
enum XMLCodec {
    static func parse(_ data: Data) throws -> DataNode {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let succeeded = parser.parse()
        guard succeeded, let root = builder.root else {
            let reason = builder.error?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "documento vuoto"
            throw FlipError.parse("XML non valido: \(reason)")
        }
        return .object([(key: root.name, value: root.node)])
    }

    // MARK: - Scrittura

    static func write(_ node: DataNode) -> String {
        var output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if case .object(let pairs) = node, pairs.count == 1,
           !pairs[0].key.hasPrefix("@"), pairs[0].key != "#text", !pairs[0].value.isArray {
            emit(name: pairs[0].key, value: pairs[0].value, indent: 0, into: &output)
        } else if node.isArray {
            emit(name: "root", value: .object([(key: "item", value: node)]), indent: 0, into: &output)
        } else {
            emit(name: "root", value: node, indent: 0, into: &output)
        }
        return output
    }

    private static func emit(name: String, value: DataNode, indent: Int, into output: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let tag = elementName(name)
        switch value {
        case .array(let items):
            for item in items {
                if item.isArray {
                    emit(name: tag, value: .object([(key: "item", value: item)]), indent: indent, into: &output)
                } else {
                    emit(name: tag, value: item, indent: indent, into: &output)
                }
            }
        case .object(let pairs):
            var attributes = ""
            var text: String?
            var children = [(key: String, value: DataNode)]()
            for pair in pairs {
                if pair.key.hasPrefix("@"), pair.key.count > 1, pair.value.isScalar {
                    let attributeName = elementName(String(pair.key.dropFirst()))
                    attributes += " \(attributeName)=\"\(escape(pair.value.scalarText, attribute: true))\""
                } else if pair.key == "#text", pair.value.isScalar {
                    text = pair.value.scalarText
                } else {
                    children.append(pair)
                }
            }
            if children.isEmpty {
                if let text = text {
                    output += "\(pad)<\(tag)\(attributes)>\(escape(text, attribute: false))</\(tag)>\n"
                } else {
                    output += "\(pad)<\(tag)\(attributes)/>\n"
                }
            } else {
                output += "\(pad)<\(tag)\(attributes)>\n"
                if let text = text, !text.isEmpty {
                    output += "\(pad)  \(escape(text, attribute: false))\n"
                }
                for child in children {
                    emit(name: child.key, value: child.value, indent: indent + 1, into: &output)
                }
                output += "\(pad)</\(tag)>\n"
            }
        case .null:
            output += "\(pad)<\(tag)/>\n"
        default:
            output += "\(pad)<\(tag)>\(escape(value.scalarText, attribute: false))</\(tag)>\n"
        }
    }

    /// Rende valido un nome di elemento XML.
    private static func elementName(_ raw: String) -> String {
        var name = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." {
                name.unicodeScalars.append(scalar)
            } else {
                name += "_"
            }
        }
        if name.isEmpty { return "_" }
        if let first = name.unicodeScalars.first, !(CharacterSet.letters.contains(first) || first == "_") {
            name = "_" + name
        }
        return name
    }

    private static func escape(_ text: String, attribute: Bool) -> String {
        var result = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return result
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    struct Frame {
        var name: String
        var attributes: [(key: String, value: String)]
        var children: [(name: String, node: DataNode)] = []
        var text = ""
    }

    var stack = [Frame]()
    var root: (name: String, node: DataNode)?
    var error: Error?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let attributes = attributeDict
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
        stack.append(Frame(name: elementName, attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        let node = XMLTreeBuilder.build(frame)
        if stack.isEmpty {
            root = (name: frame.name, node: node)
        } else {
            stack[stack.count - 1].children.append((name: frame.name, node: node))
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    static func build(_ frame: Frame) -> DataNode {
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if frame.attributes.isEmpty && frame.children.isEmpty {
            return text.isEmpty ? .null : .string(text)
        }
        var pairs = [(key: String, value: DataNode)]()
        var positions = [String: Int]()
        for attribute in frame.attributes {
            pairs.append((key: "@" + attribute.key, value: .string(attribute.value)))
        }
        for child in frame.children {
            if let position = positions[child.name] {
                if case .array(var items) = pairs[position].value {
                    items.append(child.node)
                    pairs[position].value = .array(items)
                } else {
                    pairs[position].value = .array([pairs[position].value, child.node])
                }
            } else {
                positions[child.name] = pairs.count
                pairs.append((key: child.name, value: child.node))
            }
        }
        if !text.isEmpty {
            pairs.append((key: "#text", value: .string(text)))
        }
        return .object(pairs)
    }
}
