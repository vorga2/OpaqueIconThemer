import SwiftUI
import UIKit

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

                    Text("OpaqueIconThemer может локально просканировать установленные приложения, чтобы показать их название, bundle ID и доступную системе иконку. Список никуда не отправляется.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button(action: allow) {
                    Text("Разрешить локальный скан")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)

                Text("Это внутреннее согласие приложения. iOS не предоставляет отдельного системного разрешения на чтение списка установленных приложений.")
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
                if store.scanning {
                    HStack {
                        ProgressView()
                        Text("Сканирую приложения…")
                    }
                } else if store.apps.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Список не получен",
                            systemImage: "apps.iphone",
                            description: Text(store.status.isEmpty ? "Нажми «Сканировать снова»." : store.status)
                        )
                    }
                } else {
                    Section {
                        ForEach(store.filteredApps) { app in
                            NavigationLink {
                                AppTintView(app: app)
                            } label: {
                                AppRow(app: app)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            store.scan()
                        } label: {
                            Label("Сканировать снова", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive, action: revokeConsent) {
                            Label("Отозвать разрешение", systemImage: "hand.raised")
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
                Text(app.displayName)
                    .lineLimit(1)
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
    @State private var intensity = 0.88
    @StateObject private var shortcutHelper = ShortcutHelper()

    private var tintedIcon: UIImage? {
        guard let source = app.icon else { return nil }
        return IconTintEngine.shared.render(
            source: source,
            tint: UIColor(tintColor),
            intensity: intensity
        )
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
                            preview(image: tintedIcon, title: "Тинт")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Цвет") {
                    ColorPicker("Цвет тинта", selection: $tintColor, supportsOpacity: false)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Сила")
                            Spacer()
                            Text("\(Int(intensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $intensity, in: 0.35...1.0)
                    }
                }

                Section {
                    Button {
                        guard let tintedIcon else { return }
                        shortcutHelper.saveIconAndOpenShortcuts(tintedIcon, appName: app.displayName)
                    } label: {
                        HStack {
                            Spacer()
                            if shortcutHelper.busy {
                                ProgressView().padding(.trailing, 6)
                            }
                            Label("Сохранить и открыть Команды", systemImage: "wand.and.stars")
                            Spacer()
                        }
                    }
                    .disabled(shortcutHelper.busy)
                } footer: {
                    Text("Иконка сохраняется в Фото, после чего открывается экран создания новой Команды. Название приложения копируется в буфер обмена.")
                }

                Section("Добавление на экран Домой") {
                    Text("В Командах добавь действие «Открыть приложение», выбери \(app.displayName), затем «Поделиться» → «На экран Домой» и выбери только что сохранённую иконку.")
                        .font(.callout)

                    Text("iOS не даёт обычному приложению автоматически добавить такой ярлык на экран Домой, поэтому отдельной фальшивой кнопки «Добавить сразу» здесь нет.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Иконка недоступна",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("iOS отдала приложение, но не разрешила прочитать его иконку. Для него ничего подставлять не будем.")
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
