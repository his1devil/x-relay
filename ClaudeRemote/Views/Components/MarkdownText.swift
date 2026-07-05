import SwiftUI

/// Inline-markdown renderer (bold, italic, inline code, links) via
/// `AttributedString`'s parser — synchronous, so layout heights are stable.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String
    var color: Color
    var size: CGFloat = 14.5
    var weight: Font.Weight = .regular
    /// Hug content width (user-bubble mode) instead of filling the container.
    var hugging: Bool = false

    var body: some View {
        Text(attributed)
            .font(AppFont.sans(size, weight))
            .foregroundStyle(color)
            .lineSpacing(4)
            .tint(theme.blurple)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: hugging ? nil : .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if var a = try? AttributedString(markdown: text, options: options) {
            for run in a.runs where run.inlinePresentationIntent == .code {
                a[run.range].font = AppFont.mono(size - 1.5)
                a[run.range].foregroundColor = theme.claude
                a[run.range].backgroundColor = theme.codebg
            }
            return a
        }
        return AttributedString(text)
    }
}
