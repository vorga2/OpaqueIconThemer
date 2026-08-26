import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

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

private struct AppTintView: View {
    let app: InstalledAppInfo

    @State private var tintColor: Color = .blue
    @State private var mode: IconRenderMode = .auto
    @State private var tintIntensity = 0.88
    @State private var gradientStart = 0.50
    @State private var gradientStrength = 0.16
    @StateObject private var shortcutHelper = ShortcutHelper()

    private var resolvedMode: IconRenderMode? {
        guard let source = app.icon else { return nil }
        return IconStyleRenderer.shared.resolvedMode(source: source, requested: mode)
    }

    private var tintedIcon: UIImage? {
        guard let source = app.icon else { return nil }
        let renderer = ReferenceAppleMonotoneRenderer.shared
        let uiTint = UIColor(tintColor)

        if resolvedMode == .smartLogo {
            return renderer.renderSmartLogo(
                source: source,
                tint: uiTint,
                gradientStart: gradientStart,
                gradientStrength: gradientStrength
            ) ?? renderer.renderTintedBitmap(
                source: source,
                tint: uiTint,
                intensity: tintIntensity
            )
        }

        return renderer.renderTintedBitmap(
            source: source,
            tint: uiTint,
            intensity: tintIntensity
        )
    }

    private var resultTitle: String {
        switch resolvedMode {
        case .smartLogo: return "Apple Mono"
        case .tint: return "Apple Tint"
        default: return "Результат"
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

                        if let tintedIcon {
                            preview(image: tintedIcon, title: resultTitle)
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

                    if mode == .auto, let resolvedMode {
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

                Section("Цвет") {
                    ColorPicker("Цвет", selection: $tintColor, supportsOpacity: false)

                    if mode != .smartLogo {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Сила тинта")
                                Spacer()
                                Text("\(Int(tintIntensity * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $tintIntensity, in: 0.20...1.0)
                        }
                    }
                }

                if mode != .tint {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Начало градиента")
                                Spacer()
                                Text("\(Int(gradientStart * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $gradientStart, in: 0.20...0.80)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Интенсивность")
                                Spacer()
                                Text("\(Int(gradientStrength * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $gradientStrength, in: 0.0...0.45)
                        }
                    } header: {
                        Text("Градиент логотипа")
                    } footer: {
                        Text("Mono-форма считается в linear-light: верх остаётся белым, ниже выбранной точки мягко добавляется выбранный цвет. Полупрозрачность и антиалиасинг деталей сохраняются в композите, но итоговая PNG полностью непрозрачная.")
                    }
                }

                Section {
                    Button {
                        guard let tintedIcon else { return }
                        shortcutHelper.generateReadyShortcut(
                            tintedIcon,
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
    }

    private var modeDescription: String {
        switch mode {
        case .auto:
            return "Авто оставляет простые логотипные иконки в Apple Mono-пайплайне, а сложные и игровые переводит в Apple Tint по всей картинке."
        case .smartLogo:
            return "Сегментирует главный знак мягкой маской, сохраняет alpha/антиалиасинг и тональный объём, считает luminance в linear-light sRGB и делает фон полностью непрозрачным."
        case .tint:
            return "Для игр и детализированных иконок: без вырезания формы, вся картинка переводится в linear-light двухточечный tint с сохранением светотеневой структуры."
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
