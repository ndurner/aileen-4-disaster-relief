import SwiftUI

enum OceanPalette {
    static let ink = Color(red: 0.11, green: 0.23, blue: 0.28)
    static let deepWater = Color(red: 0.08, green: 0.42, blue: 0.50)
    static let reef = Color(red: 0.29, green: 0.72, blue: 0.74)
    static let tideFoam = Color(red: 0.87, green: 0.96, blue: 0.96)
    static let sand = Color(red: 0.98, green: 0.93, blue: 0.84)
    static let coral = Color(red: 0.95, green: 0.67, blue: 0.55)
}

struct OceanBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 1.00),
                    Color(red: 0.88, green: 0.96, blue: 0.96),
                    Color(red: 0.98, green: 0.95, blue: 0.89)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(OceanPalette.reef.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 28)
                .offset(x: 150, y: -210)

            Circle()
                .fill(OceanPalette.coral.opacity(0.16))
                .frame(width: 250, height: 250)
                .blur(radius: 24)
                .offset(x: -160, y: 120)

            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 220, height: 220)
                .blur(radius: 18)
                .offset(x: 100, y: 300)
        }
        .ignoresSafeArea()
    }
}

struct OceanScreen<Content: View>: View {
    let eyebrow: String?
    let title: String?
    let subtitle: String?
    private let content: Content

    init(
        eyebrow: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if showsHeader {
                    header
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 152)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var showsHeader: Bool {
        !normalized(eyebrow).isEmpty || !normalized(title).isEmpty || !normalized(subtitle).isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow = nonEmpty(eyebrow) {
                OceanBadge(text: eyebrow)
            }

            if let title = nonEmpty(title) {
                Text(title)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(OceanPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let subtitle = nonEmpty(subtitle) {
                Text(subtitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = normalized(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OceanBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(OceanPalette.deepWater)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.62))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.70), lineWidth: 1)
            )
    }
}

struct OceanCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: OceanPalette.deepWater.opacity(0.08), radius: 28, x: 0, y: 16)
    }
}

struct OceanSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Spacer(minLength: 12)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.deepWater.opacity(0.80))
            }
        }
    }
}

struct OceanTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 220

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.55))

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink.opacity(0.42))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
            }

            TextEditor(text: $text)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.clear)
        }
        .frame(minHeight: minHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 1)
        )
    }
}

struct OceanPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(OceanPalette.deepWater)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(OceanPalette.tideFoam.opacity(0.95))
            )
    }
}

struct OceanActionTile: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OceanPalette.deepWater)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OceanPalette.tideFoam)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.ink)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink.opacity(0.62))
            }

            Spacer(minLength: 12)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OceanPalette.deepWater.opacity(0.70))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.54))
        )
    }
}

struct OceanPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(
                LinearGradient(
                    colors: [OceanPalette.deepWater, OceanPalette.reef],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .shadow(color: OceanPalette.deepWater.opacity(0.18), radius: 18, x: 0, y: 10)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct OceanSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(OceanPalette.deepWater)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.48 : 0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct AileenSceneArtwork: View {
    let imageName: String
    var height: CGFloat = 184
    var cornerRadius: CGFloat = 28

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AileenWorkflowCard<Content: View>: View {
    let imageName: String
    let title: String
    let message: String
    let bandMidOpacity: Double
    let bandBottomOpacity: Double
    private let content: Content

    init(
        imageName: String,
        title: String,
        message: String,
        bandMidOpacity: Double = 0.44,
        bandBottomOpacity: Double = 0.84,
        @ViewBuilder content: () -> Content
    ) {
        self.imageName = imageName
        self.title = title
        self.message = message
        self.bandMidOpacity = bandMidOpacity
        self.bandBottomOpacity = bandBottomOpacity
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                AileenSceneArtwork(imageName: imageName)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    LinearGradient(
                        colors: [
                            Color.clear,
                            OceanPalette.deepWater.opacity(bandMidOpacity),
                            OceanPalette.ink.opacity(bandBottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 116)
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(message)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineSpacing(1.2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 255, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }

            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: OceanPalette.deepWater.opacity(0.08), radius: 28, x: 0, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}

struct AileenLaunchSplash: View {
    var body: some View {
        ZStack {
            Image("AileenLaunchScene")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.04),
                    OceanPalette.deepWater.opacity(0.18),
                    OceanPalette.ink.opacity(0.90)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Aileen")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .shadow(color: OceanPalette.ink.opacity(0.35), radius: 10, x: 0, y: 4)

                    Text("AI office assistant")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.84))

                    Text("Preparing your workspace")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .padding(.top, 6)
                }
                .frame(maxWidth: 260, alignment: .leading)

                ProgressView()
                    .tint(Color.white.opacity(0.96))
                    .scaleEffect(1.05)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 42)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
    }
}

struct OceanTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.35, extraBounce: 0.05)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 18, weight: .bold))

                        Text(tab.shortTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selection == tab ? OceanPalette.deepWater : OceanPalette.ink.opacity(0.70))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selection == tab ? Color.white.opacity(0.78) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: OceanPalette.deepWater.opacity(0.12), radius: 16, x: 0, y: 10)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}
