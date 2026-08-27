import Foundation
import Combine
import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

private let iconPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

struct ContentView: View {
    @AppStorage("oit.localAppScanAllowed") private var localAppScanAllowed = false

    var body: some View {
        Group {
            if localAppScanAllowed {
                AppsBrowserView {
                    localAppScanAllowed = false
                }
            } else {
                LocalScanConsentView {
                    localAppScanAllowed = true
                }
            }
        }
    }
}

private struct LocalScanConsentView: View {
    let allow: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()

                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 66))

                VStack(spacing: 10) {
                    Text("Доступ к списку приложений")
                        .font(.title2.bold())

                    Text("OpaqueIconThemer может локально просканировать установленные приложения, включая кастомные и sideloaded-приложения, если их видит системный Screen Time API. Список никуда не отправляется.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button(action: allow) {
                    Text("Продолжить")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)

                Text("После этого iOS может показать системный запрос на доступ к данным использования приложений.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Opaque Icons")
        }
    }
}

private struct AppsBrowserView: View {
    @StateObject private var store = InstalledAppsStore()
    let revokeConsent: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.scanning && store.apps.isEmpty {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Сканирую приложения…")
                        }
                    } footer: {
                        Text("Поиск по полному bundle ID уже работает во время сканирования.")
                    }
                }

                if store.apps.isEmpty {
                    Section {
                        EmptyStateView(
                            title: store.isBundleIDSearch ? "Ищу bundle ID" : "Список не получен",
                            symbol: store.isBundleIDSearch ? "magnifyingglass" : "apps.iphone",
                            message: store.status.isEmpty ? "Нажми «Сканировать снова»." : store.status
                        )

                        if store.isBundleIDSearch {
                            Button {
                                store.lookupSearchNow()
                            } label: {
                                Label("Найти сейчас", systemImage: "arrow.right.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } footer: {
                        if !store.isBundleIDSearch {
                            Text("Если Screen Time helper недоступен из-за sideload-подписи, приложение автоматически пробует локальные запасные способы.")
                        }
                    }
                } else {
                    Section {
                        if store.filteredApps.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Совпадений пока нет")
                                    .font(.headline)
                                if store.isBundleIDSearch {
                                    Button("Проверить этот bundle ID") {
                                        store.lookupSearchNow()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        } else {
                            ForEach(store.filteredApps) { app in
                                NavigationLink {
                                    AppTintView(app: app)
                                } label: {
                                    AppRow(app: app)
                                }
                            }
                        }
                    } header: {
                        Text("Приложения — \(store.filteredApps.count)")
                    } footer: {
                        Text(store.status)
                    }
                }
            }
            .navigationTitle("Приложения")
            .searchable(text: $store.search, prompt: "Название или bundle ID")
            .onSubmit(of: .search) {
                store.lookupSearchNow()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            store.scan()
                        } label: {
                            Label("Сканировать снова", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive, action: revokeConsent) {
                            Label("Отозвать локальное согласие", systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
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
}

private struct AppRow: View {
    let app: InstalledAppInfo

    var body: some View {
        HStack(spacing: 12) {
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
                        .padding(8)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if app.displayName == app.bundleIdentifier, let token = app.applicationToken {
                    Label(token)
                        .labelStyle(.titleOnly)
                        .lineLimit(1)
                } else {
                    Text(app.displayName)
                        .lineLimit(1)
                }

                Text(app.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private enum TintVariant: String, CaseIterable, Identifiable {
    case simple
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "Обычный"
        case .advanced: return "Расширенный"
        }
    }
}

private struct AppTintView: View {
    let app: InstalledAppInfo

    private struct RenderSnapshot {
        let source: UIImage
        let resolvedMode: IconRenderMode
        let tintVariant: TintVariant
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
    @State private var tintVariant: TintVariant = .simple
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
        switch mode {
        case .auto:
            return autoResolvedMode
        case .smartLogo:
            return .smartLogo
        case .tint:
            return .tint
        }
    }

    private var backgroundColorKey: String {
        UIColor(tintColor).description
    }

    private var iconColorKey: String {
        UIColor(iconTintColor).description
    }

    private var shadowColorKey: String {
        UIColor(shadowColor).description
    }

    private func makeRenderSnapshot() -> RenderSnapshot? {
        guard let source = app.icon else { return nil }
        let backgroundTint = UIColor(tintColor)
        let effectiveIconTint: UIColor

        if resolvedMode == .tint && tintVariant == .advanced {
            effectiveIconTint = UIColor(iconTintColor)
        } else {
            // In normal Tint the whole icon uses one selected color. This also guarantees that
            // tint=100% + background=100% resolves to exactly one solid tint color.
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
            ) else {
                return nil
            }

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

        // Preserve the normal-Tint contract: foreground 100% + background 100% with one color
        // must stay an exactly solid selected-color icon. Shadows resume below 100%.
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

    private var resultTitle: String {
        switch resolvedMode {
        case .smartLogo: return "Apple Mono"
        case .tint:
            return tintVariant == .advanced ? "Apple Tint+" : "Apple Tint"
        case .auto: return "Результат"
        }
    }

    var body: some View {
        List {
            Section("Приложение") {
                AppRow(app: app)
            }

            if let source = app.icon {
                Section("Предпросмотр") {
                    HStack(spacing: 22) {
                        preview(image: source, title: "Оригинал")

                        if let previewIcon {
                            preview(image: previewIcon, title: resultTitle)
                        } else {
                            ProgressView()
                                .frame(width: 92, height: 92)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Режим") {
                    Picker("Обработка", selection: $mode) {
                        ForEach(IconRenderMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if resolvedMode == .tint {
                        Picker("Тип тинта", selection: $tintVariant) {
                            ForEach(TintVariant.allCases) { variant in
                                Text(variant.title).tag(variant)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if mode == .auto {
                        HStack {
                            Text("Авто выбрало")
                            Spacer()
                            Label(
                                resolvedMode == .smartLogo ? "Apple Mono" : "Apple Tint",
                                systemImage: resolvedMode == .smartLogo ? "wand.and.stars" : "paintbrush.fill"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }

                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ColorPicker(
                        resolvedMode == .tint && tintVariant == .advanced ? "Цвет фона" : "Цвет тинта",
                        selection: $tintColor,
                        supportsOpacity: false
                    )

                    if resolvedMode == .tint && tintVariant == .advanced {
                        ColorPicker("Цвет иконки", selection: $iconTintColor, supportsOpacity: false)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Интенсивность фона")
                            Spacer()
                            Text("\(Int(backgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        AdaptiveSlider(
                            value: $backgroundIntensity,
                            range: 0.0...1.0,
                            onEditingChanged: sliderEditingChanged
                        )
                    }

                    if resolvedMode == .tint {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Сила тинта")
                                Spacer()
                                Text("\(Int(tintIntensity * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            AdaptiveSlider(
                                value: $tintIntensity,
                                range: 0.0...1.0,
                                onEditingChanged: sliderEditingChanged
                            )
                        }
                    }
                } header: {
                    Text("Цвет")
                } footer: {
                    if resolvedMode == .tint && tintVariant == .advanced {
                        Text("Расширенный Tint: цвет фона и цвет элементов задаются отдельно. Интенсивность фона и сила тинта продолжают работать одновременно.")
                    } else if resolvedMode == .tint {
                        Text("Обычный Tint использует один цвет. Интенсивность фона и сила тинта работают одновременно; при 100% + 100% вся иконка становится ровно выбранным цветом.")
                    } else {
                        Text("Интенсивность фона усиливает выбранный цвет только в фоне, не ломая Mono-слои логотипа.")
                    }
                }

                if resolvedMode == .smartLogo {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Начало градиента")
                                Spacer()
                                Text("\(Int(gradientStart * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            AdaptiveSlider(
                                value: $gradientStart,
                                range: 0.0...1.0,
                                onEditingChanged: sliderEditingChanged
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Интенсивность")
                                Spacer()
                                Text("\(Int(gradientStrength * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            AdaptiveSlider(
                                value: $gradientStrength,
                                range: 0.0...1.0,
                                onEditingChanged: sliderEditingChanged
                            )
                        }
                    } header: {
                        Text("Градиент логотипа")
                    } footer: {
                        Text("Диапазон обоих параметров 0–100%. По умолчанию: начало 0%, интенсивность 45%. Mono-форма считается в linear-light, полупрозрачность и антиалиасинг деталей сохраняются в композите, а итоговая PNG полностью непрозрачная.")
                    }
                }

                Section {
                    Toggle("Тени", isOn: $shadowsEnabled)

                    if shadowsEnabled {
                        ColorPicker("Цвет тени", selection: $shadowColor, supportsOpacity: false)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Сила теней")
                                Spacer()
                                Text("\(Int(shadowStrength * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            AdaptiveSlider(
                                value: $shadowStrength,
                                range: 0.0...1.0,
                                onEditingChanged: sliderEditingChanged
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Подкрашивание тени")
                                Spacer()
                                Text("\(Int(shadowTintMix * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            AdaptiveSlider(
                                value: $shadowTintMix,
                                range: 0.0...1.0,
                                onEditingChanged: sliderEditingChanged
                            )
                        }
                    }
                } header: {
                    Text("Тени")
                } footer: {
                    Text("По умолчанию: чёрная тень, сила 90%, подкрашивание цветом поверхности 30%. Используются верхний внутренний свет, нижняя/боковая глубина, ambient, контактная тень, тени логотипа и направленный кант. При обычном Tint 100% + 100% тени отключаются автоматически, чтобы сохранить полностью одноцветный результат.")
                }

                Section {
                    Button {
                        guard let finalIcon = renderCurrentIcon() else { return }
                        previewIcon = finalIcon
                        shortcutHelper.generateReadyShortcut(
                            finalIcon,
                            appName: app.displayName,
                            bundleIdentifier: app.bundleIdentifier
                        )
                    } label: {
                        HStack {
                            Spacer()
                            if shortcutHelper.busy {
                                ProgressView().padding(.trailing, 6)
                            }
                            Label("Сохранить и создать Команду", systemImage: "wand.and.stars")
                            Spacer()
                        }
                    }
                    .disabled(shortcutHelper.busy)
                } footer: {
                    Text("OpaqueIconThemer сохранит готовую иконку отдельной картинкой в Фото и соберёт .shortcut с одним действием «Открыть приложение». Картинка в сам файл Команды не встраивается.")
                }

                Section("Остался только экран Домой") {
                    Text("После импорта открой меню Команды → «На экран Домой» → нажми на иконку и выбери сохранённую картинку из Фото.")
                        .font(.callout)

                    Text("Приложение и действие вручную выбирать уже не нужно. Саму картинку для значка ты выбираешь вручную при добавлении на экран Домой.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    EmptyStateView(
                        title: "Иконка недоступна",
                        symbol: "photo.badge.exclamationmark",
                        message: "Приложение найдено, но iOS не дала изображение иконки. Для App Store-приложений OpaqueIconThemer дополнительно пытается получить качественную 512px-иконку."
                    )
                }
            }

            if let status = shortcutHelper.status {
                Section("Статус") {
                    Text(status)
                        .font(.caption)
                }
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
        .onReceive(iconPreviewTicker) { _ in
            // Preview is rendered at most 10 times per second. Rendering happens off the main
            // thread, so dragging a slider does not force a 512px image pass on every touch event.
            refreshPreviewIfNeeded()
        }
        .onChange(of: mode) { _ in
            markPreviewDirty()
        }
        .onChange(of: tintVariant) { _ in
            markPreviewDirty()
        }
        .onChange(of: backgroundColorKey) { _ in
            markPreviewDirty()
        }
        .onChange(of: iconColorKey) { _ in
            markPreviewDirty()
        }
        .onChange(of: tintIntensity) { _ in
            markPreviewDirty()
        }
        .onChange(of: backgroundIntensity) { _ in
            markPreviewDirty()
        }
        .onChange(of: gradientStart) { _ in
            markPreviewDirty()
        }
        .onChange(of: gradientStrength) { _ in
            markPreviewDirty()
        }
        .onChange(of: shadowsEnabled) { _ in
            markPreviewDirty()
        }
        .onChange(of: shadowColorKey) { _ in
            markPreviewDirty()
        }
        .onChange(of: shadowStrength) { _ in
            markPreviewDirty()
        }
        .onChange(of: shadowTintMix) { _ in
            markPreviewDirty()
        }
    }

    private var modeDescription: String {
        switch mode {
        case .auto:
            return "Авто оставляет простые логотипные иконки в Apple Mono-пайплайне, а сложные и игровые переводит в Apple Tint. Для Tint доступны обычный и расширенный варианты."
        case .smartLogo:
            return "Сегментирует главный знак мягкой маской, сохраняет alpha/антиалиасинг и тональный объём, считает luminance в linear-light sRGB и делает фон полностью непрозрачным."
        case .tint:
            if tintVariant == .advanced {
                return "Расширенный Tint: отдельные цвета фона и элементов плюс независимые интенсивности, сведённые в одном linear-light проходе."
            }
            return "Обычный Tint: один выбранный цвет, сила тинта и интенсивность фона. На 100% + 100% результат становится полностью выбранным цветом."
        }
    }

    @ViewBuilder
    private func preview(image: UIImage, title: String) -> some View {
        VStack(spacing: 7) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}