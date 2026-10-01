import SwiftUI

/// The transcript with words the recognizer was unsure about underlined.
/// Tapping one hands it to `onTap` so the user can fix or keep it.
struct FlaggedTranscriptText: View {
    let transcript: Transcript
    var onTap: (FlaggedWord) -> Void

    private static let scheme = "whisperpolish-flag"

    var body: some View {
        Text(attributed)
            .font(.body)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme else { return .systemAction }
                if let location = url.host.flatMap(Int.init),
                   let flag = transcript.flags.first(where: { $0.location == location }) {
                    onTap(flag)
                }
                return .handled
            })
    }

    private var attributed: AttributedString {
        var attributed = AttributedString(transcript.text)
        for flag in transcript.flags {
            guard let range = Range(flag.range, in: transcript.text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed),
                  let url = URL(string: "\(Self.scheme)://\(flag.location)") else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].swiftUI.underlineStyle = Text.LineStyle(pattern: .dot, color: .polishTeal)
        }
        return attributed
    }
}
