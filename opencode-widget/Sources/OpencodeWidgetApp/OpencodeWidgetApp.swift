import SwiftUI
import AppKit
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

@Observable
@MainActor
class MenuBarState {
    static let shared = MenuBarState()
    var deepseekBalance: Double?
    var minimaxBalance: Double?
    var openAIQuota: OpenAIQuota?
    var openAIEstimatedCost: Double?
    var usageHistoryWarning: String?
    var availableUpdate: UpdateInfo?
    var hourlyUsage: [HourlyUsageBucket] = []
    var deepseekBalanceHistory: [DeepSeekBalanceSnapshot] = []
    var openAIQuotaHistory: [OpenAIQuotaSnapshot] = []
    var lastUpdated: Date?
    private let estimatedCost: @MainActor (Date) -> Double?

    init(estimatedCost: @escaping @MainActor (Date) -> Double? = { resetDate in
        QuotaLedgerService.shared.activeOpenAIEstimatedCost(resetDate: resetDate)
    }) {
        self.estimatedCost = estimatedCost
    }

    func update(with cache: WidgetCache) {
        deepseekBalance = cache.deepseek.balance
        minimaxBalance = cache.minimax.balance
        openAIQuota = cache.openAIQuota
        if let resetDate = cache.openAIQuota?.resetDate {
            openAIEstimatedCost = estimatedCost(resetDate)
        } else { openAIEstimatedCost = nil }
        hourlyUsage = cache.hourlyUsage
        usageHistoryWarning = cache.usageHistoryWarning
        deepseekBalanceHistory = cache.deepseekBalanceHistory
        openAIQuotaHistory = cache.openAIQuotaHistory
        lastUpdated = cache.lastUpdated
    }
}

@main
struct OpencodeWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ProviderSettingsView(preferences: ProviderPresentationContext.preferences)
        }
    }
}

@MainActor
private enum ProviderPresentationContext {
    static let preferences = ProviderDisplayPreferences()
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        buildMenu()

        refreshData()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshData()
            }
        }
    }

    private func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func updateStatusIcon() {
        let state = MenuBarState.shared

        guard let dsIcon = loadIcon("deepseek"),
              let mmIcon = loadIcon("minimax") else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "#")
            return
        }

        let size: CGFloat = 14
        let gap: CGFloat = 2
        let totalWidth = size * 2 + gap
        let img = NSImage(size: NSSize(width: totalWidth, height: size))
        img.lockFocus()
        dsIcon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        mmIcon.draw(in: NSRect(x: size + gap, y: 0, width: size, height: size))
        img.unlockFocus()
        img.isTemplate = state.deepseekBalance != nil || state.minimaxBalance != nil

        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
    }

    private func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let host = NSHostingView(rootView: MenuContent(preferences: ProviderPresentationContext.preferences))

        host.frame.size = host.fittingSize
        host.autoresizingMask = [.width, .height]
        item.view = host

        menu.addItem(item)
        statusItem.menu = menu
        statusItem.button?.sendAction(on: .leftMouseDown)
        statusItem.button?.target = nil
        statusItem.button?.action = nil
    }

    private func refreshData() {
        Task { [weak self] in
            let cache = await DataFetcher.refreshAll()
            let usage = await Task.detached { LocalUsageReader().fetch() }.value
            QuotaLedgerService.shared.recordRefresh(cache: cache, usage: usage)
            await QuotaLedgerService.shared.runMonthlyReportIfDue()
            let seeded = QuotaLedgerService.shared.seededCache(from: cache)
            DataStore.save(cache: seeded)
            guard let self else { return }
            updateMenuState(with: seeded)
            updateStatusIcon()
            await UpdateService.shared.publishAvailability()
        }
    }

    private func updateMenuState(with cache: WidgetCache) {
        MenuBarState.shared.update(with: cache)
    }
}

@MainActor
struct MenuContent: View {
    @State private var menuState = MenuBarState.shared
    @State private var chartOffsetHours = 0
    @State private var preferences: ProviderDisplayPreferences

    @MainActor
    init(preferences: ProviderDisplayPreferences) {
        _preferences = State(initialValue: preferences)
    }

    enum FooterAction: String {
        case refresh = "Refresh"
        case settings = "Settings"
        case quit = "Quit"
    }

    static let footerActions: [FooterAction] = [.refresh, .settings, .quit]
    static let usesNativeSettingsLink = true

    static func visibleCards(preferences: ProviderDisplayPreferences) -> [ProviderID] {
        ProviderCardLayout.visibleCards(preferences: preferences)
    }

    static func quotaText(_ quota: OpenAIQuota?) -> String {
        remainingText(quota?.remainingPercent)
    }

    static func remainingText(_ percent: Double?) -> String {
        guard let percent, percent.isFinite, (0...100).contains(percent) else { return "Quota unavailable" }
        return String(format: "%.0f%% remaining", percent)
    }

    struct QuotaRow: Identifiable {
        var id: String { label }
        let label: String
        let remainingPercent: Double?
        let resetDate: Date?
        let cycleHours: Double
    }

    static func quotaRows(_ quota: OpenAIQuota?) -> [QuotaRow] {
        [QuotaRow(label: "5h", remainingPercent: quota?.fiveHourRemainingPercent, resetDate: quota?.fiveHourResetDate, cycleHours: 5),
         QuotaRow(label: "Weekly", remainingPercent: quota?.remainingPercent, resetDate: quota?.resetDate, cycleHours: 168)]
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        return "Resets " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func estimatedCostText(_ cost: Double?) -> String {
        guard let cost, cost.isFinite else { return "Est. unavailable" }
        return String(format: "Est. $%.2f", cost)
    }

    static func elapsedText(resetDate: Date?, now: Date = Date()) -> String? {
        guard let resetDate else { return nil }
        let hours = QuotaResetTimeline(resetDate: resetDate).elapsedHours(at: now)
        return String(format: "%.0fh of 168h", hours)
    }

    static func previousOffset(current: Int, historyCount: Int) -> Int {
        min(current + ChartWindow.stepHours, ChartWindow.maximumOffset(for: historyCount))
    }

    static func nextOffset(current: Int) -> Int {
        max(0, current - ChartWindow.stepHours)
    }

    var body: some View {
        let historyCount = menuState.hourlyUsage.count
        let newestHour = menuState.hourlyUsage.last?.hour ?? Date()
        let chartRange = ChartWindow.range(endingAt: newestHour, offsetHours: chartOffsetHours)
        let usageBuckets = menuState.hourlyUsage.filter { chartRange.contains($0.hour) }
        let balanceSnapshots = menuState.deepseekBalanceHistory.filter { chartRange.contains($0.hour) }
        let openAISnapshots = menuState.openAIQuotaHistory.filter { chartRange.contains($0.hour) }
        let visibleCards = Self.visibleCards(preferences: preferences)

        VStack(spacing: 0) {
            if visibleCards.contains(.deepseek) || visibleCards.contains(.minimax) {
                HStack(spacing: 8) {
                    if visibleCards.contains(.deepseek) {
                        balanceCard(title: "DeepSeek", balance: menuState.deepseekBalance) {
                            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
                        }
                    }
                    if visibleCards.contains(.minimax) {
                        balanceCard(title: "MiniMax", balance: menuState.minimaxBalance) {
                            NSWorkspace.shared.open(URL(string: "https://platform.minimax.io/console/recharge-records?operation=RECHARGE&type=SUCCESS")!)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            if visibleCards.contains(.openAI) {
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/usage")!)
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("OpenAI").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(Self.estimatedCostText(menuState.openAIEstimatedCost))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        ForEach(Self.quotaRows(menuState.openAIQuota)) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.label).font(.caption).foregroundColor(.secondary)
                                Text(Self.remainingText(row.remainingPercent))
                                    .font(.headline).fontWeight(.semibold).monospacedDigit()
                                QuotaResetBar(remainingPercent: row.remainingPercent, resetDate: row.resetDate, cycleHours: row.cycleHours)
                                    .padding(.top, 2)
                                Text(Self.resetText(row.resetDate))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack {
                Button {
                    chartOffsetHours = Self.previousOffset(current: chartOffsetHours, historyCount: historyCount)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(chartOffsetHours == ChartWindow.maximumOffset(for: historyCount))

                Spacer()

                Button {
                    chartOffsetHours = Self.nextOffset(current: chartOffsetHours)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(chartOffsetHours == 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            UsageHistoryChart(buckets: usageBuckets, xDomain: chartRange)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            if let warning = menuState.usageHistoryWarning {
                Text(warning).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 4)
            }

            if let update = menuState.availableUpdate {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("v\(update.version) available")
                    Spacer()
                    Button("Update") { NSWorkspace.shared.open(update.releaseURL) }
                        .buttonStyle(.plain)
                    Button {
                        UpdateService.shared.skip(version: update.version)
                        menuState.availableUpdate = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .help(update.notes.isEmpty ? "Open the release page" : update.notes)
            }

            RemainingQuotaChart(
                deepseekSnapshots: balanceSnapshots,
                openAISnapshots: openAISnapshots,
                hourlyUsage: usageBuckets,
                xDomain: chartRange
            )
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Divider().padding(.vertical, 8)

            VStack(spacing: 2) {
                Button("Refresh") { refreshData() }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4).keyboardShortcut("r")
                Divider()
                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4).keyboardShortcut("q")
                Divider()
                versionLabel
                    .padding(.top, 2)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 220)
        .onChange(of: menuState.hourlyUsage) { _, history in
            chartOffsetHours = min(chartOffsetHours, ChartWindow.maximumOffset(for: history.count))
        }
    }

    /// Version readout in the same compact monospaced style Aman uses in Hermes:
    /// `# v1.5.3 (build 9)`, switching to `# v1.5.3 (update)` when a release is waiting.
    @ViewBuilder
    private var versionLabel: some View {
        if let update = menuState.availableUpdate {
            Button {
                NSWorkspace.shared.open(update.releaseURL)
            } label: {
                Text("# v\(AppVersion.short) (update)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Open the v\(update.version) release page")
        } else {
            Text("# v\(AppVersion.short) (build \(AppVersion.build))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private static let usdToMYR: Double = 4.5

    private func balanceCard(title: String, balance: Double?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                if let balance {
                    Text(String(format: "$%.2f", balance))
                        .font(.headline).fontWeight(.semibold).monospacedDigit()
                    Text(String(format: "RM%.2f", balance * Self.usdToMYR))
                        .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                } else {
                    Text("--").font(.headline).fontWeight(.semibold).monospacedDigit()
                    Text("RM--").font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(6)
    }

    private func refreshData() {
        Task {
            let cache = await DataFetcher.refreshAll()
            let usage = await Task.detached { LocalUsageReader().fetch() }.value
            QuotaLedgerService.shared.recordRefresh(cache: cache, usage: usage)
            await QuotaLedgerService.shared.runMonthlyReportIfDue()
            let seeded = QuotaLedgerService.shared.seededCache(from: cache)
            DataStore.save(cache: seeded)
            MenuBarState.shared.update(with: seeded)
            await UpdateService.shared.publishAvailability()
        }
    }
}
