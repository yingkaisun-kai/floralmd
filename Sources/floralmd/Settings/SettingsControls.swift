// Modified from Edmund by Yingkai Sun for FloralMD.
// Shared Settings view helpers.

import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(EdgeInsets(top: 28, leading: 30, bottom: 32, trailing: 30))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String?
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionTitle(title, symbol: symbol)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

struct SettingsSectionTitle: View {
    let title: String
    let symbol: String?

    init(_ title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct SettingsStatusBadge: View {
    enum Tone {
        case neutral
        case positive
        case warning
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(backgroundStyle))
            .accessibilityLabel(text)
    }

    private var foregroundStyle: Color {
        switch tone {
        case .neutral: .secondary
        case .positive: .green
        case .warning: .orange
        }
    }

    private var backgroundStyle: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.08)
        case .positive: .green.opacity(0.14)
        case .warning: .orange.opacity(0.14)
        }
    }
}

extension View {
    func settingsSupportingText() -> some View {
        foregroundStyle(.secondary)
            .controlSize(.small)
            .fixedSize(horizontal: false, vertical: true)
    }
}
