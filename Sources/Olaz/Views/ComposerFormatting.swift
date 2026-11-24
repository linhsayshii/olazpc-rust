import AppKit
import SwiftUI

/// Rich-text editing in the composer (official "Định dạng tin nhắn"): the format of each run lives in the text storage
/// under `.zaloFormat` (the official style tokens, "b,i,c_db342e"), next to the attributes that draw it. Sending reads
/// the runs back as `TextStyle`s (`textProperties`).
extension NSAttributedString.Key {
    static let zaloFormat = NSAttributedString.Key("app.olaz.format")
}

extension ComposerTextView {
    /// What a run with `format` looks like in the field (mention runs keep their own look).
    static func attributes(for format: TextFormat) -> [NSAttributedString.Key: Any] {
        var attrs = baseAttributes
        guard !format.isPlain else { return attrs }
        attrs[.font] = ChatFormat.nsFont(format, base: font.pointSize)
        if format.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if format.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let hex = format.color, hex.count == 6, let v = UInt32(hex, radix: 16) {
            attrs[.foregroundColor] = NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                                              blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        attrs[.zaloFormat] = format.tokens.joined(separator: ",")
        return attrs
    }

    static func format(in storage: NSAttributedString, at index: Int) -> TextFormat {
        guard index >= 0, index < storage.length, let st = storage.attribute(.zaloFormat, at: index, effectiveRange: nil) as? String
        else { return TextFormat() }
        return TextFormat(tokens: st.split(separator: ",").map(String.init))
    }

    /// The styled runs of the field, as the official `styles` (UTF-16 ranges).
    static func styles(of storage: NSAttributedString) -> [TextStyle] {
        var out: [TextStyle] = []
        storage.enumerateAttribute(.zaloFormat, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let st = value as? String, !st.isEmpty, range.length > 0 else { return }
            if let last = out.last, last.st == st, last.start + last.len == range.location {
                out[out.count - 1].len += range.length
            } else {
                out.append(TextStyle(start: range.location, len: range.length, st: st))
            }
        }
        return out
    }

    /// Typing goes on in the format of the character before the caret (a mention's look is never carried on).
    static func typingAttributes(_ tv: NSTextView) -> [NSAttributedString.Key: Any] {
        guard let storage = tv.textStorage else { return baseAttributes }
        let caret = tv.selectedRange().location
        return attributes(for: format(in: storage, at: caret - 1))
    }
}

/// One formatting command of the bar / the shortcuts.
enum ComposerFormatCommand {
    case bold, italic, underline, strike
    case color(String?)
    case size(Int?)

    /// Whether `format` already has it (a toggle then turns it off).
    func isOn(_ format: TextFormat) -> Bool {
        switch self {
        case .bold: format.bold
        case .italic: format.italic
        case .underline: format.underline
        case .strike: format.strike
        case .color(let c): format.color == c
        case .size(let s): format.size == s
        }
    }

    func apply(to format: inout TextFormat, on: Bool) {
        switch self {
        case .bold: format.bold = on
        case .italic: format.italic = on
        case .underline: format.underline = on
        case .strike: format.strike = on
        case .color(let c): format.color = on ? c : nil
        case .size(let s): format.size = on ? s : nil
        }
    }
}

extension ComposerHandle {
    /// Applies `command` to the selection (toggling when the whole selection already has it), or to what is typed next.
    func format(_ command: ComposerFormatCommand) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var current = ComposerTextView.format(in: storage, at: -1)
            if let st = tv.typingAttributes[.zaloFormat] as? String {
                current = TextFormat(tokens: st.split(separator: ",").map(String.init))
            }
            let on: Bool = switch command {
            case .color(let c): c != nil
            case .size(let s): s != nil
            default: !command.isOn(current)
            }
            command.apply(to: &current, on: on)
            tv.typingAttributes = ComposerTextView.attributes(for: current)
            onFormatChange?()
            return
        }
        var allOn = true
        storage.enumerateAttribute(.zaloFormat, in: range) { value, _, stop in
            let f = TextFormat(tokens: (value as? String ?? "").split(separator: ",").map(String.init))
            if !command.isOn(f) { allOn = false; stop.pointee = true }
        }
        let on: Bool = switch command {
        case .color(let c): c != nil
        case .size(let s): s != nil
        default: !allOn
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        var runs: [(NSRange, TextFormat, Bool)] = []
        storage.enumerateAttributes(in: range) { attrs, run, _ in
            let f = TextFormat(tokens: (attrs[.zaloFormat] as? String ?? "").split(separator: ",").map(String.init))
            runs.append((run, f, attrs[.zaloMention] != nil))
        }
        for (run, old, isMention) in runs {
            var f = old
            command.apply(to: &f, on: on)
            if isMention {
                // A mention keeps its token look; only its format tokens change.
                if f.isPlain { storage.removeAttribute(.zaloFormat, range: run) }
                else { storage.addAttribute(.zaloFormat, value: f.tokens.joined(separator: ","), range: run) }
            } else {
                storage.setAttributes(ComposerTextView.attributes(for: f), range: run)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        onFormatChange?()
    }
}

/// "Định dạng tin nhắn": bold / italic / underline / strike, the official colors and sizes, for the selection or what is
/// typed next.
struct ComposerFormatBar: View {
    let handle: ComposerHandle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                tool("bold", "In đậm (⌘B)", .bold)
                tool("italic", "In nghiêng (⌘I)", .italic)
                tool("underline", "Gạch chân (⌘U)", .underline)
                tool("strikethrough", "Gạch ngang (⌘⇧X)", .strike)
            }
            HStack(spacing: 8) {
                Button { handle.format(.color(nil)) } label: {
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).help("Màu mặc định")
                ForEach(TextStyle.colors, id: \.token) { c in
                    Button { handle.format(.color(c.hex)) } label: {
                        Circle().fill(Color(hex: c.hex) ?? .primary).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain).help("Màu \(c.name.lowercased())")
                    .accessibilityLabel("Màu \(c.name.lowercased())")
                }
            }
            HStack(spacing: 6) {
                Button("Chữ nhỏ") { handle.format(.size(TextStyle.smallSize)) }
                Button("Chữ thường") { handle.format(.size(nil)) }
                Button("Chữ lớn") { handle.format(.size(TextStyle.largeSize)) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func tool(_ symbol: String, _ help: String, _ command: ComposerFormatCommand) -> some View {
        Button { handle.format(command) } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 30, height: 26)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }
}
