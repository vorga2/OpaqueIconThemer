import Foundation
import Combine
import SwiftUI
import UIKit

private let liquidPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

/// New iOS 26/27-first interface. The previous ContentView remains in the project as a legacy
/// fallback/reference, while the app entry point now opens this Liquid Glass shell.
struct LiquidContentView: View {
    @AppStorage("oit.localAppScanAllowed") private var localAppScanAllowed = false

    var body: some View {
        Group {
            if localAppScanAllowed {
                LGLAppsBrowserView {
                    localAppScanAllowed = false
                }
            } else {
                LGLScanConsentView {
                    localAppScanAllowed = true
                }
            }
        }
    }
}

// MARK: - Liquid Glass primitives

private struct LGLBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.15),
                    Color.purple.opacity(0.08),
                    Color.cyan.opacity(0.07),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.13))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: 170, y: -310)

            Circle()
                .fill(Color.purple.opacity(0.09))
                .frame(width: 310, height: 310)
                .blur(radius: 90)
                .offset(x: -190, y: 330)
        }
        .ignoresSafeArea()
    }
}

private struct LGLGlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let interactive: Bool
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = 28,
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            content()
                .padding(18)
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content()
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.7)
                }
        }
    }
}

private struct LGLSectionTitle: View {
    let title: String
    let symbol: String?

    init(_ title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
            }
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.5)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
}

private struct LGLPrimaryButton<Label: View>: View {
    let action: () -> Void
    let disabled: Bool
    @ViewBuilder let label: () -> Label

    init(disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.disabled = disabled
        self.label = label
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glassProminent)
                .disabled(disabled)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
    }
}

private struct LGLSecondaryButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
        }
    }
}

private struct LGLSegmentedControl<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = value
                    }
                } label: {
                    Text(title(value))
                        .font(.subheadline.weight(selection == value ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                .background {
                    if selection == value {
                        if #available(iOS 26.0, *) {
                            Color.accentColor.opacity(0.13)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        } else {
                            Capsule().fill(.thinMaterial)
                        }
                    }
                }
            }
        }
        .padding(5)
        .background {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: .capsule)
            } else {
                Capsule().fill(.thinMaterial)
            }
        }
    }
}

private struct LGLSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var percent: Bool = true
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 11) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(percent ? "\(Int(value * 100))%" : String(format: "%.2f", value))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Consent

private struct LGLScanConsentView: View {
    let allow: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LGLBackdrop()

                VStack(spacing: 24) {
                    Spacer()

                    if #available(iOS 26.0, *) {
                        Image(systemName: "square.grid.3x3.square")
                            .font(.system(size: 50, weight: .medium))
                            .frame(width: 96, height: 96)
                            .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                    } else {
                        Image(systemName: "square.grid.3x3.square")
                            .font(.system(size: 50, weight: .medium))
                    }

                    LGLGlassCard {
                        VStack(spacing: 12) {
                            Text("Доступ к приложениям")
                                .font(.title2.bold())

                            Text("OpaqueIconThemer локально находит установленные приложения и их иконки. Список никуда не отправляется.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)

                            LGLPrimaryButton(action: allow) {
                                Label("Продолжить", systemImage: "arrow.right")
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Text("iOS может показать отдельный системный запрос доступа.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)

                    Spacer()
                }
            }
            .navigationTitle("Opaque Icons")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - App browser

private struct LGLAppsBrowserView: View {
    @StateObject private var store = InstalledAppsStore()
    let revokeConsent: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LGLBackdrop()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        searchCard

                        if store.scanning && store.apps.isEmpty {
                            LGLGlassCard {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Сканирую приложения…")
                                            .font(.headline)
                                        Text("Это происходит локально на устройстве")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        if store.apps.isEmpty {
                            emptyCard
                        } else {
                            HStack {
                                LGLSectionTitle("Приложения — \(store.filteredApps.count)", symbol: "square.grid.2x2")
                                Spacer()
                            }

                            if store.filteredApps.isEmpty {
                                LGLGlassCard {
                                    VStack(spacing: 10) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                        Text("Совпадений пока нет")
                                            .font(.headline)
                                        if store.isBundleIDSearch {
                                            LGLSecondaryButton(action: store.lookupSearchNow) {
                                                Text("Проверить bundle ID")
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            } else {
                                ForEach(store.filteredApps) { app in
                                    NavigationLink {
                                        LGLAppTintView(app: app)
                                    } label: {
                                        LGLGlassCard(cornerRadius: 24, interactive: true) {
                                            LGLAppRow(app: app)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !store.status.isEmpty {
                                Text(store.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Приложения")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            store.scan()
                        } label: {
                            Label("Сканировать снова", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive, action: revokeConsent) {
                            Label("Отозвать согласие", systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .onAppear {
                if store.apps.isEmpty && !store.scanning {
                    store.scan()
                }
            }
        }
    }

    private var searchCard: some View {
        LGLGlassCard(cornerRadius: 24, interactive: true) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Название или bundle ID", text: $store.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        store.lookupSearchNow()
                    }
                if !store.search.isEmpty {
                    Button {
                        store.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyCard: some View {
        LGLGlassCard {
            VStack(spacing: 13) {
                Image(systemName: store.isBundleIDSearch ? "magnifyingglass" : "apps.iphone")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(store.isBundleIDSearch ? "Ищу bundle ID" : "Список не получен")
                    .font(.headline)

                Text(store.status.isEmpty ? "Нажми «Сканировать снова»." : store.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if store.isBundleIDSearch {
                    LGLPrimaryButton(action: store.lookupSearchNow) {
                        Label("Найти сейчас", systemImage: "arrow.right.circle.fill")
                    }
                } else {
                    LGLSecondaryButton(action: store.scan) {
                        Label("Сканировать снова", systemImage: "arrow.clockwise")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LGLAppRow: View {
    let app: InstalledAppInfo

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon = app.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                } else if let token = app.applicationToken {
                    Label(token)
                        .labelStyle(.iconOnly)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(9)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if app.displayName == app.bundleIdentifier, let token = app.applicationToken {
                    Label(token)
                        .labelStyle(.titleOnly)
                        .lineLimit(1)
                        .font(.headline)
                } else {
                    Text(app.displayName)
                        .lineLimit(1)
                        .font(.headline)
                }

                Text(app.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Editor

private enum LGLTintVariant: String, CaseIterable, Hashable {
    case simple
    case advanced

    var title: String {
        switch self {
        case .simple: return "Обычный"
        case .advanced: return "Расширенный"
        }
    }
}

private struct LGLAppTintView: View {
    let app: InstalledAppInfo

    private struct RenderSnapshot {
        let source: UIImage
        let resolvedMode: IconRenderMode
        let tintVariant: LGLTintVariant
        let backgroundTint: UIColor
        let iconTint: UIColor
        let tintIntensity: CGFloat
        let backgroundIntensity: CGFloat
        let gradientStart: CGFloat
        let gradientStrength: CGFloat
        let shadowsEnabled: Bool
        let shadowColor: UIColor
        let shadowStrength: CGFloat
        let shadowTintMix: CGFloat
    }

    @State private var tintColor: Color = .blue
    @State private var iconTintColor: Color = .blue
    @State private var mode: IconRenderMode = .auto
    @State private var tintVariant: LGLTintVariant = .simple
    @State private var tintIntensity: Double = 0.88
    @State private var backgroundIntensity: Double = 0.72
    @State private var gradientStart: Double = 0.0
    @State private var gradientStrength: Double = 0.45
    @State private var shadowsEnabled = true
    @State private var shadowColor: Color = .black
    @State private var shadowStrength: Double = 0.90
    @State private var shadowTintMix: Double = 0.30
    @State private var autoResolvedMode: IconRenderMode = .tint
    @State private var previewIcon: UIImage?
    @State private var previewRevision = 1
    @State private var renderedRevision = 0
    @State private var renderInFlight = false
    @StateObject private var shortcutHelper = ShortcutHelper()

    private var resolvedMode: IconRenderMode {
        mode == .auto ? autoResolvedMode : mode
    }

    private var backgroundColorKey: String { UIColor(tintColor).description }
    private var iconColorKey: String { UIColor(iconTintColor).description }
    private var shadowColorKey: String { UIColor(shadowColor).description }

    var body: some View {
        ZStack {
            LGLBackdrop()

            ScrollView {
                LazyVStack(spacing: 18) {
                    appHeader

                    if let source = app.icon {
                        previewCard(source: source)
                        modeCard
                        colorCard

                        if resolvedMode == .smartLogo {
                            gradientCard
                        }

                        shadowsCard
                        actionCard
                        homeScreenCard
                    } else {
                        LGLGlassCard {
                            VStack(spacing: 12) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                                Text("Иконка недоступна")
                                    .font(.headline)
                                Text("Приложение найдено, но iOS не отдала изображение иконки.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    if let status = shortcutHelper.status {
                        VStack(alignment: .leading, spacing: 8) {
                            LGLSectionTitle("Статус", symbol: "checkmark.circle")
                            LGLGlassCard {
                                Text(status)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 50)
            }
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let source = app.icon {
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: source, requested: .auto)
            }
            markPreviewDirty()
            refreshPreviewIfNeeded(force: true)
        }
        .onReceive(liquidPreviewTicker) { _ in
            refreshPreviewIfNeeded()
        }
        .onChange(of: mode) { _ in markPreviewDirty() }
        .onChange(of: tintVariant) { _ in markPreviewDirty() }
        .onChange(of: backgroundColorKey) { _ in markPreviewDirty() }
        .onChange(of: iconColorKey) { _ in markPreviewDirty() }
        .onChange(of: tintIntensity) { _ in markPreviewDirty() }
        .onChange(of: backgroundIntensity) { _ in markPreviewDirty() }
        .onChange(of: gradientStart) { _ in markPreviewDirty() }
        .onChange(of: gradientStrength) { _ in markPreviewDirty() }
        .onChange(of: shadowsEnabled) { _ in markPreviewDirty() }
        .onChange(of: shadowColorKey) { _ in markPreviewDirty() }
        .onChange(of: shadowStrength) { _ in markPreviewDirty() }
        .onChange(of: shadowTintMix) { _ in markPreviewDirty() }
    }

    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Приложение", symbol: "app")
            LGLGlassCard {
                LGLAppRow(app: app)
            }
        }
    }

    private func previewCard(source: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Предпросмотр", symbol: "eye")
            LGLGlassCard(cornerRadius: 32) {
                HStack(spacing: 28) {
                    preview(image: source, title: "Оригинал")

                    if let previewIcon {
                        preview(image: previewIcon, title: resultTitle)
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                                .frame(width: 104, height: 104)
                            Text("Рендер")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Режим", symbol: "switch.2")
            LGLGlassCard {
                VStack(spacing: 14) {
                    LGLSegmentedControl(
                        values: IconRenderMode.allCases,
                        selection: $mode,
                        title: { $0.title }
                    )

                    if resolvedMode == .tint {
                        LGLSegmentedControl(
                            values: LGLTintVariant.allCases,
                            selection: $tintVariant,
                            title: { $0.title }
                        )
                    }

                    if mode == .auto {
                        HStack {
                            Label("Авто выбрало", systemImage: "sparkles")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(resolvedMode == .smartLogo ? "Apple Mono" : "Apple Tint")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Цвет", symbol: "paintpalette")
            LGLGlassCard {
                VStack(spacing: 18) {
                    ColorPicker(
                        resolvedMode == .tint && tintVariant == .advanced ? "Цвет фона" : "Цвет тинта",
                        selection: $tintColor,
                        supportsOpacity: false
                    )
                    .font(.body.weight(.medium))

                    if resolvedMode == .tint && tintVariant == .advanced {
                        Divider().opacity(0.35)
                        ColorPicker("Цвет иконки", selection: $iconTintColor, supportsOpacity: false)
                            .font(.body.weight(.medium))
                    }

                    Divider().opacity(0.35)
                    LGLSliderRow(
                        title: "Интенсивность фона",
                        value: $backgroundIntensity,
                        range: 0...1,
                        onEditingChanged: sliderEditingChanged
                    )

                    if resolvedMode == .tint {
                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Сила тинта",
                            value: $tintIntensity,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    }

                    Text(colorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var gradientCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Градиент логотипа", symbol: "circle.lefthalf.filled")
            LGLGlassCard {
                VStack(spacing: 18) {
                    LGLSliderRow(
                        title: "Начало градиента",
                        value: $gradientStart,
                        range: 0...1,
                        onEditingChanged: sliderEditingChanged
                    )
                    Divider().opacity(0.35)
                    LGLSliderRow(
                        title: "Интенсивность",
                        value: $gradientStrength,
                        range: 0...1,
                        onEditingChanged: sliderEditingChanged
                    )
                    Text("Mono-форма считается в linear-light; мягкие слои и антиалиасинг сохраняются, итоговая PNG остаётся непрозрачной.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var shadowsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Тени", symbol: "circle.bottomhalf.filled")
            LGLGlassCard {
                VStack(spacing: 18) {
                    Toggle(isOn: $shadowsEnabled) {
                        Label("Тени элементов", systemImage: "drop.fill")
                            .font(.body.weight(.medium))
                    }

                    if shadowsEnabled {
                        Divider().opacity(0.35)
                        ColorPicker("Цвет тени", selection: $shadowColor, supportsOpacity: false)
                            .font(.body.weight(.medium))
                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Сила теней",
                            value: $shadowStrength,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Подкрашивание",
                            value: $shadowTintMix,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    }

                    Text("Тени применяются только к найденным элементам иконки, не к краям плитки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Готово", symbol: "wand.and.stars")
            LGLGlassCard {
                VStack(spacing: 12) {
                    LGLPrimaryButton(disabled: shortcutHelper.busy) {
                        guard let finalIcon = renderCurrentIcon() else { return }
                        previewIcon = finalIcon
                        shortcutHelper.generateReadyShortcut(
                            finalIcon,
                            appName: app.displayName,
                            bundleIdentifier: app.bundleIdentifier
                        )
                    } label: {
                        HStack {
                            if shortcutHelper.busy {
                                ProgressView()
                            }
                            Label("Сохранить и создать Команду", systemImage: "wand.and.stars")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                    }

                    Text("Сохраняет готовую иконку в Фото и создаёт .shortcut с одним действием «Открыть приложение».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var homeScreenCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Экран Домой", symbol: "iphone")
            LGLGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Открой меню Команды → «На экран Домой»", systemImage: "1.circle.fill")
                    Label("Нажми на значок и выбери сохранённую картинку", systemImage: "2.circle.fill")
                    Text("Само приложение и действие выбирать повторно уже не нужно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resultTitle: String {
        switch resolvedMode {
        case .smartLogo: return "Apple Mono"
        case .tint: return tintVariant == .advanced ? "Apple Tint+" : "Apple Tint"
        case .auto: return "Результат"
        }
    }

    private var modeDescription: String {
        switch mode {
        case .auto:
            return "Авто отправляет простые логотипные иконки в Apple Mono, а сложные/игровые — в Apple Tint."
        case .smartLogo:
            return "Мягкая многослойная сегментация сохраняет полупрозрачные детали, объём и антиалиасинг логотипа."
        case .tint:
            return tintVariant == .advanced
                ? "Расширенный Tint: отдельные цвета фона и элементов с независимой интенсивностью."
                : "Обычный Tint: один цвет для всей иконки с раздельной силой фона и тинта."
        }
    }

    private var colorDescription: String {
        if resolvedMode == .tint && tintVariant == .advanced {
            return "Tint+ использует layer-aware маску: вложенные и полупрозрачные детали относятся к элементам, а не ошибочно к фону."
        } else if resolvedMode == .tint {
            return "При 100% + 100% обычный Tint становится ровно выбранным цветом."
        }
        return "Интенсивность фона не разрушает Mono-слои логотипа."
    }

    private func preview(image: UIImage, title: String) -> some View {
        VStack(spacing: 9) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rendering

    private func makeRenderSnapshot() -> RenderSnapshot? {
        guard let source = app.icon else { return nil }
        let backgroundTint = UIColor(tintColor)
        let effectiveIconTint: UIColor

        if resolvedMode == .tint && tintVariant == .advanced {
            effectiveIconTint = UIColor(iconTintColor)
        } else {
            effectiveIconTint = backgroundTint
        }

        return RenderSnapshot(
            source: source,
            resolvedMode: resolvedMode,
            tintVariant: tintVariant,
            backgroundTint: backgroundTint,
            iconTint: effectiveIconTint,
            tintIntensity: CGFloat(tintIntensity),
            backgroundIntensity: CGFloat(backgroundIntensity),
            gradientStart: CGFloat(gradientStart),
            gradientStrength: CGFloat(gradientStrength),
            shadowsEnabled: shadowsEnabled,
            shadowColor: UIColor(shadowColor),
            shadowStrength: CGFloat(shadowStrength),
            shadowTintMix: CGFloat(shadowTintMix)
        )
    }

    private static func render(_ snapshot: RenderSnapshot) -> UIImage? {
        let renderer = ReferenceAppleMonotoneRenderer.shared
        let baseOutput: UIImage?

        if snapshot.resolvedMode == .smartLogo {
            let base = renderer.renderSmartLogo(
                source: snapshot.source,
                tint: snapshot.backgroundTint,
                gradientStart: snapshot.gradientStart,
                gradientStrength: snapshot.gradientStrength
            ) ?? renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.backgroundTint,
                intensity: snapshot.tintIntensity
            )

            guard let base else { return nil }
            baseOutput = BackgroundIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                tint: snapshot.backgroundTint,
                intensity: snapshot.backgroundIntensity
            ) ?? base
        } else {
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: snapshot.tintIntensity
            ) else { return nil }

            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
        }

        guard let baseOutput else { return nil }

        let preserveSolidTint = snapshot.resolvedMode == .tint &&
            snapshot.tintVariant == .simple &&
            snapshot.tintIntensity >= 0.999 &&
            snapshot.backgroundIntensity >= 0.999

        guard snapshot.shadowsEnabled && !preserveSolidTint else {
            return baseOutput
        }

        return IconShadowProcessor.shared.apply(
            source: snapshot.source,
            rendered: baseOutput,
            surfaceColor: snapshot.backgroundTint,
            shadowColor: snapshot.shadowColor,
            strength: snapshot.shadowStrength,
            tintMix: snapshot.shadowTintMix,
            logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced
        ) ?? baseOutput
    }

    private func renderCurrentIcon() -> UIImage? {
        guard let snapshot = makeRenderSnapshot() else { return nil }
        return Self.render(snapshot)
    }

    private func markPreviewDirty() {
        previewRevision += 1
    }

    private func refreshPreviewIfNeeded(force: Bool = false) {
        guard !renderInFlight else { return }
        let revision = previewRevision
        guard force || revision != renderedRevision else { return }
        guard let snapshot = makeRenderSnapshot() else { return }

        renderInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.render(snapshot)
            DispatchQueue.main.async {
                if let image, revision >= renderedRevision {
                    previewIcon = image
                }
                renderedRevision = revision
                renderInFlight = false
            }
        }
    }

    private func sliderEditingChanged(_ editing: Bool) {
        if !editing {
            markPreviewDirty()
            refreshPreviewIfNeeded(force: true)
        }
    }
}
