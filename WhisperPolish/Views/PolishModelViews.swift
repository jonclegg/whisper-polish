import SwiftUI

/// The card at the top of the notes list until the polish model is on the
/// phone: an offer to download it, then a progress ring with Cancel, or Try
/// again after a failure.
struct PolishModelCard: View {
    @Environment(OnDevicePolishDownload.self) private var download

    var body: some View {
        HStack(spacing: 14) {
            PolishModelRing(state: download.state, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.polishTeal.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PolishModelCard")
    }

    private var title: String {
        switch download.state {
        case .notDownloaded, .installed: "Polish on your iPhone"
        case .downloading: "Downloading the Polish model"
        case .failed: "Polish model download failed"
        }
    }

    private var detail: String {
        switch download.state {
        case .notDownloaded, .installed:
            "One-time \(OnDevicePolishDownload.sizeText) download. Then Polish works in the keyboard with no server and no account."
        case .downloading(let fraction):
            "\(PolishModelRing.megabytes(fraction)) of \(OnDevicePolishDownload.sizeText). Keep the app open until it finishes."
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private var action: some View {
        switch download.state {
        case .notDownloaded, .installed:
            PolishModelButton(title: "Download", systemImage: "arrow.down", prominent: true) { download.start() }
        case .downloading:
            PolishModelButton(title: "Cancel", systemImage: "xmark", prominent: false) { download.cancel() }
        case .failed:
            PolishModelButton(title: "Try again", systemImage: "arrow.counterclockwise", prominent: true) { download.start() }
        }
    }
}

/// The Settings row: the same states, plus "installed" once it's done.
struct PolishModelRow: View {
    @Environment(OnDevicePolishDownload.self) private var download

    var body: some View {
        HStack(spacing: 12) {
            PolishModelRing(state: download.state, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch download.state {
            case .notDownloaded:
                PolishModelButton(title: "Download", systemImage: "arrow.down", prominent: true) { download.start() }
            case .downloading:
                PolishModelButton(title: "Cancel", systemImage: "xmark", prominent: false) { download.cancel() }
            case .failed:
                PolishModelButton(title: "Try again", systemImage: "arrow.counterclockwise", prominent: true) { download.start() }
            case .installed:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch download.state {
        case .notDownloaded: "On-device Polish"
        case .downloading(let fraction): "Downloading \(Int((fraction * 100).rounded()))%"
        case .installed: "Polish model installed"
        case .failed: "Download failed"
        }
    }

    private var detail: String {
        switch download.state {
        case .notDownloaded: "One-time \(OnDevicePolishDownload.sizeText) download"
        case .downloading(let fraction): "\(PolishModelRing.megabytes(fraction)) of \(OnDevicePolishDownload.sizeText)"
        case .installed: "Polish runs in the keyboard, on this iPhone"
        case .failed(let message): message
        }
    }
}

/// A sparkle while waiting, a filling ring with the percent while downloading,
/// and a check once installed.
struct PolishModelRing: View {
    let state: OnDevicePolishDownload.State
    let size: CGFloat

    /// Whole megabytes, so the text doesn't change width with every chunk.
    static func megabytes(_ fraction: Double) -> String {
        "\(Int(fraction * Double(OnDevicePolishModel.byteCount) / 1_000_000)) MB"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.polishTealSoft)
            switch state {
            case .downloading(let fraction):
                Circle()
                    .stroke(Color.polishTeal.opacity(0.15), lineWidth: size / 12)
                    .padding(size / 24)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Color.polishTeal, style: StrokeStyle(lineWidth: size / 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size / 24)
                    .animation(.easeOut(duration: 0.25), value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.polishTeal)
            case .installed:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Color.polishTeal)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.orange)
            case .notDownloaded:
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.polishTeal)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PolishModelButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? Color.polishTeal : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
