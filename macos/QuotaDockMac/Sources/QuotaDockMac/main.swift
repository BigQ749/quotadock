import AppKit
import Combine
import Foundation
import SwiftUI

struct QuotaWindow: Codable, Identifiable {
    let label: String
    let remainingPercent: Double
    let resetText: String

    var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label
        case remainingPercent
        case resetText
    }

    init(label: String, remainingPercent: Double, resetText: String) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetText = resetText
    }
}

struct ProviderSnapshot: Codable, Identifiable {
    let id: String
    let title: String
    let badge: String?
    let updatedAt: String?
    let lastSuccessAt: String?
    let syncStatus: String?
    let lastError: String?
    let windows: [QuotaWindow]
}

private struct SnapshotEnvelope: Codable {
    let providers: [ProviderSnapshot]
}

final class QuotaStore: ObservableObject {
    @Published private(set) var providers: [ProviderSnapshot] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReloadAt: Date?
    @Published var selectedIds: Set<String> = []

    let dataDirectory: URL
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDirectory = appSupport.appendingPathComponent("QuotaDock", isDirectory: true)
        reload()
    }

    func reload() {
        let file = dataDirectory.appendingPathComponent("providers.json")
        do {
            guard FileManager.default.fileExists(atPath: file.path) else {
                providers = []
                errorMessage = "尚未找到 providers.json"
                lastReloadAt = Date()
                return
            }
            let data = try Data(contentsOf: file)
            let loaded: [ProviderSnapshot]
            if let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data) {
                loaded = envelope.providers
            } else {
                loaded = try decoder.decode([ProviderSnapshot].self, from: data)
            }
            providers = loaded
            selectedIds.formIntersection(Set(loaded.map(\.id)))
            if selectedIds.isEmpty {
                selectedIds = Set(loaded.map(\.id))
            }
            errorMessage = nil
            lastReloadAt = Date()
        } catch {
            errorMessage = "读取额度数据失败：\(error.localizedDescription)"
            lastReloadAt = Date()
        }
    }

    func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    var visibleProviders: [ProviderSnapshot] {
        providers.filter { selectedIds.contains($0.id) }
    }
}

struct DashboardView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("QuotaDock")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("macOS · 本地额度浮窗")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新本地额度快照")
            }

            Divider()

            if store.visibleProviders.isEmpty {
                EmptyStateView(store: store)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.visibleProviders) { provider in
                            ProviderCardView(provider: provider)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(store.errorMessage == nil ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(store.errorMessage ?? "每 60 秒检查本地快照")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let date = store.lastReloadAt {
                    Text(date, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: 480, minHeight: 220, maxHeight: 700)
        .background(.ultraThinMaterial)
    }
}

private struct EmptyStateView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.mint)
            Text("还没有本地额度快照")
                .font(.system(size: 18, weight: .semibold))
            Text("请创建：\n\(store.dataDirectory.path)/providers.json")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("QuotaDock 只负责展示，不会在 macOS 上代替第三方平台登录或保存 Cookie。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ProviderCardView: View {
    let provider: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                if let badge = provider.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                Text(provider.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            ForEach(provider.windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(String(format: "%.0f%%", max(0, min(100, window.remainingPercent))))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.mint)
                    }
                    ProgressView(value: max(0, min(100, window.remainingPercent)), total: 100)
                        .tint(.mint)
                    if !window.resetText.isEmpty {
                        Text(window.resetText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(provider.syncStatus == "success" ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(provider.syncStatus == "success" ? "同步正常" : "同步失败，保留上次成功数据")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(provider.lastSuccessAt ?? provider.updatedAt ?? "尚无同步时间")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(15)
        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Q"
        statusItem.button?.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.store.reload()
            self?.rebuildMenu()
        }
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func showPanelFromMenu() {
        showPanel()
    }

    @objc private func refreshFromMenu() {
        store.reload()
        rebuildMenu()
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.toggle(id)
        rebuildMenu()
        showPanel()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 QuotaDock", action: #selector(showPanelFromMenu), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        for provider in store.providers {
            let item = NSMenuItem(title: provider.title, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.id
            item.state = store.selectedIds.contains(provider.id) ? .on : .off
            menu.addItem(item)
        }

        if !store.providers.isEmpty {
            menu.addItem(.separator())
        }
        let refresh = NSMenuItem(title: "刷新本地快照", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 QuotaDock", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func showPanel() {
        if panel == nil {
            let next = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            next.title = "QuotaDock"
            next.titleVisibility = .hidden
            next.titlebarAppearsTransparent = true
            next.isMovableByWindowBackground = true
            next.level = .floating
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            next.isReleasedWhenClosed = false
            next.contentView = NSHostingView(rootView: DashboardView(store: store))
            panel = next
        }
        guard let panel else { return }
        if !panel.isVisible, let visibleFrame = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visibleFrame.maxX - panel.frame.width - 24, y: visibleFrame.maxY - 24))
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct QuotaDockMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
