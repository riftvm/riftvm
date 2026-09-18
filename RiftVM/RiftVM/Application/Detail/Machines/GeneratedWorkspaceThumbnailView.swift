//
//  GeneratedWorkspaceThumbnailView.swift
//  RiftVM
//
//  Moved out of the machine card when the generic-machine area was removed;
//  the app settings preview and generated covers still use it.
//

import SwiftUI

#if arch(arm64)
enum VMGeneratedThumbnailStyle: String, CaseIterable, Identifiable {
    case aurora, midnight, ocean, sunset, graphite, paper, terminal, editorial, neon, mono

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct GeneratedMachineThumbnailView: View {
    let title: String
    let type: VMOSType
    let style: VMGeneratedThumbnailStyle

    var body: some View {
        ZStack {
            background
            switch style {
            case .aurora:
                VMAuroraThumbnailView(title: title, type: type)
            case .midnight:
                titleText(.system(size: 43, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            case .ocean:
                titleText(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .blue.opacity(0.7), radius: 14)
            case .sunset:
                titleText(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            case .graphite:
                titleText(.system(size: 42, weight: .medium, design: .default)).foregroundStyle(.white.opacity(0.92))
            case .paper:
                VStack(spacing: 6) {
                    titleText(.system(size: 44, weight: .bold, design: .serif)).foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.14))
                    Rectangle().fill(Color.orange).frame(width: 42, height: 3)
                }
            case .terminal:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Circle().fill(.yellow).frame(width: 7, height: 7)
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    titleText(.system(size: 38, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.45, green: 1, blue: 0.62))
                    Text("$ riftvm run")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .editorial:
                VStack(spacing: 5) {
                    Text(type == .linux ? "LINUX VIRTUAL MACHINE" : "MAC VIRTUAL MACHINE")
                        .font(.system(size: 9, weight: .semibold, design: .serif))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.55))
                    titleText(.system(size: 48, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                }
            case .neon:
                ZStack {
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.pink).offset(x: 3, y: 2)
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.cyan).offset(x: -2, y: -1)
                    titleText(.system(size: 46, weight: .black, design: .monospaced)).foregroundStyle(.white)
                }
            case .mono:
                VStack(alignment: .leading, spacing: 8) {
                    Text(type == .linux ? "LINUX" : "MACOS").font(.caption.monospaced().weight(.bold)).tracking(3)
                    titleText(.system(size: 45, weight: .black, design: .default))
                }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if style == .aurora {
            Color.clear
        } else {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var palette: [Color] {
        switch style {
        case .aurora: [.indigo, .purple, .blue]
        case .midnight: [Color(red: 0.03, green: 0.05, blue: 0.11), Color(red: 0.10, green: 0.14, blue: 0.24)]
        case .ocean: [Color(red: 0.02, green: 0.28, blue: 0.48), Color(red: 0.05, green: 0.65, blue: 0.70)]
        case .sunset: [Color(red: 0.94, green: 0.27, blue: 0.30), Color(red: 0.98, green: 0.60, blue: 0.24)]
        case .graphite: [Color(red: 0.12, green: 0.13, blue: 0.15), Color(red: 0.34, green: 0.36, blue: 0.40)]
        case .paper: [Color(red: 0.98, green: 0.95, blue: 0.88), Color(red: 0.91, green: 0.86, blue: 0.76)]
        case .terminal: [Color(red: 0.02, green: 0.04, blue: 0.04), Color(red: 0.04, green: 0.10, blue: 0.08)]
        case .editorial: [Color(red: 0.19, green: 0.08, blue: 0.12), Color(red: 0.48, green: 0.17, blue: 0.19)]
        case .neon: [Color(red: 0.06, green: 0.02, blue: 0.16), Color(red: 0.16, green: 0.03, blue: 0.25)]
        case .mono: [Color.black, Color(red: 0.18, green: 0.18, blue: 0.18)]
        }
    }

    private func titleText(_ font: Font) -> some View {
        Text(title.uppercased())
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .padding(.horizontal, 22)
    }
}

private struct VMAuroraThumbnailView: View {
    let title: String
    let type: VMOSType

    var body: some View {
        ZStack {
            LinearGradient(
                colors: identity.palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(identity.glow.opacity(0.34))
                .frame(width: 190, height: 190)
                .blur(radius: 34)
                .offset(x: 125, y: -65)

            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 130, height: 130)
                .blur(radius: 20)
                .offset(x: -145, y: 90)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(identity.platform, systemImage: identity.smallSymbol)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.13), in: Capsule())

                    Text(displayTitle)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                        .multilineTextAlignment(.leading)

                    Text(identity.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: identity.largeSymbol)
                    .font(.system(size: 54, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 72)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.platform), \(title)")
    }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.localizedCaseInsensitiveContains(identity.platform) else {
            return identity.platform
        }
        return trimmed.isEmpty ? identity.platform : trimmed
    }

    private var identity: VMAuroraThumbnailIdentity {
        VMAuroraThumbnailIdentity(title: title, type: type)
    }
}

private struct VMAuroraThumbnailIdentity {
    let platform: String
    let detail: String
    let smallSymbol: String
    let largeSymbol: String
    let palette: [Color]
    let glow: Color

    init(title: String, type: VMOSType) {
        let normalizedTitle = title.lowercased()
        if type == .macOS {
            platform = "macOS"
            detail = "Apple silicon virtual machine"
            smallSymbol = "apple.logo"
            largeSymbol = "macwindow"
            palette = [
                Color(red: 0.08, green: 0.13, blue: 0.28),
                Color(red: 0.22, green: 0.20, blue: 0.48),
                Color(red: 0.08, green: 0.40, blue: 0.62),
            ]
            glow = Color(red: 0.33, green: 0.76, blue: 1.00)
        } else if normalizedTitle.contains("ubuntu") {
            platform = "Omarchy"
            detail = "ARM64 Linux virtual machine"
            smallSymbol = "circle.grid.cross"
            largeSymbol = "circle.grid.cross.fill"
            palette = [
                Color(red: 0.22, green: 0.07, blue: 0.18),
                Color(red: 0.48, green: 0.12, blue: 0.28),
                Color(red: 0.84, green: 0.28, blue: 0.16),
            ]
            glow = Color(red: 1.00, green: 0.48, blue: 0.18)
        } else if normalizedTitle.contains("omarchy") {
            platform = "Omarchy"
            detail = "Arch Linux desktop"
            smallSymbol = "sparkles"
            largeSymbol = "terminal.fill"
            palette = [
                Color(red: 0.025, green: 0.035, blue: 0.055),
                Color(red: 0.045, green: 0.12, blue: 0.11),
                Color(red: 0.10, green: 0.20, blue: 0.13),
            ]
            glow = Color(red: 0.55, green: 0.96, blue: 0.42)
        } else {
            platform = "Linux"
            detail = "ARM64 virtual machine"
            smallSymbol = "terminal"
            largeSymbol = "pc"
            palette = [
                Color(red: 0.06, green: 0.10, blue: 0.18),
                Color(red: 0.10, green: 0.25, blue: 0.32),
                Color(red: 0.08, green: 0.42, blue: 0.44),
            ]
            glow = Color(red: 0.20, green: 0.86, blue: 0.82)
        }
    }
}

/*
 Thumbnail area of a machine card: shows a bundled, selected, or captured
 image when available, otherwise a generated title cover, with a live
 running badge on top.
 */
#endif
