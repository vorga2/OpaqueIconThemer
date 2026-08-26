import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ThemeStore
    @State private var importing = false
    @State private var clearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: store.bridgeReady ? "checkmark.shield.fill" : "shield.slash")
                            .foregroundStyle(store.bridgeReady ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text("SpringBoard Bridge").font(.headline)
                            Text(store.bridgeStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Меняется картинка настоящего SBIconView. WebClip и Shortcuts не используются.")
                }

                Section("Тема") {
                    Button {
                        importing = true
                    } label: {
                        Label("Выбрать PNG", systemImage: "photo.badge.plus")
                    }

                    Text("Имя файла должно быть bundle ID приложения, например com.apple.Preferences.png")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Иконок")
                        Spacer()
                        Text("\(store.iconCount)").foregroundStyle(.secondary)
                    }

                    ForEach(store.bundleIDs.prefix(24), id: \.self) { id in
                        HStack(spacing: 12) {
                            if let image = store.preview(id) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 38, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }

                            Text(id)
                                .font(.caption.monospaced())
                                .lineLimit(1)

                            Spacer()

                            Button(role: .destructive) {
                                store.remove(id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await store.apply() }
                    } label: {
                        HStack {
                            Spacer()
                            if store.busy { ProgressView().padding(.trailing, 6) }
                            Text("Применить").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!store.bridgeReady || store.iconCount == 0 || store.busy)

                    Button(role: .destructive) {
                        clearConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Вернуть оригинальные")
                            Spacer()
                        }
                    }
                    .disabled(!store.bridgeReady || store.busy)
                }

                if let log = store.log {
                    Section("Лог") {
                        Text(log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Opaque Icons")
            .toolbar {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.png],
            allowsMultipleSelection: true
        ) { result in
            store.importFiles(result)
        }
        .confirmationDialog("Вернуть стандартные иконки?", isPresented: $clearConfirm) {
            Button("Вернуть", role: .destructive) {
                Task { await store.clear() }
            }
            Button("Отмена", role: .cancel) {}
        }
        .onAppear { store.refresh() }
    }
}
