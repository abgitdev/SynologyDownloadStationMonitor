import Foundation
import AppKit
import CryptoKit
import Security
import SwiftUI
import UniformTypeIdentifiers

// Example shown as placeholder in the Host field. The app connects to whatever
// private/LAN address the user enters (validated by validateLocalHost).
let hostFieldPlaceholder = "192.168.1.50 or synology.local"

@main
struct SynologyDownloadStationMonitorApp: App {
    var body: some Scene {
        // Single window (not WindowGroup): the app holds one DSM session/SID, so we
        // must not let File ▸ New Window spawn parallel sessions (audit #84).
        Window("Synology Download Station Monitor", id: "main") {
            MonitorView()
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Theme

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

enum Theme {
    static let windowTop = Color(hex: 0x1f1f22)
    static let windowBottom = Color(hex: 0x161618)
    static let windowGradient = LinearGradient(colors: [windowTop, windowBottom], startPoint: .top, endPoint: .bottom)

    static let text = Color(hex: 0xf5f5f7)
    static let textDim = Color(hex: 0xc7c7cc)
    static let textDim2 = Color(hex: 0xaeaeb2)
    static let textMuted = Color(hex: 0x8e8e93)
    static let textFaint = Color(hex: 0x636366)
    static let textGhost = Color(hex: 0x6c6c70)

    static let accent = Color(hex: 0xff9f0a)
    static let accentDeep = Color(hex: 0xff7a00)
    static let accentHi = Color(hex: 0xffb340)
    static let accentBar = LinearGradient(colors: [accentDeep, accentHi], startPoint: .leading, endPoint: .trailing)
    static let accentButton = LinearGradient(colors: [Color(hex: 0xffab2e), Color(hex: 0xff8c00)], startPoint: .top, endPoint: .bottom)

    static let green = Color(hex: 0x30d158)
    static let greenDeep = Color(hex: 0x28b84e)
    static let greenBar = LinearGradient(colors: [greenDeep, green], startPoint: .leading, endPoint: .trailing)
    static let red = Color(hex: 0xff453a)
    static let pausedBar = Color(hex: 0x6c6c70)

    static func whiteA(_ o: Double) -> Color { .white.opacity(o) }
}

enum Col {
    static let size: CGFloat = 84
    static let progress: CGFloat = 190
    static let down: CGFloat = 92
    static let up: CGFloat = 92
    static let uploaded: CGFloat = 104
    static let left: CGFloat = 78
    static let gap: CGFloat = 14
    static let hPad: CGFloat = 22
}

// MARK: - Task classification & system info

enum TaskKind {
    case downloading, seeding, paused, finished, waiting, error, other
}

extension DownloadTask {
    var kind: TaskKind {
        switch status.lowercased() {
        case "downloading": return .downloading
        case "seeding": return .seeding
        case "paused": return .paused
        case "finished": return .finished
        case "waiting": return .waiting
        case "error": return .error
        default: return .other
        }
    }
    var ratio: Double {
        guard downloaded > 0 else { return 0 }
        return Double(uploaded) / Double(downloaded)
    }
    var displayTitle: String { decodedPercentTitle(title) }
    var destination: String? { additional?.detail?.destination }
    var sourceURI: String? { additional?.detail?.uri }

    /// Fraction the progress bar should fill (seeding/finished render full).
    var barFraction: Double {
        switch kind {
        case .seeding, .finished: return 1
        default: return progress
        }
    }
    var progressCaption: String {
        let pct = Int((progress * 100).rounded())
        switch kind {
        case .downloading: return "\(pct)%"
        case .waiting: return "Queued"
        case .seeding: return "Seeding · 100%"
        case .finished: return "Completed · 100%"
        case .paused: return "Paused · \(pct)%"
        case .error: return "Error"
        case .other: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct DiskVolume: Hashable {
    let name: String
    let totalBytes: Int64
    let usedBytes: Int64
    var usedFraction: Double { totalBytes > 0 ? min(max(Double(usedBytes) / Double(totalBytes), 0), 1) : 0 }
    var freeText: String {
        // Saturating subtraction: a hostile NAS reporting used > total must not trap (F25).
        let (free, overflow) = totalBytes.subtractingReportingOverflow(usedBytes)
        return "\(formatBytes(overflow ? 0 : free)) free"
    }
    var percentText: String { "\(Int((usedFraction * 100).rounded()))%" }
}

struct SystemInfo: Hashable {
    var volume: DiskVolume?
    var dsmVersion: String?
    var uptimeSeconds: Int64 = 0

    /// "DSM 7.2.1-69057 Update 5" -> "DSM 7.2.1"
    var dsmVersionShort: String? {
        guard let v = dsmVersion, !v.isEmpty else { return nil }
        return v.split(separator: "-").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? v
    }
    var uptimeText: String? {
        guard uptimeSeconds > 0 else { return nil }
        return "uptime \(formatUptime(uptimeSeconds))"
    }
}

func formatUptime(_ seconds: Int64) -> String {
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    let m = (seconds % 3600) / 60
    if d > 0 { return "\(d)d \(String(format: "%02d", h))h" }
    if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
    return "\(m)m"
}

enum TaskFilter: CaseIterable {
    case all, active, seeding, completed, paused
    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .seeding: return "Seeding"
        case .completed: return "Completed"
        case .paused: return "Paused"
        }
    }
}

// MARK: - Window chrome

struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func configureMonitorWindow() -> some View {
        background(WindowAccessor { window in
            window.title = "Synology Download Station"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.backgroundColor = NSColor(Theme.windowBottom)
            window.isMovableByWindowBackground = true
        })
    }
}

// MARK: - Reusable styling

private struct Hairline: View {
    var color: Color = Theme.whiteA(0.06)
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

struct DarkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.whiteA(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.whiteA(0.12), lineWidth: 1))
    }
}

struct ChipButtonStyle: ButtonStyle {
    var fg: Color = Theme.textDim
    var bg: Color = Theme.whiteA(0.04)
    var border: Color = Theme.whiteA(0.1)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg.opacity(configuration.isPressed ? 0.5 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentButton))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .shadow(color: Theme.accentDeep.opacity(0.45), radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
    }
}

// MARK: - Root

struct MonitorView: View {
    @StateObject private var model = MonitorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            Theme.windowGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                ConnectionToolbar(model: model)
                Hairline()
                SummaryRow(model: model)
                FilterTabsView(model: model)
                TaskListArea(model: model)
                StatusStrip(model: model)
                BottomBar(model: model)
            }

            if model.showConnectionSheet {
                ConnectionSheet(model: model)
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.bottom, 86)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .foregroundStyle(Theme.text)
        .animation(.easeOut(duration: 0.18), value: model.showConnectionSheet)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .configureMonitorWindow()
        .task { model.loadSavedPassword() }
        .onChange(of: scenePhase) { _, phase in
            model.setPollingActive(phase == .active)
        }
        .onAppear { if !model.isConnected { model.showConnectionSheet = true } }
        .confirmationDialog(model.deleteDialogTitle, isPresented: $model.confirmDelete) {
            Button(model.deleteTargetIDs.count > 1 ? "Remove \(model.deleteTargetIDs.count) tasks" : "Remove", role: .destructive) { Task { await model.deleteConfirmed() } }
            Button("Cancel", role: .cancel) { model.deleteTargetIDs = [] }
        }
        .confirmationDialog("Delete the app and all its data?", isPresented: $model.confirmUninstall, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await model.performUninstall() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The app will be moved to the Trash; settings, cache, and the password in Keychain will be erased permanently. The Local Network entry in macOS System Settings will remain — remove it manually.")
        }
        .confirmationDialog("Trust this NAS certificate?", isPresented: $model.pinConfirmPresented, titleVisibility: .visible) {
            Button("Trust and connect") { Task { await model.confirmPendingPin() } }
            Button("Cancel", role: .cancel) { model.cancelPendingPin() }
        } message: {
            Text("First connection to this address. Public key fingerprint (SHA-256):\n\(model.pendingPinFingerprint ?? "")\nThe password will be sent only after you confirm. If you're not sure, cancel.")
        }
        .alert("Two-step verification", isPresented: $model.otpPromptPresented) {
            TextField("6-digit code", text: $model.otpCode)
                .textContentType(.oneTimeCode)
            Button("Verify") { Task { await model.submitOTP() } }
            Button("Cancel", role: .cancel) { model.cancelOTP() }
        } message: {
            Text(model.otpError ?? "This account uses two-step verification. Enter the 6-digit code from your authenticator app.")
        }
    }
}

// MARK: - Connection toolbar

struct ConnectionToolbar: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        HStack(spacing: 12) {
            StatusPill(model: model)

            HStack(spacing: 6) {
                Text(model.host).font(.system(size: 12.5))
                Text("·").foregroundStyle(Theme.textFaint)
                Text("DSM").font(.system(size: 12.5))
            }
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.whiteA(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.whiteA(0.08), lineWidth: 1))

            if let volume = model.systemInfo?.volume {
                DiskWidget(volume: volume)
            }

            Spacer()

            if model.isConnected && !model.selectedTaskIDs.isEmpty {
                SelectionActionBar(model: model)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            Button { Task { await model.refresh() } } label: {
                HStack(spacing: 6) {
                    // Plain, static refresh icon — no rotation/spin. The arrow must NOT
                    // animate around itself (explicit user requirement).
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!model.isConnected)

            if model.isConnected {
                Button { Task { await model.disconnect() } } label: { Text("Disconnect") }
                    .buttonStyle(ChipButtonStyle(fg: Theme.accent, bg: Theme.accent.opacity(0.1), border: Theme.accent.opacity(0.3)))
                    .disabled(model.isBusy)   // don't overlap disconnect/logout with an in-flight op (audit #23)
            } else {
                Button { model.openConnectionSheet() } label: { Text("Connect") }
                    .buttonStyle(ChipButtonStyle(fg: Theme.accent, bg: Theme.accent.opacity(0.1), border: Theme.accent.opacity(0.3)))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .animation(.easeOut(duration: 0.16), value: model.selectedTaskIDs.isEmpty)
    }
}

/// Batch actions for the current multi-selection — appears in the toolbar only while
/// one or more tasks are selected (Cmd/Shift-click to build the selection).
struct SelectionActionBar: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        HStack(spacing: 8) {
            Text("\(model.selectedTaskIDs.count) selected")
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.textDim)

            // Reuse the SAME ChipButtonStyle as Refresh/Disconnect (icon-only, tinted),
            // so every toolbar chip is exactly the same size/height.
            chip("play.fill", help: "Resume selected", tint: Theme.green) {
                Task { await model.resumeSelected() }
            }
            chip("pause.fill", help: "Pause selected", tint: Theme.accent) {
                Task { await model.pauseSelected() }
            }
            chip("trash", help: "Delete selected", tint: Theme.red) {
                model.requestDeleteSelected()
            }
        }
    }

    private func chip(_ system: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Fixed icon box so all three chips are identical width/height regardless
            // of glyph (play/pause are narrow, trash is wide).
            Image(systemName: system)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 17, height: 15)
        }
        .buttonStyle(ChipButtonStyle(fg: tint, bg: tint.opacity(0.14), border: tint.opacity(0.34)))
        .disabled(model.isBusy)
        .help(help)
    }
}

struct StatusPill: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        Button { model.openConnectionSheet() } label: {
            HStack(spacing: 8) {
                Circle().fill(model.statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: model.statusColor.opacity(0.9), radius: 4)
                Text(model.statusText).font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(model.statusColor)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(model.statusColor.opacity(0.12)))
            .overlay(Capsule().strokeBorder(model.statusColor.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DiskWidget: View {
    let volume: DiskVolume
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.fill").font(.system(size: 11)).opacity(0.8)
            Text(volume.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hex: 0xe5e5ea))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.whiteA(0.1)).frame(width: 120, height: 5)
                Capsule().fill(Theme.accentBar).frame(width: 120 * volume.usedFraction, height: 5)
            }
            Text(volume.freeText).font(.system(size: 12)).foregroundStyle(Theme.textMuted).monospacedDigit()
            Text(volume.percentText).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.accent).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.whiteA(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.whiteA(0.08), lineWidth: 1))
    }
}

// MARK: - Summary cards

struct SummaryRow: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(tint: Theme.accent, bg: Theme.accent.opacity(0.08), border: Theme.accent.opacity(0.16)) {
                Text("↓").font(.system(size: 18)).foregroundStyle(Theme.accent)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.totalDownText).font(.system(size: 18, weight: .bold)).monospacedDigit()
                    Text("download").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            SummaryCard(tint: Theme.green, bg: Theme.green.opacity(0.07), border: Theme.green.opacity(0.15)) {
                Text("↑").font(.system(size: 18)).foregroundStyle(Theme.green)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.totalUpText).font(.system(size: 18, weight: .bold)).monospacedDigit()
                    Text("upload").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            SummaryCard(tint: Theme.text, bg: Theme.whiteA(0.04), border: Theme.whiteA(0.07)) {
                Text("\(model.activeDownloads)").font(.system(size: 18, weight: .bold))
            } content: {
                Text("active\ndownloads").font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineSpacing(1)
            }
            SummaryCard(tint: Theme.text, bg: Theme.whiteA(0.04), border: Theme.whiteA(0.07)) {
                Text("\(model.seedingCount)").font(.system(size: 18, weight: .bold))
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("seeding").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Text("\(model.seedingUploadedText) up").font(.system(size: 11)).foregroundStyle(Theme.green)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

struct SummaryCard<Icon: View, Content: View>: View {
    let tint: Color
    let bg: Color
    let border: Color
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            icon
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Filter tabs

struct FilterTabsView: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(TaskFilter.allCases, id: \.self) { filter in
                let selected = model.activeFilter == filter
                Button { model.activeFilter = filter } label: {
                    HStack(spacing: 5) {
                        Text(filter.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        Text("\(model.count(for: filter))").font(.system(size: 12.5)).opacity(0.6)
                    }
                    .foregroundStyle(selected ? Theme.text : Color(hex: 0xaeaeb2))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.18) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent.opacity(0.3) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 14)
    }
}

// MARK: - Task list

struct TaskListArea: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        let tasks = model.filteredTasks
        Group {
            if tasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    TaskHeaderRow()
                    Hairline()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tasks) { task in
                                TaskRow(task: task, model: model)
                                Hairline(color: Theme.whiteA(0.04))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isConnected ? "tray" : "externaldrive.connected.to.line.below")
                .font(.system(size: 40)).foregroundStyle(Theme.textMuted)
            Text(model.isConnected ? "No tasks in this view" : "Not connected")
                .font(.title3).foregroundStyle(Theme.text)
            Text(model.isConnected
                 ? "Download Station has no tasks matching this filter."
                 : "Open the connection panel to sign in to your Synology over LAN.")
                .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            if !model.isConnected {
                Button { model.openConnectionSheet() } label: {
                    HStack(spacing: 6) { Image(systemName: "network"); Text("Connect") }
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TaskHeaderRow: View {
    var body: some View {
        HStack(spacing: Col.gap) {
            cell("Name", maxWidth: true)
            cell("Size", width: Col.size)
            cell("Progress", width: Col.progress)
            cell("↓ Speed", width: Col.down)
            cell("↑ Speed", width: Col.up)
            cell("Uploaded", width: Col.uploaded)
            cell("Left", width: Col.left)
        }
        .padding(.horizontal, Col.hPad).padding(.bottom, 8)
    }
    private func cell(_ text: String, width: CGFloat? = nil, maxWidth: Bool = false) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textGhost)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: maxWidth ? .infinity : nil, alignment: .leading)
    }
}

struct TaskRow: View {
    let task: DownloadTask
    @ObservedObject var model: MonitorModel

    var body: some View {
        let selected = model.selectedTaskIDs.contains(task.id)
        HStack(spacing: Col.gap) {
            HStack(spacing: 8) {
                leadingIndicator
                Text(task.displayTitle).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(task.size)).font(.system(size: 12.5)).foregroundStyle(Theme.textDim2)
                .frame(width: Col.size, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                ProgressTrack(fraction: task.barFraction, kind: task.kind)
                Text(task.progressCaption).font(.system(size: 11))
                    .foregroundStyle(task.kind == .seeding ? Theme.green : Theme.textMuted)
            }
            .frame(width: Col.progress, alignment: .leading)

            Text(task.speedDownload > 0 ? formatSpeed(task.speedDownload) : "0 B/s")
                .font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(task.speedDownload > 0 ? Theme.accent : Theme.textFaint)
                .frame(width: Col.down, alignment: .leading)

            Text(task.speedUpload > 0 ? formatSpeed(task.speedUpload) : "0 B/s")
                .font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(task.speedUpload > 0 ? Theme.green : Theme.textFaint)
                .frame(width: Col.up, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(formatBytes(task.uploaded)).font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(task.kind == .seeding ? Theme.green : Theme.textDim2)
                Text(String(format: "ratio %.2f", task.ratio)).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            .frame(width: Col.uploaded, alignment: .leading)

            Text(leftText).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.textDim2)
                .frame(width: Col.left, alignment: .leading)
        }
        .padding(.horizontal, Col.hPad).padding(.vertical, 13)
        .opacity(task.kind == .paused ? 0.55 : 1)
        .background(selected ? Theme.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.handleRowTap(task.id) }
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var leadingIndicator: some View {
        switch task.kind {
        case .seeding: PulsingDot(color: Theme.green)
        case .paused: Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
        default: EmptyView()
        }
    }

    private var leftText: String {
        switch task.kind {
        case .seeding: return "∞"
        case .paused, .finished, .error: return "—"
        default: return formatTime(task.timeLeft)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button { model.showInFinder(task) } label: { Label("Show in Finder", systemImage: "folder") }
        if let uri = task.sourceURI, !uri.isEmpty {
            Button { model.copyURI(task) } label: { Label("Copy magnet / link", systemImage: "link") }
        }
        Button { model.openInDSM() } label: { Label("Open in DSM web", systemImage: "globe") }
        Divider()
        if task.kind == .paused {
            Button { Task { await model.resumeTask(task.id) } } label: { Label("Resume", systemImage: "play.fill") }
        } else {
            Button { Task { await model.pauseTask(task.id) } } label: { Label("Pause", systemImage: "pause.fill") }
        }
        Button(role: .destructive) { model.requestDelete(task.id) } label: { Label("Remove task", systemImage: "trash") }
    }
}

struct PulsingDot: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (sin(t / 2 * 2 * .pi) + 1) / 2
            Circle().fill(color)
                .frame(width: 8, height: 8)
                .opacity(0.45 + 0.55 * phase)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
    }
}

struct ProgressTrack: View {
    let fraction: Double
    let kind: TaskKind

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillWidth = max(0, w * fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(barFill)
                    .frame(width: fillWidth)
                    .overlay(shimmer(width: fillWidth).clipShape(Capsule()))
                    .modifier(SeedGlow(active: kind == .seeding))
            }
        }
        .frame(height: 7)
    }

    private var trackColor: Color {
        kind == .seeding ? Theme.green.opacity(0.15) : Theme.whiteA(0.08)
    }

    private var barFill: AnyShapeStyle {
        switch kind {
        case .seeding, .finished: return AnyShapeStyle(Theme.greenBar)
        case .paused: return AnyShapeStyle(Theme.pausedBar)
        case .error: return AnyShapeStyle(Theme.red)
        default: return AnyShapeStyle(Theme.accentBar)
        }
    }

    @ViewBuilder private func shimmer(width: CGFloat) -> some View {
        if (kind == .downloading || kind == .seeding) && width > 4 {
            TimelineView(.animation) { timeline in
                let period = 1.9
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let band = max(20, width * 0.35)
                let x = -band + t * (width + band)
                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: x)
            }
        }
    }
}

struct SeedGlow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let g = (sin(t / 2.6 * 2 * .pi) + 1) / 2
                content.shadow(color: Theme.green.opacity(0.15 + 0.4 * g), radius: 2 + 6 * g)
            }
        } else {
            content
        }
    }
}

// MARK: - Status strip

enum AppInfo {
    /// Marketing version from Info.plist, e.g. "v1.4.0" (build number is not shown to users).
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(short)"
    }()
}

struct StatusStrip: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 14) {
            item(AppInfo.version)
            dot
            item("\(model.tasks.count) tasks")
            dot
            item("\(model.totalSizeText) total")
            dot
            item("\(model.totalUploadedText) uploaded")
            Spacer()
            if let version = model.systemInfo?.dsmVersionShort {
                item(version)
            }
            if let uptime = model.systemInfo?.uptimeText {
                dot
                item(uptime)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) { Hairline(color: Theme.whiteA(0.05)) }
    }
    private func item(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).monospacedDigit()
    }
    private var dot: some View { Text("·").foregroundStyle(Color(hex: 0x48484a)) }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 12) {
            TextField("URL or magnet link…", text: $model.newURI)
                .modifier(DarkField())
                .onSubmit { Task { await model.addDownload() } }
                .disabled(!model.isConnected)

            Button { Task { await model.addDownload() } } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("Add") }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!model.isConnected || model.newURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button { model.pickTorrentFile() } label: {
                HStack(spacing: 6) { Image(systemName: "doc.badge.plus"); Text("Torrent") }
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!model.isConnected)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Connection sheet

struct ConnectionSheet: View {
    @ObservedObject var model: MonitorModel
    @FocusState private var focusedField: Field?

    private enum Field { case host, username, password }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.closeConnectionSheet() }
                .onExitCommand { model.closeConnectionSheet() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Connect to Synology").font(.system(size: 14, weight: .bold))
                Text("Enter your DSM details. This app works on the local network only.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .padding(.top, 2).padding(.bottom, 18)

                HStack(alignment: .top, spacing: 12) {
                    field("Host / IP") {
                        TextField(hostFieldPlaceholder, text: $model.host).modifier(DarkField())
                            .focused($focusedField, equals: .host)
                            .onChange(of: model.host) { _, _ in model.loadSavedPassword() }
                            .help("The local address of your Synology NAS (a private IP such as 192.168.x.x / 10.x.x.x or a name like synology.local).")
                    }
                    field("Protocol", width: 128) {
                        Menu {
                            Button("Auto (HTTPS)") { model.protocolPreference = .auto }
                            Button("HTTPS") { model.protocolPreference = .https }
                            Button("HTTP") { model.protocolPreference = .http }
                        } label: {
                            HStack {
                                Text(portLabel)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                            }
                            .modifier(DarkField())
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel("Connection protocol")
                    }
                    field("Port", width: 84) {
                        TextField(model.protocolPreference == .http ? "5000" : "5001", text: portText)
                            .modifier(DarkField())
                            .help("DSM port. Defaults are 5001 (HTTPS) / 5000 (HTTP) — change it if yours differs.")
                    }
                }
                .padding(.bottom, 12)

                HStack(spacing: 12) {
                    field("Username") {
                        TextField("DSM username", text: $model.username).modifier(DarkField())
                            .focused($focusedField, equals: .username)
                            .onChange(of: model.username) { _, _ in model.loadSavedPassword() }
                    }
                    field("Password") {
                        SecureField("DSM password", text: $model.password).modifier(DarkField())
                            .focused($focusedField, equals: .password)
                            .onSubmit { Task { await model.connect() } }
                    }
                }
                .padding(.bottom, 14)

                HStack {
                    Toggle(isOn: $model.allowSelfSigned) {
                        Text("Allow self-signed certificate").font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button { model.forgetSavedCredentials() } label: {
                        Text("Forget login details").font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Remove the saved username, password, and trusted certificate from this Mac")
                    Button { model.resetPinnedCertificate() } label: {
                        Text("Reset certificate").font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Reset if the NAS changed its TLS certificate and connecting stopped working")
                }
                .padding(.bottom, 18)

                if model.protocolPreference == .http {
                    Text("⚠︎ HTTP is unencrypted — your password will be sent in clear text. Use HTTPS if possible.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }

                if let message = model.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(model.connectionState == .error ? Theme.red : Theme.textMuted)
                        .lineLimit(2)
                        .padding(.bottom, 12)
                }

                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.green).frame(width: 7, height: 7).shadow(color: Theme.green.opacity(0.8), radius: 4)
                        Text("Local network only").font(.system(size: 12)).foregroundStyle(Theme.green)
                    }
                    Spacer()
                    Button { model.closeConnectionSheet() } label: { Text("Cancel") }
                        .buttonStyle(ChipButtonStyle(fg: Theme.textDim, bg: Theme.whiteA(0.05), border: Theme.whiteA(0.12)))
                    Button { Task { await model.connect() } } label: {
                        HStack(spacing: 6) { Image(systemName: "globe"); Text("Connect") }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
                }

                Hairline(color: Theme.whiteA(0.06)).padding(.vertical, 16)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Delete app").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textDim)
                        Text("Erases all data and moves the .app to the Trash").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button(role: .destructive) { model.confirmUninstall = true } label: {
                        HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete…") }
                    }
                    .buttonStyle(ChipButtonStyle(fg: Theme.red, bg: Theme.red.opacity(0.1), border: Theme.red.opacity(0.3)))
                    .disabled(model.isUninstalling)
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: 0x26262b), Color(hex: 0x202024)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Hairline(color: Theme.whiteA(0.1)) }
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 18)
            .transition(.move(edge: .top))
            .onAppear {
                focusedField = model.host.isEmpty ? .host : (model.username.isEmpty ? .username : .password)
                model.loadSavedPassword()   // refill from Keychain after a disconnect cleared it (R1-11)
            }
        }
    }

    private var portLabel: String {
        switch model.protocolPreference {
        case .auto: return "Auto"
        case .https: return "HTTPS"
        case .http: return "HTTP"
        }
    }

    /// Edits the port for the currently-selected scheme (HTTP edits httpPort, else
    /// httpsPort). Ignores non-numeric / out-of-range input.
    private var portText: Binding<String> {
        Binding(
            get: { String(model.protocolPreference == .http ? model.httpPort : model.httpsPort) },
            set: { raw in
                guard let n = Int(raw.filter(\.isNumber)), (1...65535).contains(n) else { return }
                if model.protocolPreference == .http { model.httpPort = n } else { model.httpsPort = n }
            }
        )
    }

    @ViewBuilder private func field<Content: View>(_ label: String, width: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            content()
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

// MARK: - Toast

struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text("✦").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0x26262a).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.whiteA(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password = ""
    @Published var allowSelfSigned = UserDefaults.standard.bool(forKey: "allowSelfSigned")
    @Published var protocolPreference = ProtocolPreference(rawValue: UserDefaults.standard.string(forKey: "protocolPreference") ?? "") ?? .auto
    @Published var httpsPort = (UserDefaults.standard.object(forKey: "httpsPort") as? Int) ?? 5001
    @Published var httpPort = (UserDefaults.standard.object(forKey: "httpPort") as? Int) ?? 5000
    @Published var connectionState: ConnectionState = .disconnected
    @Published var message: String?
    @Published var tasks: [DownloadTask] = [] {
        didSet {
            // Drop stale selections so batch actions can never target a task that
            // finished/was removed on the NAS between refreshes (audit H9).
            let valid = Set(tasks.map(\.id))
            if !selectedTaskIDs.isSubset(of: valid) {
                selectedTaskIDs = selectedTaskIDs.intersection(valid)
            }
            if let anchor = selectionAnchorID, !valid.contains(anchor) { selectionAnchorID = nil }
        }
    }
    /// Multi-selection of task ids — Cmd-click toggles one, Shift-click extends a
    /// range. The toolbar batch actions (resume/pause/remove) operate on this set.
    @Published var selectedTaskIDs: Set<String> = []
    /// Anchor row for Shift-click range selection.
    private var selectionAnchorID: String?
    @Published var newURI = ""
    @Published var confirmDelete = false
    @Published var isBusy = false

    @Published var showConnectionSheet = false
    @Published var activeFilter: TaskFilter = .all
    @Published var toast: String?
    @Published var systemInfo: SystemInfo?
    @Published var deleteTargetIDs: Set<String> = []
    @Published var confirmUninstall = false
    @Published var isUninstalling = false
    /// First-connect cert confirmation (audit F02): set when a brand-new NAS cert was
    /// seen; the sheet shows pendingPinFingerprint and the password is sent only on confirm.
    @Published var pinConfirmPresented = false
    @Published var pendingPinFingerprint: String?
    // 2-step verification (2FA) prompt: shown only when the NAS account requires an OTP.
    @Published var otpPromptPresented = false
    @Published var otpCode = ""
    @Published var otpError: String?
    private var pendingPinValue: String?
    private var pendingPinHost: String?

    private var toastTask: Task<Void, Never>?
    private var loadPasswordTask: Task<Void, Never>?
    private var client: SynologyClient?
    private var pollTask: Task<Void, Never>?
    private var sysInfoTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var terminationObserver: NSObjectProtocol?
    private var consecutivePollFailures = 0
    private let maxPollFailures = 3

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // queue:.main → already on the main thread/actor; run teardown SYNCHRONOUSLY so it
            // completes before the process exits (a Task{} here would not run in time) — F16.
            MainActor.assumeIsolated { self?.cancelLocalSessionForClose() }
        }
    }

    deinit {
        // deinit may run off the main actor, so only the thread-safe observer removal here;
        // session teardown happens via the willTerminate handler (audit F50/F16).
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var isConnected: Bool { connectionState == .connected }
    var statusText: String {
        switch connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .error: "Error"
        }
    }
    var statusColor: Color {
        switch connectionState {
        case .disconnected: Theme.textMuted
        case .connecting: Theme.accent
        case .connected: Theme.green
        case .error: Theme.red
        }
    }

    // MARK: Aggregates

    var totalDownText: String { formatSpeed(saturatingSum(tasks.map(\.speedDownload))) }
    var totalUpText: String { formatSpeed(saturatingSum(tasks.map(\.speedUpload))) }
    var activeDownloads: Int { tasks.filter { $0.kind == .downloading }.count }
    var seedingCount: Int { tasks.filter { $0.kind == .seeding }.count }
    var seedingUploadedText: String { formatBytes(saturatingSum(tasks.filter { $0.kind == .seeding }.map(\.uploaded))) }
    var totalSizeText: String { formatBytes(saturatingSum(tasks.map(\.size))) }
    var totalUploadedText: String { formatBytes(saturatingSum(tasks.map(\.uploaded))) }

    /// "Active" = anything that isn't seeding/finished/paused, so .error/.other tasks stay
    /// visible in a tab instead of vanishing from every category (audit F42).
    private func isActiveKind(_ kind: TaskKind) -> Bool {
        !(kind == .seeding || kind == .finished || kind == .paused)
    }

    var filteredTasks: [DownloadTask] {
        switch activeFilter {
        case .all: return tasks
        case .active: return tasks.filter { isActiveKind($0.kind) }
        case .seeding: return tasks.filter { $0.kind == .seeding }
        case .completed: return tasks.filter { $0.kind == .finished }
        case .paused: return tasks.filter { $0.kind == .paused }
        }
    }

    func count(for filter: TaskFilter) -> Int {
        switch filter {
        case .all: return tasks.count
        case .active: return tasks.filter { isActiveKind($0.kind) }.count
        case .seeding: return seedingCount
        case .completed: return tasks.filter { $0.kind == .finished }.count
        case .paused: return tasks.filter { $0.kind == .paused }.count
        }
    }

    // MARK: Connection sheet & toast

    func openConnectionSheet() { showConnectionSheet = true }
    func closeConnectionSheet() { showConnectionSheet = false }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Per-task actions

    // MARK: Row selection (plain click / Cmd-toggle / Shift-range)

    /// Handle a click on a task row, honouring the held modifier keys:
    /// plain = select only this; Cmd = toggle this in/out; Shift = extend a range
    /// from the anchor row through this one (in the order the rows are displayed).
    func handleRowTap(_ id: String) {
        let flags = NSEvent.modifierFlags
        let ordered = filteredTasks.map(\.id)
        if flags.contains(.command) {
            if selectedTaskIDs.contains(id) {
                selectedTaskIDs.remove(id)
                // Don't leave the anchor on a now-unselected row (audit R2-13).
                if selectionAnchorID == id {
                    selectionAnchorID = ordered.last(where: { selectedTaskIDs.contains($0) })
                }
            } else {
                selectedTaskIDs.insert(id)
                selectionAnchorID = id
            }
        } else if flags.contains(.shift) {
            // Extend a range from the anchor; if either endpoint can't be resolved, just add
            // this one row instead of collapsing the whole selection (audit F43).
            if let anchor = selectionAnchorID,
               let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
                selectedTaskIDs.formUnion(ordered[min(a, b)...max(a, b)])
            } else {
                selectedTaskIDs.insert(id)
                selectionAnchorID = id
            }
        } else {
            selectedTaskIDs = [id]
            selectionAnchorID = id
        }
    }

    /// Selected ids in display order; any selection outside the current filter is
    /// appended so a batch action never silently skips a hidden-but-selected task.
    var orderedSelectedIDs: [String] {
        let visible = filteredTasks.map(\.id).filter { selectedTaskIDs.contains($0) }
        return visible + Array(selectedTaskIDs.subtracting(visible))
    }

    func pauseTask(_ id: String) async { await performTaskAction("pause", ids: [id], toast: "Task paused") }
    func resumeTask(_ id: String) async { await performTaskAction("resume", ids: [id], toast: "Task resumed") }

    func pauseSelected() async {
        let ids = orderedSelectedIDs
        await performTaskAction("pause", ids: ids, toast: ids.count > 1 ? "Paused: \(ids.count)" : "Task paused")
    }
    func resumeSelected() async {
        let ids = orderedSelectedIDs
        await performTaskAction("resume", ids: ids, toast: ids.count > 1 ? "Resumed: \(ids.count)" : "Task resumed")
    }

    /// Context-menu Remove targets just the right-clicked task.
    func requestDelete(_ id: String) {
        deleteTargetIDs = [id]
        confirmDelete = true
    }

    /// Toolbar Remove targets every selected task.
    func requestDeleteSelected() {
        guard !selectedTaskIDs.isEmpty else { return }
        deleteTargetIDs = selectedTaskIDs
        confirmDelete = true
    }

    var deleteDialogTitle: String {
        deleteTargetIDs.count > 1
            ? "Remove \(deleteTargetIDs.count) tasks from Download Station?"
            : "Remove this task from Download Station?"
    }

    func deleteConfirmed() async {
        let visible = filteredTasks.map(\.id).filter { deleteTargetIDs.contains($0) }
        let targets = visible.isEmpty ? Array(deleteTargetIDs) : visible + Array(deleteTargetIDs.subtracting(visible))
        deleteTargetIDs = []
        guard !targets.isEmpty else { return }
        await performTaskAction("delete", ids: targets, toast: targets.count > 1 ? "Deleted: \(targets.count)" : "Task deleted")
    }

    /// DSM's SYNO.DownloadStation.Task pause/resume/delete accept a comma-separated
    /// id list, so a batch is a single round-trip.
    private func performTaskAction(_ method: String, ids: [String], toast toastText: String) async {
        guard !isBusy, isConnected, let client, !ids.isEmpty else { return }
        let generation = connectionGeneration
        isBusy = true
        defer { if generation == connectionGeneration { isBusy = false } }
        do {
            try await client.taskAction(method: method, id: ids.joined(separator: ","))
            try await replaceTasksAfterOperation(using: client, generation: generation)
            showToast(toastText)
        } catch {
            handleOperationError(error, client: client, generation: generation)
        }
    }

    /// Open the DSM web UI in the browser using the scheme/port the app actually connected
    /// with — not a hardcoded https:5001 (audit F26/R1-05). NOTE: the browser session is
    /// outside this app's certificate pinning, and the NAS address lands in browser history,
    /// which the in-app uninstall cannot remove (audit R2-11).
    func openInDSM() {
        let scheme = protocolPreference == .http ? "http" : "https"
        let port = protocolPreference == .http ? httpPort : httpsPort
        guard !normalizedHost.isEmpty, let url = URL(string: "\(scheme)://\(normalizedHost):\(port)") else { return }
        NSWorkspace.shared.open(url)
        showToast("Opening DSM in the browser (outside the app's protection)…")
    }

    func copyURI(_ task: DownloadTask) {
        guard let uri = task.sourceURI, !uri.isEmpty else { showToast("This task has no link"); return }
        // Validate the scheme before putting NAS-supplied text on the system pasteboard, and
        // mark it concealed — a magnet/URL can carry a private tracker passkey (audit F27/R2-10).
        let scheme = String(uri.prefix(while: { $0 != ":" }).lowercased())
        guard ["magnet", "http", "https", "ftp", "ftps", "ed2k"].contains(scheme) else {
            showToast("Unsupported link type"); return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(uri, forType: .string)
        pb.setString(uri, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        showToast("Link copied")
    }

    /// Reveal the task's file/folder in Finder via the locally-mounted NAS share.
    /// DSM `destination` like "Downloads/Torrents" maps to /Volumes/<share>/<rest>/<title>.
    func showInFinder(_ task: DownloadTask) {
        guard let destination = task.destination, !destination.isEmpty else {
            showToast("This task has no destination path")
            return
        }
        // destination + title come straight from the NAS, which the threat model
        // treats as possibly hostile. Reject any traversal/separator so a crafted task
        // can't point Finder outside the mounted share or at an attacker-chosen item,
        // resolve ONLY the share named in the destination (no fan-out across every
        // mounted volume), and always REVEAL — never .open, which could launch a
        // registered app/item the NAS controls (audit F03).
        let components = destination.split(separator: "/").map(String.init)
        guard let share = components.first,
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }),
              !task.title.isEmpty, !task.title.contains("/"),
              task.title != "..", task.title != "." else {
            showToast("Invalid path from the NAS")
            return
        }
        let fileManager = FileManager.default
        let root = "/Volumes/\(share)"
        let rootStd = (root as NSString).standardizingPath
        func inside(_ path: String) -> Bool {
            let s = (path as NSString).standardizingPath
            return s == rootStd || s.hasPrefix(rootStd + "/")
        }
        let subPath = components.dropFirst().joined(separator: "/")
        let folder = subPath.isEmpty ? root : "\(root)/\(subPath)"
        let item = "\(folder)/\(task.title)"

        if inside(item), fileManager.fileExists(atPath: item) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item)])
            showToast("Revealing in Finder…")
            return
        }
        if inside(folder), fileManager.fileExists(atPath: folder) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            showToast("Revealing the folder in Finder…")
            return
        }
        showToast("Folder not found — mount the NAS share in Finder")
    }

    // MARK: System info

    func fetchSystemInfo() async {
        guard let client else { return }
        let generation = connectionGeneration
        let info = await client.systemInfo()
        guard generation == connectionGeneration else { return }
        systemInfo = info
    }

    /// Single tracked system-info fetch — cancels any previous one so rapid Refresh clicks
    /// don't pile up overlapping round-trips racing on `systemInfo` (audit R1-08/R1-13).
    private func fetchSystemInfoTracked() {
        sysInfoTask?.cancel()
        sysInfoTask = Task { [weak self] in await self?.fetchSystemInfo() }
    }

    /// Forget the pinned NAS certificate so TOFU re-learns it on the next connect
    /// (use after a legitimate DSM cert change locks out the connection — review MEDIUM).
    func resetPinnedCertificate() {
        KeychainService.deletePin(host: normalizedHost)
        showToast("Trusted certificate reset — it will be re-learned on the next connection")
    }

    /// User confirmed a brand-new NAS cert fingerprint: persist the pin, then reconnect so
    /// login() can run against the now-trusted cert (audit F02).
    func confirmPendingPin() async {
        guard let pin = pendingPinValue, let host = pendingPinHost else { return }
        let ok = KeychainService.savePin(pin, host: host)
        pinConfirmPresented = false
        pendingPinFingerprint = nil; pendingPinValue = nil; pendingPinHost = nil
        guard ok else {
            connectionState = .error
            message = "Could not save the trusted certificate to Keychain."
            return
        }
        await connect()
    }

    func cancelPendingPin() {
        pinConfirmPresented = false
        pendingPinFingerprint = nil; pendingPinValue = nil; pendingPinHost = nil
        connectionState = .disconnected
        message = "Connection canceled — certificate not confirmed."
    }

    /// User entered a 2-step verification code: reconnect, this time sending the OTP.
    func submitOTP() async {
        let code = otpCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { otpError = "Enter the 6-digit code."; otpPromptPresented = true; return }
        otpPromptPresented = false
        await connect()
    }

    func cancelOTP() {
        otpPromptPresented = false
        otpCode = ""
        otpError = nil
        connectionState = .disconnected
        message = "Connection canceled — two-step verification code not entered."
    }

    /// "spki:<hex>" -> grouped hex for readable side-by-side comparison with DSM.
    static func formatFingerprint(_ pin: String) -> String {
        let hex = pin.hasPrefix("spki:") ? String(pin.dropFirst(5)) : pin
        var out = ""
        for (i, c) in hex.enumerated() {
            if i > 0 && i % 4 == 0 { out.append(" ") }
            out.append(c)
        }
        return out
    }

    /// Erase saved credentials for the current host/user: Keychain password, the cert pin,
    /// and the persisted host/username/prefs. Leaves the app installed (audit F28).
    func forgetSavedCredentials() {
        let host = normalizedHost, user = normalizedUsername
        if !host.isEmpty {
            if !user.isEmpty {
                KeychainService.delete(host: host, username: user)
                KeychainService.deleteDeviceToken(host: host, username: user)
            }
            KeychainService.deletePin(host: host)
        }
        let d = UserDefaults.standard
        for key in ["host", "username", "allowSelfSigned", "protocolPreference", "httpsPort", "httpPort"] {
            d.removeObject(forKey: key)
        }
        password = ""
        showToast("Saved login details removed from this Mac")
    }

    func loadSavedPassword() {
        // Runs on every host/username keystroke: debounce, only ever FILL an empty field
        // (never stomp what the user is typing), do the blocking Keychain read OFF the main
        // actor, and re-validate before assigning (audit F23/R2-06/#67).
        guard password.isEmpty else { return }
        let host = normalizedHost
        let user = normalizedUsername
        guard !user.isEmpty, !host.isEmpty else { return }
        loadPasswordTask?.cancel()
        loadPasswordTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let outcome: (password: String?, error: String?) = await Task.detached {
                do { return (try KeychainService.load(host: host, username: user), nil) }
                catch { return (nil, readable(error)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            // The fields may have changed (or been filled) while we waited.
            guard self.password.isEmpty, self.normalizedHost == host, self.normalizedUsername == user else { return }
            if let saved = outcome.password, !saved.isEmpty {
                self.password = saved
            } else if let err = outcome.error, !self.isConnected {
                self.message = "Could not load saved password from Keychain: \(err)"
            }
        }
    }

    func connect() async {
        guard !isBusy else { return }
        guard !isConnected else {
            message = "Already connected."
            return
        }

        let cleanHost = normalizedHost
        let cleanUsername = normalizedUsername
        do {
            try validateLocalHost(cleanHost)
        } catch {
            connectionState = .error
            message = readable(error)
            return
        }

        guard !cleanUsername.isEmpty, !password.isEmpty else {
            connectionState = .error
            message = "Enter DSM username and password."
            return
        }

        let generation = advanceSession()
        configuredDestination = nil
        pollTask?.cancel()
        pollTask = nil

        let oldClient = client
        client = nil

        isBusy = true
        connectionState = .connecting
        message = "Connecting to Synology Download Station..."
        defer {
            if generation == connectionGeneration {
                isBusy = false
            }
        }

        try? await oldClient?.logout()
        oldClient?.invalidate()

        let settings = ConnectionSettings(host: cleanHost, username: cleanUsername, protocolPreference: protocolPreference, allowSelfSigned: allowSelfSigned, httpsPort: httpsPort, httpPort: httpPort)
        let trimmedOTP = otpCode.trimmingCharacters(in: .whitespaces)
        let newClient = SynologyClient(settings: settings, password: password, otpCode: trimmedOTP.isEmpty ? nil : trimmedOTP)

        do {
            try await newClient.connect()
            let loadedTasks = try await newClient.listTasks()
            guard generation == connectionGeneration else {
                try? await newClient.logout()
                newClient.invalidate()
                return
            }

            self.client = newClient
            self.tasks = loadedTasks
            connectionState = .connected
            // (The NAS cert was confirmed before login via the pin-confirmation sheet on
            // first sight — audit F02 — so there is nothing to surface here now.)
            // Make sure this account has a Download Station default folder, otherwise
            // its new tasks would sit in "waiting" forever and never start.
            await ensureDownloadDestinationConfigured(using: newClient, generation: generation)
            if let keychainWarning = persistSuccessfulConnection(host: cleanHost, username: cleanUsername) {
                message = "Connected, but password was not saved in Keychain: \(keychainWarning)"
            } else if newClient.isInsecure {
                message = "Connected over HTTP without encryption — the password was sent in clear text. Use HTTPS 5001 if possible."
                showToast("⚠︎ Connected over HTTP — unencrypted")
            } else {
                message = "Connected. Showing Download Station tasks from Synology."
            }
            consecutivePollFailures = 0
            startPolling(generation: generation)
            showConnectionSheet = false
            otpPromptPresented = false
            otpCode = ""
            otpError = nil
            fetchSystemInfoTracked()
        } catch let pinReq as PinConfirmationRequired {
            newClient.invalidate()
            guard generation == connectionGeneration else { return }
            // No password was sent. Ask the user to confirm the fingerprint; on confirm we
            // persist the pin and reconnect, on cancel nothing is trusted (audit F02).
            pendingPinValue = pinReq.pin
            pendingPinHost = pinReq.host
            pendingPinFingerprint = Self.formatFingerprint(pinReq.pin)
            pinConfirmPresented = true
            connectionState = .disconnected
            message = "First confirm the NAS certificate fingerprint."
        } catch let otp as OTPRequired {
            newClient.invalidate()
            guard generation == connectionGeneration else { return }
            // The account has 2-step verification. No SID was issued; ask for the 6-digit
            // code and reconnect with it. Accounts without 2FA never get here.
            otpCode = ""
            otpError = otp.codeWasWrong ? "That code was incorrect — try again." : nil
            otpPromptPresented = true
            connectionState = .disconnected
            message = otp.codeWasWrong
                ? "Two-step verification code was incorrect — enter it again."
                : "This account uses two-step verification. Enter the 6-digit code."
        } catch {
            try? await newClient.logout()
            newClient.invalidate()
            guard generation == connectionGeneration else { return }
            guard !isCancellation(error) else {
                connectionState = .disconnected
                message = nil
                return
            }
            connectionState = .error
            message = readable(error)
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        guard let client else {
            connectionState = .disconnected
            message = "Not connected."
            return
        }
        let generation = connectionGeneration
        isBusy = true
        defer { if generation == connectionGeneration { isBusy = false } }
        await refreshTasks(using: client, generation: generation, userInitiated: true)
        fetchSystemInfoTracked()
    }

    func disconnect() async {
        let generation = advanceSession()
        pollTask?.cancel()
        pollTask = nil
        sysInfoTask?.cancel()
        sysInfoTask = nil
        toastTask?.cancel()
        toastTask = nil
        loadPasswordTask?.cancel()
        loadPasswordTask = nil

        let activeClient = client
        defer { activeClient?.invalidate() }
        client = nil
        tasks = []
        selectedTaskIDs = []
        selectionAnchorID = nil
        newURI = ""
        password = ""   // don't keep the plaintext credential in memory once disconnected (audit R1-11)
        systemInfo = nil
        connectionState = .disconnected
        message = "Disconnected from Synology Download Station."

        isBusy = true
        defer {
            if generation == connectionGeneration {
                isBusy = false
            }
        }

        do {
            try await activeClient?.logout()
        } catch {
            guard !isCancellation(error) else { return }
            message = "Disconnected locally. Synology logout returned: \(readable(error))"
        }
    }

    /// Folder existing tasks download into — passed to new tasks so DSM does not
    /// reject them with error 406 ("no default destination") when the account has
    /// no Download Station default location configured.
    /// The account's Download Station default folder as read/set on connect. Used as
    /// a fallback destination when there are no existing tasks to infer one from, so
    /// the proper .torrent file-upload path stays reachable for brand-new accounts.
    private var configuredDestination: String?

    var preferredDestination: String? {
        let dests = tasks.compactMap { $0.destination }.filter { !$0.isEmpty }
        guard !dests.isEmpty else { return configuredDestination }
        return Dictionary(grouping: dests, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    /// On connect, if the account has no Download Station default download folder,
    /// set one. This is the fix for the "task added but never starts (waiting)"
    /// problem that hits any account which has never opened Download Station before.
    private func ensureDownloadDestinationConfigured(using client: SynologyClient, generation: Int) async {
        // If we can read an existing default, keep it and remember it. If the read
        // FAILS, do nothing — never risk overwriting the user's real folder on a blip.
        do {
            if let existing = try await client.downloadDefaultDestination() {
                if generation == connectionGeneration { configuredDestination = existing }
                return
            }
        } catch {
            return
        }
        guard generation == connectionGeneration else { return }
        // Genuinely no default set: pick one (a folder existing tasks use, else a
        // sensible share) so this account's downloads actually start.
        var desired = preferredDestination
        if desired == nil {
            desired = await client.suggestedDestination()
        }
        guard let desired, generation == connectionGeneration else { return }
        do {
            try await client.setDefaultDestination(desired)
            if generation == connectionGeneration { configuredDestination = desired }
        } catch {
            // Best-effort: if it fails, new tasks may stay "waiting" and the add
            // flow will surface the real error.
        }
    }

    func addDownload() async {
        let uri = newURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, isConnected, let client, !uri.isEmpty else { return }
        // Only hand DSM the download schemes it expects; reject file://, internal
        // URLs, etc. so the app can't be used to make the NAS fetch arbitrary local
        // resources (audit #93).
        let scheme = uri.prefix(while: { $0 != ":" }).lowercased()
        let allowed = ["magnet", "http", "https", "ftp", "ftps", "ed2k"]
        guard allowed.contains(scheme) else {
            // Pure input-validation failure — surface a toast, don't flip a LIVE session into
            // the .error state (audit F13).
            showToast("Only magnet:, http(s):, ftp(s):, or ed2k: links are supported.")
            return
        }
        let generation = connectionGeneration

        isBusy = true
        defer {
            if generation == connectionGeneration {
                isBusy = false
            }
        }

        do {
            try await client.create(uri: uri, destination: preferredDestination)
            guard isCurrent(client, generation: generation) else { return }
            newURI = ""
            try await replaceTasksAfterOperation(using: client, generation: generation)
            message = "Download added to Synology Download Station."
        } catch {
            handleOperationError(error, client: client, generation: generation)
        }
    }

    func pickTorrentFile() {
        guard isConnected else { return }

        let panel = NSOpenPanel()
        panel.title = "Add Torrent"
        panel.message = "Choose a .torrent file to send to Synology Download Station."
        panel.prompt = "Add Torrent"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let torrentType = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [torrentType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addTorrentFile(url) }
    }

    func addTorrentFile(_ fileURL: URL) async {
        guard !isBusy, isConnected, let client else { return }
        let generation = connectionGeneration

        isBusy = true
        defer {
            if generation == connectionGeneration {
                isBusy = false
            }
        }

        let canAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let usedMagnet = try await client.createTorrent(fileURL: fileURL, destination: preferredDestination)
            guard isCurrent(client, generation: generation) else { return }
            // Surface when the real-file upload didn't take and we fell back to a magnet (F38).
            message = usedMagnet
                ? "Couldn't upload the file — added as a magnet (metadata will be fetched from peers)."
                : "Torrent file sent to Synology Download Station."
            try await replaceTasksAfterOperation(using: client, generation: generation)
        } catch {
            handleOperationError(error, client: client, generation: generation)
        }
    }

    func cancelLocalSessionForClose() {
        advanceSession()
        pollTask?.cancel()
        pollTask = nil
        sysInfoTask?.cancel()
        sysInfoTask = nil
        loadPasswordTask?.cancel()
        loadPasswordTask = nil
        toastTask?.cancel()
        toastTask = nil
        client?.invalidate()
        client = nil
        isBusy = false
        password = ""   // scrub the in-memory credential on teardown (audit R1-11)
    }

    /// Full self-uninstall: tear the session down cleanly (no zombie process or
    /// connection), wipe every on-disk / Keychain trace, trash the .app, and quit.
    func performUninstall() async {
        guard !isUninstalling else { return }
        isUninstalling = true

        // 1) Best-effort server-side logout, then the existing local teardown
        //    (cancels pollTask, invalidates the URLSession/SID, drops the client).
        let activeClient = client
        if let activeClient {
            // Best-effort server logout, but never let an unreachable NAS stall the
            // uninstall — cap the wait at ~3s, then proceed regardless (review LOW).
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await activeClient.logout() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        cancelLocalSessionForClose()

        // 2) Stop the toast task so it can't fire after teardown.
        toastTask?.cancel()
        toastTask = nil

        // 3) Drop the willTerminate observer so our own terminate() below does not
        //    re-enter the session teardown mid-uninstall.
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }

        // 4) Wipe data + Keychain + defaults, then trash the .app bundle — off the main
        //    actor so the Keychain delete loop + trashing don't freeze the UI (audit F49).
        //    (No DEBUG dump of the wiped paths/Keychain service names — audit F51.)
        _ = await Task.detached { SelfUninstall.wipeAll() }.value

        // 5) Hand off the cfprefsd-resistant plist purge to a detached helper that runs
        //    AFTER we exit (cfprefsd rewrites the plist on our termination otherwise).
        SelfUninstall.schedulePostExitPrefsPurge()

        // 6) Quit. The bundle is already in the Trash; no process lingers.
        NSApplication.shared.terminate(nil)
    }

    private var normalizedHost: String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://") { value.removeFirst("https://".count) }
        else if value.hasPrefix("http://") { value.removeFirst("http://".count) }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        // Bracketed IPv6 literal "[addr]" / "[addr]:port" -> keep the inner address.
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            return String(value[value.index(after: value.startIndex)..<close])
        }
        // Bare IPv6 literal ("::" or 2+ colons): keep verbatim so it is recognised and
        // rejected by validateLocalHost — never silently truncated into a bare label
        // that the LAN guard would trust (would otherwise leak credentials, audit).
        if value.contains("::") || value.filter({ $0 == ":" }).count >= 2 {
            return value
        }
        // IPv4 / hostname with an optional ":port" -> drop the port.
        if let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value
    }

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateLocalHost(_ value: String) throws {
        guard !value.isEmpty else {
            throw MonitorError.message("Enter the address of your Synology NAS.")
        }
        guard LANHost.isPrivate(value) else {
            throw MonitorError.message("This app works on the local network only. Enter a private NAS address (for example 192.168.x.x, 10.x.x.x) or a local name (for example synology.local).")
        }
    }

    @discardableResult
    private func advanceSession() -> Int {
        connectionGeneration += 1
        return connectionGeneration
    }

    private func isCurrent(_ candidate: SynologyClient, generation: Int) -> Bool {
        generation == connectionGeneration && client === candidate
    }

    private func persistSuccessfulConnection(host: String, username: String) -> String? {
        // If the account changed, delete the previous account's stored password AND its 2FA
        // device token so neither is orphaned in Keychain (audit #4; the device token is a
        // 2FA-bypass secret, so it must not linger for an account we no longer use).
        let prevHost = UserDefaults.standard.string(forKey: "host")
        let prevUser = UserDefaults.standard.string(forKey: "username")
        if let prevHost, let prevUser, (prevHost != host || prevUser != username) {
            KeychainService.delete(host: prevHost, username: prevUser)
            KeychainService.deleteDeviceToken(host: prevHost, username: prevUser)
        }
        // If the host itself changed, forget the old host's cert pin too so it isn't left
        // orphaned in Keychain (audit F28).
        if let prevHost, prevHost != host {
            KeychainService.deletePin(host: prevHost)
        }
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(username, forKey: "username")
        UserDefaults.standard.set(allowSelfSigned, forKey: "allowSelfSigned")
        UserDefaults.standard.set(protocolPreference.rawValue, forKey: "protocolPreference")
        UserDefaults.standard.set(httpsPort, forKey: "httpsPort")
        UserDefaults.standard.set(httpPort, forKey: "httpPort")
        do {
            try KeychainService.save(password: password, host: host, username: username)
            return nil
        } catch {
            return readable(error)
        }
    }

    private func replaceTasksAfterOperation(using client: SynologyClient, generation: Int) async throws {
        let updatedTasks = try await client.listTasks()
        guard isCurrent(client, generation: generation) else { return }
        tasks = updatedTasks
        connectionState = .connected
        // A successful authenticated round-trip proves the session is alive, so
        // clear the transient-failure streak (review LOW).
        consecutivePollFailures = 0
    }

    private func refreshTasks(using client: SynologyClient, generation: Int, userInitiated: Bool) async {
        do {
            let updatedTasks = try await client.listTasks()
            guard isCurrent(client, generation: generation) else { return }
            // A late background poll must not clobber a user operation's result (audit R1-03).
            if !userInitiated && isBusy { return }
            tasks = updatedTasks
            connectionState = .connected
            consecutivePollFailures = 0
            if userInitiated {
                message = "Updated \(Date().formatted(date: .omitted, time: .standard))."
            }
        } catch {
            guard !isCancellation(error), isCurrent(client, generation: generation) else { return }
            // Session-expiry / permission errors: drop the session immediately.
            if shouldInvalidateSession(for: error) {
                failActiveSession(error, client: client, generation: generation)
                return
            }
            // A transient network blip or decode hiccup must NOT kill a live session
            // (audit H5). Keep polling; give up only after several failures in a row.
            consecutivePollFailures += 1
            if consecutivePollFailures >= maxPollFailures {
                failActiveSession(error, client: client, generation: generation)
                return
            }
            connectionState = .connected
            if userInitiated {
                message = "Network was briefly unavailable — connection kept."
            }
        }
    }

    private func handleOperationError(_ error: Error, client: SynologyClient, generation: Int) {
        guard !isCancellation(error), generation == connectionGeneration else { return }
        if shouldInvalidateSession(for: error) {
            failActiveSession(error, client: client, generation: generation)
        } else {
            connectionState = .connected
            message = readable(error)
        }
    }

    private func failActiveSession(_ error: Error, client failedClient: SynologyClient, generation: Int) {
        guard !isCancellation(error), isCurrent(failedClient, generation: generation) else { return }
        advanceSession()   // bump the generation so any stale in-flight completion is ignored (F31)
        pollTask?.cancel()
        pollTask = nil
        sysInfoTask?.cancel()
        sysInfoTask = nil
        client = nil
        failedClient.invalidate()
        connectionState = .error
        message = readable(error)
    }

    private func shouldInvalidateSession(for error: Error) -> Bool {
        if let apiError = error as? APIError {
            // Only true session-expiry / permission codes force a fresh login.
            return [105, 106, 107, 119, 402].contains(apiError.code)
        }
        // Transient network errors and decode hiccups keep the session alive (audit H5).
        if isTransientNetworkError(error) { return false }
        if error is DecodingError { return false }
        return !isCancellation(error)
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Pause the 5s polling loop while the window is hidden, resume when it returns —
    /// stops wasting network/battery and keeping the SID busy in the background
    /// (audit #64). Does not touch the session, so resume is instant.
    func setPollingActive(_ active: Bool) {
        guard isConnected else { return }
        if active {
            if pollTask == nil { startPolling(generation: connectionGeneration) }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startPolling(generation: Int) {
        // NOTE: do NOT reset consecutivePollFailures here — startPolling also runs when the
        // window re-activates (setPollingActive), and zeroing would defeat the 3-strike
        // dead-session give-up. It is reset at genuine session start (connect) and on a
        // proven-successful round-trip (audit F32/R2-14).
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.poll(generation: generation)
            }
        }
    }

    private func poll(generation: Int) async {
        guard generation == connectionGeneration, !isBusy, let client else { return }
        await refreshTasks(using: client, generation: generation, userInitiated: false)
    }
}

/// LAN-only guard: the app must only ever send DSM credentials to a private/local
/// address, never a public host. Accepts private IPv4 ranges, loopback/link-local,
/// and local hostnames (.local/.lan/.home/.internal, or a bare name with no dots).
/// Rejects public IPs, public-looking FQDNs, and IPv6 literals (not supported — a
/// truncated IPv6 literal must never be mistaken for a trusted bare hostname).
enum LANHost {
    static func isPrivate(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return false }
        // Canonical dotted-quad (strict octets).
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        // Any OTHER form the C resolver would read as an IPv4 address — a bare decimal
        // integer ("134744072" == 8.8.8.8), hex ("0x8080808"), octal, or short
        // "a.b"/"a.b.c" forms — must be validated as an address too, never waved
        // through as a "bare hostname". This closes the dotless-integer bypass of the
        // LAN-only guard that could send the DSM password to a public host (audit F01).
        if let octets = inetAtonOctets(host) { return isPrivateIPv4(octets) }
        if host.contains(":") { return false }          // IPv6 literal — not supported, reject
        for suffix in [".local", ".lan", ".home", ".internal", ".localdomain", ".home.arpa"] {
            if host.hasSuffix(suffix) { return true }
        }
        // Bare single-label name (e.g. "synology"): allow only if it looks like a real
        // mDNS/LAN hostname — letters/digits/hyphen, at least one letter, no leading/
        // trailing hyphen — never a numeric/hex token the resolver could read as an IP.
        if !host.contains(".") {
            let charsOK = host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            let hasLetter = host.contains { $0.isLetter }
            return charsOK && hasLetter && !host.hasPrefix("-") && !host.hasSuffix("-")
        }
        return false
    }

    /// Stricter than `isPrivate`: true ONLY when `raw` is a numeric IP literal that points
    /// at an internal host — a private/loopback/link-local IPv4 (in any libc-readable form)
    /// or any IPv6 literal. A DNS hostname (including mDNS `.local`/`.lan` names such as the
    /// `retracker.local` found in nearly every CIS torrent) is NOT an IP literal and returns
    /// false here, even though `isPrivate` classifies those names as LAN. Gates the raw
    /// .torrent upload path: blocks only the real SSRF vector (a crafted tracker aimed at
    /// e.g. 192.168.x.x / 127.0.0.1) without forcing hostname-tracker torrents into the
    /// metadata-less magnet fallback (audit F24).
    static func isInternalIPLiteral(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return false }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        if let octets = inetAtonOctets(host) { return isPrivateIPv4(octets) }
        if host.contains(":") { return true }   // IPv6 literal — can't range-check, treat as internal
        return false                             // hostname — not an IP literal
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (127, _): return true                  // loopback
        case (169, 254): return true                // link-local
        case (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true           // CGNAT / Tailscale
        default: return false                       // public IPv4
        }
    }

    /// Parse any libc-acceptable IPv4 form (decimal/hex/octal integer, short
    /// a/a.b/a.b.c) the same way the network stack will, returning canonical octets.
    private static func inetAtonOctets(_ host: String) -> [Int]? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        let n = UInt32(bigEndian: addr.s_addr)
        return [Int((n >> 24) & 0xff), Int((n >> 16) & 0xff), Int((n >> 8) & 0xff), Int(n & 0xff)]
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard let n = Int(p), (0...255).contains(n), String(n) == String(p) else { return nil }
            octets.append(n)
        }
        return octets
    }
}

enum ProtocolPreference: String, Hashable {
    case auto
    case https
    case http
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case error
}

struct ConnectionSettings {
    let host: String
    let username: String
    // NOTE: the password is intentionally NOT stored here — it is passed straight into
    // SynologyClient.login() and discarded once the SID is obtained (audit R2-12).
    let protocolPreference: ProtocolPreference
    let allowSelfSigned: Bool
    var httpsPort: Int = 5001
    var httpPort: Int = 5000
}

final class SynologyClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let settings: ConnectionSettings
    /// 6-digit 2-step verification code, set only after the user answered an OTPRequired
    /// prompt. nil for the common (no-2FA) case, where login() never sends it.
    private let otpCode: String?
    private var session: URLSession!

    // sid/baseURL/apiInfo are read/written from the cooperative thread pool after
    // every `await`, so a lock removes the data race the audit flagged (H4). The
    // lock is never held across an `await`. (Full `actor` conversion was deferred
    // to the Phase-3 live-NAS test window — see project journal.)
    private let stateLock = NSLock()
    private var _baseURL: URL?
    private var _apiInfo: [String: APIDescriptor] = [:]
    private var _sid: String?
    private var _candidatePin: String?
    private var _password: String?   // held only until login() obtains the SID (audit R2-12)

    private var baseURL: URL? {
        get { stateLock.withLock { _baseURL } }
        set { stateLock.withLock { _baseURL = newValue } }
    }
    private var apiInfo: [String: APIDescriptor] {
        get { stateLock.withLock { _apiInfo } }
        set { stateLock.withLock { _apiInfo = newValue } }
    }
    private var sid: String? {
        get { stateLock.withLock { _sid } }
        set { stateLock.withLock { _sid = newValue } }
    }

    /// True when the live connection is plaintext HTTP (the user explicitly picked the
    /// "HTTP" option; Auto/HTTPS never use cleartext). Surfaced to warn the user (H2/F47).
    var isInsecure: Bool { baseURL?.scheme?.lowercased() == "http" }

    /// The SPKI pin learned this connection that still needs explicit user confirmation
    /// before the password is sent (nil once a stored pin matched). connect() checks this
    /// after the unauthenticated info() probe and stops before login() if set (audit F02).
    func pendingPinForConfirmation() -> String? {
        stateLock.withLock { _candidatePin }
    }

    private var httpsPort: Int { settings.httpsPort }
    private var httpPort: Int { settings.httpPort }

    init(settings: ConnectionSettings, password: String, otpCode: String? = nil) {
        self.settings = settings
        self.otpCode = otpCode
        super.init()
        stateLock.withLock { _password = password }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func connect() async throws {
        var lastError: Error?
        for base in try bases() {
            do {
                baseURL = base
                apiInfo = try await info(base)
                _ = try require("SYNO.DownloadStation.Task")
                // A brand-new cert was trusted only for this unauthenticated probe; stop
                // and have the user confirm its fingerprint BEFORE the password is sent.
                if let candidate = pendingPinForConfirmation() {
                    throw PinConfirmationRequired(pin: candidate, host: settings.host)
                }
                try await login()
                return
            } catch let pinReq as PinConfirmationRequired {
                throw pinReq
            } catch let otp as OTPRequired {
                throw otp
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MonitorError.message("Cannot connect to Synology.")
    }

    func listTasks() async throws -> [DownloadTask] {
        let taskAPI = try require("SYNO.DownloadStation.Task")
        let data: TaskListData = try await request(path: taskAPI.path, fields: [
            "api": "SYNO.DownloadStation.Task",
            "version": "\(taskAPI.maxVersion)",
            "method": "list",
            "additional": "detail,transfer"
        ], authenticated: true)
        return data.tasks
    }

    func create(uri: String, destination: String? = nil) async throws {
        let isMagnet = uri.lowercased().hasPrefix("magnet:?")
        if !isMagnet, let taskAPI = apiInfo["SYNO.DownloadStation2.Task"] {
            var fields = [
                "api": "SYNO.DownloadStation2.Task",
                "version": "\(min(taskAPI.maxVersion, 2))",
                "method": "create",
                "type": "url",
                "url": try jsonArrayString([uri]),
                "create_list": "false"
            ]
            if let destination, !destination.isEmpty { fields["destination"] = destination }
            let _: EmptyData = try await request(path: taskAPI.path, fields: fields, authenticated: true, allowEmptyData: true)
            return
        }

        let taskAPI = try require("SYNO.DownloadStation.Task")
        var fields = [
            "api": "SYNO.DownloadStation.Task",
            "version": "\(taskAPI.maxVersion)",
            "method": "create",
            "uri": uri
        ]
        // Without a destination DSM rejects the task with error 406 on accounts
        // that have no default Download Station location set (verified live).
        if let destination, !destination.isEmpty { fields["destination"] = destination }
        let _: EmptyData = try await request(path: taskAPI.path, fields: fields, authenticated: true, allowEmptyData: true)
    }

    /// Returns true if it fell back to a metadata-less magnet (so the caller can tell the
    /// user the real-file upload didn't take — audit F38).
    @discardableResult
    func createTorrent(fileURL: URL, destination: String? = nil) async throws -> Bool {
        // A real .torrent is tiny; refuse an absurdly large file before reading it all into
        // memory (audit F48/R1-10).
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8_000_000 {
            throw MonitorError.message("This .torrent file is too large.")
        }
        let torrentData = try Data(contentsOf: fileURL)
        // Preferred path: upload the real .torrent file and let DSM parse it — same flow the
        // DSM web UI uses (FileStation.Upload → DownloadStation2 create_list → Task.List
        // download). Keeps the real name/metadata and actually starts the download.
        let canUploadFile = apiInfo["SYNO.FileStation.Upload"] != nil
            && apiInfo["SYNO.DownloadStation2.Task"] != nil
            && apiInfo["SYNO.DownloadStation2.Task.List"] != nil
        // Keep a raw .torrent off the upload path ONLY if it aims a tracker at an internal
        // IP *literal* (192.168.x / 127.x / IPv6) — the real SSRF vector. We deliberately do
        // NOT block hostname trackers here: the `.local` retracker present in nearly every
        // CIS torrent was previously flagged "unsafe", forcing every such file down the
        // metadata-less magnet fallback (the F24 `viaMagnetFallback=true` regression). The
        // magnet fallback still strips ALL LAN trackers, so a genuinely risky file stays
        // sanitized (audit F12 intent preserved).
        // RESIDUAL RISK (accepted, documented): a hostname tracker we let through could still
        // resolve — on the NAS's OWN resolver, later — to an internal IP (DNS-rebinding-style
        // SSRF). We deliberately do NOT resolve trackers here: resolution happens on the NAS
        // after we hand it the file, so an add-time lookup is both TOCTOU-racy and
        // resolver-mismatched (it can't actually close the gap). This risk also pre-dates
        // this change — the old gate passed any public-looking hostname too. For a home LAN
        // app where the user adds their own .torrents, this is a known residual risk, not a
        // blocker (Codex review nuance).
        // Fail SAFE on a parse failure: if our bencode parser can't read the .torrent (but
        // DSM might), do NOT hand DSM the raw file — a tracker we never got to inspect could
        // aim the NAS at an internal host. `?? true` routes such a file to the magnet path,
        // which re-parses and fails closed, instead of an unchecked raw upload (Codex audit
        // H2). Valid torrents parse fine, so this never affects the F24 fix.
        let hasInternalIPTracker = (try? TorrentMagnetBuilder.hasInternalIPLiteralTracker(in: torrentData)) ?? true
        if canUploadFile, !hasInternalIPTracker, let dest = destination, !dest.isEmpty {
            let folderPath = dest.hasPrefix("/") ? dest : "/" + dest
            // Random, non-revealing temp name — never embed the user's local filename, which
            // anyone with NAS share access could otherwise read (audit R2-09).
            let uploadedPath = folderPath + "/.sdsm-upload-\(UUID().uuidString).torrent"
            let tempName = (uploadedPath as NSString).lastPathComponent

            // Phase 1 (recoverable): upload the file + register a parse list. A failure here
            // means NOTHING was created on the NAS yet, so falling back to a magnet is safe.
            var listID: String?
            do {
                try await fileStationUpload(folderPath: folderPath, fileName: tempName, data: torrentData)
                listID = try await ds2CreateLocalList(localPath: uploadedPath, destination: dest)
            } catch {
                // Log WHY the file path failed — otherwise the silent magnet fallback hides
                // the real DSM error (it surfaced live only as an unexplained magnet fallback).
                await shieldedDelete(uploadedPath)
                listID = nil
            }

            // Phase 2 (committed): once a list exists, commit it. If the commit fails we must
            // NOT fall back to a magnet — the task may already exist and a retry would
            // double-add. Surface the real error. Cleanup is cancellation-shielded so a torn-
            // down session can't orphan the temp .torrent (audit F18).
            if let listID {
                do {
                    try await ds2ListDownload(listID: listID, destination: dest)
                    await shieldedDelete(uploadedPath)
                    return false
                } catch {
                    await shieldedDelete(uploadedPath)
                    throw error
                }
            }
        }
        // Fallback: derive a magnet from the .torrent (works without FileStation, but DSM
        // must fetch metadata from peers before it can start).
        let magnet = try TorrentMagnetBuilder.magnet(from: torrentData)
        try await create(uri: magnet, destination: destination)
        return true
    }

    /// Delete a NAS path even if the calling task was cancelled — an unstructured Task is not
    /// cancelled together with its parent, so a cancel can't orphan the temp .torrent (F18).
    private func shieldedDelete(_ path: String) async {
        await Task { try? await self.fileStationDelete(path: path) }.value
    }

    private func ds2CreateLocalList(localPath: String, destination: String) async throws -> String {
        let api = try require("SYNO.DownloadStation2.Task")
        struct ListResult: Decodable { let listID: [String]; enum CodingKeys: String, CodingKey { case listID = "list_id" } }
        let result: ListResult = try await request(path: api.path, fields: [
            "api": "SYNO.DownloadStation2.Task",
            "version": "\(min(api.maxVersion, 2))",
            "method": "create",
            "type": "local",
            "destination": destination,
            "create_list": "true",
            "local_path": localPath
        ], authenticated: true)
        guard let id = result.listID.first, !id.isEmpty else {
            throw MonitorError.message("Synology did not return a torrent list to download.")
        }
        return id
    }

    private func ds2ListDownload(listID: String, destination: String) async throws {
        let api = try require("SYNO.DownloadStation2.Task.List")
        let _: EmptyData = try await request(path: api.path, fields: [
            "api": "SYNO.DownloadStation2.Task.List",
            "version": "\(min(api.maxVersion, 2))",
            "method": "download",
            "list_id": listID,
            "destination": destination
        ], authenticated: true, allowEmptyData: true)
    }

    private func fileStationUpload(folderPath: String, fileName: String, data: Data) async throws {
        guard let baseURL, let sid else { throw MonitorError.message("Not connected.") }
        let api = try require("SYNO.FileStation.Upload")
        // FileStation.Upload reads the API selector AND the _sid from the query string;
        // the multipart body must carry only the form fields + file (verified live). The
        // Phase-3 F24 change moved _sid into the body to keep it out of the URL — but DSM
        // then rejects the upload, silently falling back to a metadata-less magnet (seen
        // live: `viaMagnetFallback=true`). On a LAN session to the user's own NAS the
        // ephemeral SID in the URL is a negligible risk (never logged, never persisted),
        // so correctness wins: _sid goes back in the query.
        let url = try makeURL(base: baseURL, path: api.path, query: [
            "api": "SYNO.FileStation.Upload",
            "version": "\(min(api.maxVersion, 2))",
            "method": "upload",
            "_sid": sid
        ])
        try await multipartPOST(url: url, parts: [
            .field(name: "path", value: folderPath),
            .field(name: "create_parents", value: "true"),
            .field(name: "overwrite", value: "true"),
            .file(name: "file", filename: fileName, contentType: "application/octet-stream", data: data)
        ])
    }

    func fileStationDelete(path: String) async throws {
        let api = try require("SYNO.FileStation.Delete")
        let _: EmptyData = try await request(path: api.path, fields: [
            "api": "SYNO.FileStation.Delete",
            "version": "\(min(api.maxVersion, 2))",
            "method": "delete",
            "path": try jsonArrayString([path])
        ], authenticated: true, allowEmptyData: true)
    }

    /// The connecting account's Download Station default download folder, or nil if
    /// none is configured. A null default is why a fresh (non-primary) user's tasks
    /// sit forever in "waiting" without ever starting (verified live; documented
    /// Synology behaviour).
    /// Returns the configured default download folder, or nil if the account
    /// genuinely has none. THROWS on a read failure so the caller can tell "no
    /// default" apart from "couldn't read" and never overwrites an existing setting.
    func downloadDefaultDestination() async throws -> String? {
        let api = try require("SYNO.DownloadStation.Info")
        struct Config: Decodable { let defaultDestination: String?; enum CodingKeys: String, CodingKey { case defaultDestination = "default_destination" } }
        let cfg: Config = try await request(path: api.path, fields: [
            "api": "SYNO.DownloadStation.Info",
            "version": "\(api.maxVersion)",
            "method": "getconfig"
        ], authenticated: true)
        let dest = cfg.defaultDestination?.trimmingCharacters(in: .whitespaces)
        return (dest?.isEmpty == false) ? dest : nil
    }

    /// Sets the connecting account's default download folder. This is what unblocks
    /// downloads for accounts that have never opened Download Station before.
    func setDefaultDestination(_ destination: String) async throws {
        let api = try require("SYNO.DownloadStation.Info")
        let _: EmptyData = try await request(path: api.path, fields: [
            "api": "SYNO.DownloadStation.Info",
            "version": "\(api.maxVersion)",
            "method": "setserverconfig",
            "default_destination": destination
        ], authenticated: true, allowEmptyData: true)
    }

    /// Best-effort sensible default destination when the account has no tasks to copy
    /// one from: prefer a share that looks download-related, else the first share.
    /// Returned share-relative (no leading slash), e.g. "Downloads".
    func suggestedDestination() async -> String? {
        guard let api = apiInfo["SYNO.FileStation.List"] else { return nil }
        struct Shares: Decodable { let shares: [Share]; struct Share: Decodable { let path: String } }
        let data: Shares? = try? await request(path: api.path, fields: [
            "api": "SYNO.FileStation.List",
            "version": "\(min(api.maxVersion, 2))",
            "method": "list_share"
        ], authenticated: true)
        let names = (data?.shares ?? [])
            .map { $0.path.hasPrefix("/") ? String($0.path.dropFirst()) : $0.path }
            .filter { !$0.isEmpty }
        if let dl = names.first(where: { let n = $0.lowercased(); return n.contains("download") || n.contains("torrent") }) {
            return dl
        }
        // Otherwise the first non-system share. Never auto-pick a system/special share
        // as the global Download Station default; return nil rather than a bad guess.
        let systemish = ["timemachine", "time machine", "backup", "surveillance", "homes", "web", "usbshare", "satashare", "docker", "system"]
        return names.first { name in
            let n = name.lowercased()
            return !systemish.contains { n.contains($0) }
        }
    }

    private enum MultipartPart {
        case field(name: String, value: String)
        case file(name: String, filename: String, contentType: String, data: Data)
    }

    private func multipartPOST(url: URL, parts: [MultipartPart]) async throws {
        let boundary = "----sdsm-\(UUID().uuidString)"
        var body = Data()
        for part in parts {
            body.appendString("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.appendString(value)
                body.appendString("\r\n")
            case .file(let name, let filename, let contentType, let fileData):
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                body.appendString("Content-Type: \(contentType)\r\n\r\n")
                body.append(fileData)
                body.appendString("\r\n")
            }
        }
        body.appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await cappedData(for: request)   // also enforces HTTP status (audit F09)
        let envelope = try JSONDecoder().decode(SuccessEnvelope.self, from: data)
        guard envelope.success else { throw APIError(code: envelope.error?.code ?? 100) }
    }

    func taskAction(method: String, id: String) async throws {
        let taskAPI = try require("SYNO.DownloadStation.Task")
        // DSM returns success:true even when individual ids fail; decode the per-id error
        // array and surface any failure instead of silently reporting success (audit F06).
        let results: TaskActionResults = try await request(path: taskAPI.path, fields: [
            "api": "SYNO.DownloadStation.Task",
            "version": "\(taskAPI.maxVersion)",
            "method": method,
            "id": id
        ], authenticated: true, allowEmptyData: true)
        let failed = results.items.filter { ($0.error ?? 0) != 0 }
        guard failed.isEmpty else {
            let codes = Set(failed.compactMap(\.error)).sorted().map(String.init).joined(separator: ", ")
            throw MonitorError.message("Synology rejected \(failed.count) task(s). Code: \(codes).")
        }
    }

    /// Best-effort read-only system info (DSM version, uptime, primary volume usage).
    /// Each part degrades to nil independently so a missing/forbidden endpoint never fails the session.
    func systemInfo() async -> SystemInfo {
        var info = SystemInfo()

        // DSM version + uptime — readable by normal (non-admin) DSM users.
        if let dsm = try? require("SYNO.DSM.Info"),
           let data: DSMInfoData = try? await request(path: dsm.path, fields: [
               "api": "SYNO.DSM.Info",
               "version": "\(dsm.maxVersion)",
               "method": "getinfo"
           ], authenticated: true) {
            info.dsmVersion = data.versionString
            info.uptimeSeconds = data.uptime
        }

        // Storage volume — may require admin; hidden automatically if unavailable.
        if let storage = try? require("SYNO.Storage.CGI.Storage"),
           let data: StorageData = try? await request(path: storage.path, fields: [
               "api": "SYNO.Storage.CGI.Storage",
               "version": "\(storage.maxVersion)",
               "method": "load_info"
           ], authenticated: true) {
            info.volume = data.firstVolume
        }

        return info
    }

    private func info(_ base: URL) async throws -> [String: APIDescriptor] {
        // Decode tolerantly: one malformed/unexpected descriptor entry must not throw
        // away the whole API map and break the connection (audit #70).
        let raw: [String: FailableAPIDescriptor] = try await get(base: base, path: "query.cgi", fields: [
            "api": "SYNO.API.Info",
            "version": "1",
            "method": "query",
            "query": "SYNO.API.Auth,SYNO.DownloadStation.Info,SYNO.DownloadStation.Task,SYNO.DownloadStation2.Task,SYNO.DownloadStation2.Task.List,SYNO.DSM.Info,SYNO.Storage.CGI.Storage,SYNO.FileStation.Upload,SYNO.FileStation.List,SYNO.FileStation.Delete"
        ])
        return raw.compactMapValues(\.value)
    }

    private func login() async throws {
        let authAPI = try require("SYNO.API.Auth")
        let password = stateLock.withLock { _password } ?? ""
        var fields = [
            "api": "SYNO.API.Auth",
            "version": "\(authAPI.maxVersion)",
            "method": "login",
            "account": settings.username,
            "passwd": password,
            "session": "DownloadStation",
            "format": "sid"
        ]
        // 2-step verification (2FA): the OTP code is attached only right after the user
        // answered an OTPRequired prompt. A previously remembered device sends a stored
        // device token instead, which makes DSM skip the prompt. Accounts without 2FA send
        // NEITHER — this base login is byte-for-byte the path verified live.
        let savedDeviceToken = KeychainService.loadDeviceToken(host: settings.host, username: settings.username)
        if let otpCode, !otpCode.isEmpty {
            fields["otp_code"] = otpCode
            fields["enable_device_token"] = "yes"          // remember this Mac so 2FA isn't asked next time
            fields["device_name"] = "Synology Download Station Monitor"
        } else if let savedDeviceToken, !savedDeviceToken.isEmpty {
            fields["device_id"] = savedDeviceToken          // remembered device → DSM skips the OTP
        }
        let data: AuthData
        do {
            data = try await request(path: authAPI.path, fields: fields, authenticated: false)
        } catch let api as APIError where api.code == 403 || api.code == 404 {
            // SYNO.API.Auth: 403 = a 2-step verification code is required; 404 = the code we
            // sent was wrong. Intercepted here, before the generic error mapper, so these auth
            // codes are never confused with same-numbered codes from other APIs (e.g.
            // DownloadStation's own 406). A stored device token DSM no longer honors also comes
            // back as 403 — drop it so we stop resending a dead token, then re-prompt for OTP.
            if otpCode == nil {
                KeychainService.deleteDeviceToken(host: settings.host, username: settings.username)
            }
            throw OTPRequired(codeWasWrong: api.code == 404)
        }
        sid = data.sid
        // Persist the device token so a future 2FA connect skips the code. It is a 2FA bypass
        // secret → ThisDeviceOnly, and wiped by "Forget login details" / Uninstall.
        if let did = data.did, !did.isEmpty {
            _ = KeychainService.saveDeviceToken(did, host: settings.host, username: settings.username)
        }
        stateLock.withLock { _password = nil }   // discard the plaintext once we have the SID (audit R2-12)
    }

    func logout() async throws {
        defer { sid = nil }
        guard let baseURL, let sid else { return }
        let authAPI = try require("SYNO.API.Auth")
        let _: EmptyData = try await post(base: baseURL, path: authAPI.path, fields: [
            "api": "SYNO.API.Auth",
            "version": "\(authAPI.maxVersion)",
            "method": "logout",
            "session": "DownloadStation",
            "_sid": sid
        ], allowEmptyData: true)
    }

    func invalidate() {
        sid = nil
        stateLock.withLock { _password = nil }
        session?.invalidateAndCancel()
    }

    private func request<T: Decodable>(path: String, fields: [String: String], authenticated: Bool, allowEmptyData: Bool = false) async throws -> T {
        guard let baseURL else { throw MonitorError.message("Not connected.") }
        var values = fields
        if authenticated {
            guard let sid else { throw MonitorError.message("Missing Synology session.") }
            values["_sid"] = sid
        }
        return try await post(base: baseURL, path: path, fields: values, allowEmptyData: allowEmptyData)
    }

    /// 16 MB ceiling — a DSM API/JSON response is tiny; a multi-GB body is a hostile NAS
    /// trying to exhaust memory, so we stream and abort past the cap (audit R2-04).
    private static let maxResponseBytes = 16 * 1024 * 1024

    /// Stream the response with a hard size cap and an up-front HTTP-status check, so the
    /// app can't be OOM-crashed by an unbounded body (R2-04) and every path validates the
    /// status (audit F09).
    private func cappedData(for request: URLRequest) async throws -> Data {
        // `bytes(for:)` WITHOUT a per-task delegate silently SKIPS the session's
        // server-trust delegate (urlSession(_:didReceive:)), so the system applied default
        // handling and rejected every self-signed DSM cert as "certificate invalid" — the
        // app could only connect over plaintext HTTP. Reproduced live; `data(for:)` does
        // call the delegate, `bytes(for:delegate:)` restores it. Passing `delegate: self`
        // keeps the 16 MB streaming cap (R2-04) AND the TLS pinning challenge handler.
        let (stream, response) = try await session.bytes(for: request, delegate: self)
        try checkHTTPStatus(response)
        if response.expectedContentLength > Self.maxResponseBytes {
            stream.task.cancel()
            throw MonitorError.message("Synology returned an unexpectedly large response.")
        }
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count > Self.maxResponseBytes {
                stream.task.cancel()
                throw MonitorError.message("Synology returned an unexpectedly large response.")
            }
        }
        return data
    }

    private func get<T: Decodable>(base: URL, path: String, fields: [String: String]) async throws -> T {
        let url = try makeURL(base: base, path: path, query: fields)
        let data = try await cappedData(for: URLRequest(url: url))
        return try decodeEnvelope(data)
    }

    private func post<T: Decodable>(base: URL, path: String, fields: [String: String], allowEmptyData: Bool = false) async throws -> T {
        let url = try makeURL(base: base, path: path, query: [:])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let data = try await cappedData(for: request)
        return try decodeEnvelope(data, allowEmptyData: allowEmptyData)
    }

    /// Reject non-2xx responses up front so a proxy/login/HTML error page surfaces as
    /// a clear "HTTP <code>" message instead of an opaque JSON DecodingError.
    private func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(code: http.statusCode)
        }
    }

    private func decodeEnvelope<T: Decodable>(_ data: Data, allowEmptyData: Bool = false) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if envelope.success {
            if let data = envelope.data { return data }
            if allowEmptyData, let t = (T.self as? EmptyInitable.Type)?.init() as? T { return t }
            throw MonitorError.message("Synology returned no data.")
        }
        throw APIError(code: envelope.error?.code ?? 100)
    }

    private func require(_ name: String) throws -> APIDescriptor {
        guard let value = apiInfo[name] else {
            throw MonitorError.message("\(name) not available. Check that Download Station is installed.")
        }
        return value
    }

    private func bases() throws -> [URL] {
        guard LANHost.isPrivate(settings.host) else {
            throw MonitorError.message("This app is LAN-only and refuses to connect to a non-private host.")
        }

        switch settings.protocolPreference {
        case .auto:
            // Auto = HTTPS only. We deliberately never fall back to plaintext HTTP —
            // not even on the first connect — because a LAN attacker who blocks the
            // HTTPS handshake could otherwise harvest the DSM password in cleartext
            // (audit H1 / #95). A NAS with no HTTPS requires the user to pick the
            // "HTTP 5000" option explicitly, which warns that the password is sent
            // unencrypted.
            return [try makeBaseURL(scheme: "https", port: httpsPort)]
        case .https:
            return [try makeBaseURL(scheme: "https", port: httpsPort)]
        case .http:
            return [try makeBaseURL(scheme: "http", port: httpPort)]
        }
    }

    private func makeBaseURL(scheme: String, port: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = settings.host
        components.port = port
        guard let url = components.url else {
            throw MonitorError.message("Bad Synology host.")
        }
        return url
    }

    private func makeURL(base: URL, path: String, query: [String: String]) throws -> URL {
        var cleanPath = path
        if cleanPath.hasPrefix("/") { cleanPath.removeFirst() }
        if cleanPath.hasPrefix("webapi/") { cleanPath.removeFirst("webapi/".count) }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw MonitorError.message("Bad URL.")   // no force-unwrap (audit F39)
        }
        components.path = "/webapi/\(cleanPath)"
        if !query.isEmpty {
            // Encode '+' ourselves; queryItems leaves it intact and the server reads it
            // back as a space, corrupting a SID/value (audit R1-01).
            components.percentEncodedQuery = query
                .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw MonitorError.message("Bad URL.") }
        return url
    }

    /// Percent-encode to the unreserved set. URLComponents leaves "+" intact, which a
    /// server decodes back to a space — silently corrupting passwords/URIs/magnets/SIDs
    /// that contain "+" (audit H7/R1-01). Shared by formBody and makeURL.
    static func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let body = fields.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func jsonArrayString(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MonitorError.message("Cannot encode Synology request.")
        }
        return string
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Hard scope: only ever pin/trust the exact LAN host we are connecting to.
        guard LANHost.isPrivate(settings.host), challenge.protectionSpace.host == settings.host else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // When self-signed is OFF, require the system chain to validate first.
        if !settings.allowSelfSigned {
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }
        // SPKI pinning (audit H1/F02/R1-02/R2-03). On a host we already trust, require an
        // exact key match and HARD-CANCEL anything else (changed cert / MITM). On a brand-
        // new (or legacy-format) pin we trust THIS connection only so the unauthenticated
        // info() probe can run, stash the candidate, and let connect() stop BEFORE login()
        // to ask the user to confirm the fingerprint — the password is never sent first.
        guard let pin = CertPinning.spkiPin(from: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let current = "spki:" + pin
        if let stored = KeychainService.loadPin(host: settings.host), stored.hasPrefix("spki:") {
            if pinsEqual(stored, current) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)   // changed cert / MITM → block
            }
            return
        }
        // First trust (or one-time migration from the old DER-pin format): do NOT persist
        // yet — connect() requires explicit user confirmation before login() (audit F02).
        stateLock.withLock { _candidatePin = current }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Never silently follow HTTP redirects to another host/scheme (audit H3) —
    /// that would carry the password/SID off the LAN.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIError?
}

struct APIError: Error, Decodable {
    let code: Int
}

/// A non-2xx HTTP response, carrying the status code so the session layer can tell a
/// transient 5xx/429/408 apart from an auth failure (audit F05).
struct HTTPStatusError: Error {
    let code: Int
}

/// Thrown by SynologyClient.connect when a never-before-seen TLS cert was trusted only
/// for the unauthenticated probe; the UI must confirm the fingerprint before the password
/// is sent (audit F02/R1-02). `pin` is the "spki:<hash>" value to persist on confirm.
struct PinConfirmationRequired: Error {
    let pin: String
    let host: String
}

/// Thrown by login() when the DSM account has 2-step verification (2FA/MFA) enabled: the
/// API rejects a password-only login with code 403 (a one-time code is required) or 404
/// (the code we sent was wrong). The UI prompts for the 6-digit code and reconnects.
/// Accounts WITHOUT 2FA never reach this path — their login simply succeeds.
struct OTPRequired: Error {
    let codeWasWrong: Bool
}

/// Minimal envelope for endpoints (e.g. multipart FileStation.Upload) where we only
/// need to know success/failure and ignore any returned data payload.
struct SuccessEnvelope: Decodable {
    let success: Bool
    let error: APIError?
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

struct APIDescriptor: Decodable {
    let path: String
    let maxVersion: Int

    enum CodingKeys: String, CodingKey { case path, maxVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)            // path is essential
        maxVersion = (try? c.decode(Int.self, forKey: .maxVersion)) ?? 1   // minVersion was unused (audit F53)
    }
}

/// Wrapper so one unparseable API descriptor is skipped instead of failing the
/// whole API.Info decode (audit #70).
struct FailableAPIDescriptor: Decodable {
    let value: APIDescriptor?
    init(from decoder: Decoder) throws { value = try? APIDescriptor(from: decoder) }
}

struct AuthData: Decodable {
    let sid: String
    /// Device token issued when we pass enable_device_token=yes during a 2FA login. Sent
    /// back as device_id on later logins to skip the OTP prompt. DSM versions name it
    /// either "did" or "device_id", so accept both. nil for non-2FA logins.
    let did: String?

    enum CodingKeys: String, CodingKey { case sid, did, deviceId = "device_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid = try c.decode(String.self, forKey: .sid)
        did = (try? c.decode(String.self, forKey: .did)) ?? (try? c.decode(String.self, forKey: .deviceId))
    }
}

struct TaskListData: Decodable {
    let tasks: [DownloadTask]

    enum CodingKeys: String, CodingKey { case tasks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode tolerantly: one malformed task (missing id, new shape from a
        // different DSM version) must not throw away the whole list or kill the
        // session during background polling (audit H6).
        let failable = (try? container.decode([FailableTask].self, forKey: .tasks)) ?? []
        tasks = failable.compactMap(\.task)
    }
}

/// Wrapper that swallows a single bad task instead of failing the entire array.
struct FailableTask: Decodable {
    let task: DownloadTask?
    init(from decoder: Decoder) throws {
        task = try? DownloadTask(from: decoder)
    }
}

protocol EmptyInitable { init() }

struct EmptyData: Decodable, EmptyInitable {
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Per-id results from a Task pause/resume/delete batch. DSM reports success:true even when
/// individual ids fail, so we decode the array and surface any non-zero error (audit F06).
struct TaskActionResults: Decodable, EmptyInitable {
    struct Item: Decodable { let id: String?; let error: Int? }
    let items: [Item]
    init() { items = [] }
    init(from decoder: Decoder) throws { items = (try? [Item](from: decoder)) ?? [] }
}

struct DownloadTask: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let size: Int64
    let status: String
    let additional: Additional?

    var speedDownload: Int64 { additional?.transfer?.speedDownload ?? 0 }
    var speedUpload: Int64 { additional?.transfer?.speedUpload ?? 0 }
    var downloaded: Int64 { additional?.transfer?.sizeDownloaded ?? 0 }
    var uploaded: Int64 { additional?.transfer?.sizeUploaded ?? 0 }
    var progress: Double {
        // Treat all terminal "done" states as 100%, not just "finished" (audit #38).
        if status == "finished" || status == "seeding" { return 1 }
        guard size > 0 else { return 0 }
        return min(max(Double(downloaded) / Double(size), 0), 1)
    }
    var timeLeft: TimeInterval? {
        guard size > downloaded, speedDownload > 0 else { return nil }
        return TimeInterval(size - downloaded) / TimeInterval(speedDownload)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, size, status, additional
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate `id` arriving as a JSON number instead of a string (audit H6).
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int64.self, forKey: .id) {
            id = String(intID)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container,
                debugDescription: "Task id is missing or not a string/number.")
        }
        title = (try? container.decode(String.self, forKey: .title)) ?? id
        size = container.lossyInt64(.size)
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        additional = try? container.decode(Additional.self, forKey: .additional)
    }
}

struct Additional: Decodable, Hashable {
    let transfer: Transfer?
    let detail: Detail?
}

struct Detail: Decodable, Hashable {
    let destination: String?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case destination, uri
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try? container.decode(String.self, forKey: .destination)
        uri = try? container.decode(String.self, forKey: .uri)
    }
}

struct Transfer: Decodable, Hashable {
    let sizeDownloaded: Int64
    let sizeUploaded: Int64
    let speedDownload: Int64
    let speedUpload: Int64

    enum CodingKeys: String, CodingKey {
        case sizeDownloaded = "size_downloaded"
        case sizeUploaded = "size_uploaded"
        case speedDownload = "speed_download"
        case speedUpload = "speed_upload"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sizeDownloaded = container.lossyInt64(.sizeDownloaded)
        sizeUploaded = container.lossyInt64(.sizeUploaded)
        speedDownload = container.lossyInt64(.speedDownload)
        speedUpload = container.lossyInt64(.speedUpload)
    }
}

struct DSMInfoData: Decodable {
    let versionString: String?
    let uptime: Int64

    enum CodingKeys: String, CodingKey {
        case versionString = "version_string"
        case uptime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versionString = try? container.decode(String.self, forKey: .versionString)
        uptime = container.lossyInt64(.uptime)
    }
}

struct StorageData: Decodable {
    let volumes: [StorageVolume]

    var firstVolume: DiskVolume? {
        guard let volume = volumes.first(where: { $0.totalBytes > 0 }) ?? volumes.first else { return nil }
        return DiskVolume(name: volume.displayName, totalBytes: volume.totalBytes, usedBytes: volume.usedBytes)
    }

    enum CodingKeys: String, CodingKey {
        case volumes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volumes = (try? container.decode([StorageVolume].self, forKey: .volumes)) ?? []
    }
}

struct StorageVolume: Decodable {
    let id: String?
    let totalBytes: Int64
    let usedBytes: Int64

    var displayName: String {
        if let id, let suffix = id.split(separator: "_").last, Int(suffix) != nil {
            return "Volume \(suffix)"
        }
        return id ?? "Volume"
    }

    enum CodingKeys: String, CodingKey {
        case id, size
    }

    enum SizeKeys: String, CodingKey {
        case total, used
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        if let size = try? container.nestedContainer(keyedBy: SizeKeys.self, forKey: .size) {
            totalBytes = size.lossyInt64(.total)
            usedBytes = size.lossyInt64(.used)
        } else {
            totalBytes = 0
            usedBytes = 0
        }
    }
}

enum TorrentMagnetBuilder {
    static func magnet(from data: Data) throws -> String {
        // A real .torrent is tiny; refuse an absurdly large file before scanning it (F48).
        guard data.count <= 8_000_000 else {
            throw MonitorError.message("This .torrent file is too large.")
        }
        var parser = BencodeParser(data: data)
        let torrent = try parser.parseTorrent()
        let hash = Insecure.SHA1.hash(data: torrent.infoData)
            .map { String(format: "%02x", $0) }
            .joined()

        var items = ["xt=urn:btih:\(hash)"]
        if let name = torrent.name, !name.isEmpty {
            items.append("dn=\(Self.encodeDisplayNameForDSM(name))")
        }
        // Only forward public http/https/udp trackers. Dropping trackers aimed at
        // private/loopback hosts stops a crafted .torrent from making the NAS beacon
        // to internal addresses (SSRF, audit #71).
        for tracker in torrent.trackers where Self.isSafeTracker(tracker) {
            items.append("tr=\(Self.encodeMagnetValue(tracker))")
        }

        return "magnet:?\(items.joined(separator: "&"))"
    }

    private static func isSafeTracker(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme),
              let host = comps.host, !host.isEmpty else { return false }
        // Reject IPv6-literal trackers outright (can't range-check them; they could aim at
        // internal ::1/fc00::/fe80:: hosts) plus any private/loopback host (anti-SSRF, F12).
        let bare = host.hasPrefix("[") ? String(host.dropFirst().prefix { $0 != "]" }) : host
        if bare.contains(":") { return false }
        return !LANHost.isPrivate(bare)   // drop internal/loopback tracker hosts
    }

    /// True if the .torrent aims a tracker at an internal IP *literal* (private/loopback/
    /// link-local IPv4, or any IPv6) — the genuine SSRF vector we keep off the raw-upload
    /// path (a crafted file would otherwise make the NAS beacon to internal addresses).
    /// Hostname trackers — crucially the ubiquitous `retracker.local` — are deliberately
    /// NOT flagged, so legitimate CIS torrents still take the file-upload path that keeps
    /// the real name/file list and reliably starts the download. The magnet fallback still
    /// strips ALL LAN trackers as defence-in-depth (audit F12 intent kept; fixes the F24
    /// regression where `.local` trackers forced every such torrent into a magnet).
    static func hasInternalIPLiteralTracker(in data: Data) throws -> Bool {
        var parser = BencodeParser(data: data)
        let torrent = try parser.parseTorrent()
        return torrent.trackers.contains { url in
            guard let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty else { return false }
            let bare = host.hasPrefix("[") ? String(host.dropFirst().prefix { $0 != "]" }) : host
            return LANHost.isInternalIPLiteral(bare)
        }
    }

    private static func encodeDisplayNameForDSM(_ value: String) -> String {
        // Percent-encode to a strict allow-list (readable alphanumerics/space/safe punct)
        // so magnet delimiters AND "+" — which a server decodes back to a space — and any
        // control bytes are escaped, instead of denylisting just four chars (audit F41).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " -._~()[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodeMagnetValue(_ value: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "v", value: value)]
        guard let query = components.percentEncodedQuery,
              query.hasPrefix("v=") else { return value }
        return String(query.dropFirst(2))
    }
}

private struct ParsedTorrent {
    let infoData: Data
    let name: String?
    let trackers: [String]
}

private enum BencodeValue {
    case int(Int64)
    case bytes(Data)
    case list([BencodeValue])
    case dict([String: BencodeValue])
}

private struct BencodeParser {
    /// Real .torrent files nest far less than this; the cap stops a crafted
    /// `llll…`/`dddd…` chain from exhausting the thread stack (SIGSEGV).
    private static let maxDepth = 100

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parseTorrent() throws -> ParsedTorrent {
        guard readByte() == 100 else {
            throw MonitorError.message("This is not a valid .torrent file.")
        }

        var infoData: Data?
        var name: String?
        var trackers: [String] = []

        while peekByte() != 101 {
            let keyData = try parseByteString()
            let key = String(data: keyData, encoding: .utf8) ?? ""

            if key == "info" {
                let start = index
                let value = try parseValue()
                let end = index
                // 'info' MUST be a dictionary; otherwise the SHA-1 info-hash would be
                // computed over a non-dict and produce a bogus magnet (audit F30).
                guard case .dict(let dict) = value else {
                    throw MonitorError.message("Torrent file 'info' is not a dictionary.")
                }
                infoData = Data(bytes[start..<end])
                // Reject only PURE v2 (no v1 fields). Hybrid v1+v2 torrents carry v1
                // `pieces`/`piece length`, so the SHA-1 of the info dict is a valid,
                // working v1 info-hash — accept those (audit #19).
                let hasV1Fields = dict["pieces"] != nil && dict["piece length"] != nil
                if case .int(let metaVersion)? = dict["meta version"], metaVersion >= 2, !hasV1Fields {
                    throw MonitorError.message("Pure BitTorrent v2 torrent files are not supported yet. Use a magnet link or add the file in Synology DSM.")
                }
                if case .bytes(let nameData)? = dict["name"] {
                    name = String(data: nameData, encoding: .utf8)
                }
            } else if key == "announce" {
                let value = try parseValue()
                trackers.append(contentsOf: trackerStrings(from: value))
            } else if key == "announce-list" {
                let value = try parseValue()
                trackers.append(contentsOf: trackerStrings(from: value))
            } else {
                _ = try parseValue()
            }
        }

        _ = readByte()

        guard let infoData else {
            throw MonitorError.message("Torrent file does not contain info dictionary.")
        }

        return ParsedTorrent(infoData: infoData, name: name, trackers: unique(trackers))
    }

    private mutating func parseValue(depth: Int = 0) throws -> BencodeValue {
        guard depth < BencodeParser.maxDepth else {
            throw MonitorError.message("Torrent file is nested too deeply.")
        }
        guard let byte = peekByte() else {
            throw MonitorError.message("Unexpected end of torrent file.")
        }

        if byte == 105 { return try parseInteger() }
        if byte == 108 { return try parseList(depth: depth) }
        if byte == 100 { return try parseDictionary(depth: depth) }
        if byte >= 48 && byte <= 57 { return .bytes(try parseByteString()) }

        throw MonitorError.message("Unsupported torrent file format.")
    }

    private mutating func parseInteger() throws -> BencodeValue {
        _ = readByte()  // 'i'
        let start = index
        while let byte = peekByte(), byte != 101 {   // until 'e'
            index += 1
            if index - start > 20 {                  // a valid Int64 is <= 20 chars incl. sign
                throw MonitorError.message("Invalid integer in torrent file.")
            }
        }
        guard readByte() == 101 else {
            throw MonitorError.message("Invalid integer in torrent file.")
        }
        let text = String(decoding: bytes[start..<index - 1], as: UTF8.self)
        // Require a canonical integer (parses in Int64, no leading zeros / "-0" / sign
        // noise) rather than silently coercing garbage to 0 (audit F30/R1-19).
        guard let value = Int64(text), String(value) == text else {
            throw MonitorError.message("Invalid integer in torrent file.")
        }
        return .int(value)
    }

    private mutating func parseList(depth: Int) throws -> BencodeValue {
        _ = readByte()
        var values: [BencodeValue] = []
        while peekByte() != 101 {
            values.append(try parseValue(depth: depth + 1))
        }
        _ = readByte()
        return .list(values)
    }

    private mutating func parseDictionary(depth: Int) throws -> BencodeValue {
        _ = readByte()
        var values: [String: BencodeValue] = [:]
        while peekByte() != 101 {
            let keyData = try parseByteString()
            let key = String(data: keyData, encoding: .utf8) ?? ""
            values[key] = try parseValue(depth: depth + 1)
        }
        _ = readByte()
        return .dict(values)
    }

    private mutating func parseByteString() throws -> Data {
        var length = 0
        var hasDigit = false

        while let byte = peekByte(), byte >= 48 && byte <= 57 {
            hasDigit = true
            let (scaled, overflow1) = length.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = scaled.addingReportingOverflow(Int(byte - 48))
            guard !overflow1, !overflow2 else {
                throw MonitorError.message("Invalid string length in torrent file.")
            }
            length = sum
            index += 1
        }

        // `length <= bytes.count - index` avoids the overflow that `index + length` could trap on.
        guard hasDigit, readByte() == 58, length <= bytes.count - index else {
            throw MonitorError.message("Invalid string in torrent file.")
        }

        let start = index
        index += length
        return Data(bytes[start..<index])
    }

    private mutating func readByte() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    private func peekByte() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func trackerStrings(from value: BencodeValue) -> [String] {
        switch value {
        case .bytes(let data):
            if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                return [string]
            }
            return []
        case .list(let values):
            return values.flatMap { trackerStrings(from: $0) }
        case .dict, .int:
            return []
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

/// Converts a Double to Int64 without trapping on NaN/Infinity or values outside
/// Int64's range (Double(Int64.max) rounds ABOVE Int64.max, so a naive Int64(d)
/// can crash).
func safeInt64(_ value: Double) -> Int64 {
    guard value.isFinite else { return 0 }
    let r = value.rounded()
    if r >= 9.223372036854775e18 { return .max }
    if r <= -9.223372036854775e18 { return .min }
    return Int64(r)
}

/// Saturating Int64 sum — a hostile NAS returning several near-max values must not crash
/// the app via a trapping overflow on a display-time reduction (audit F25).
func saturatingSum(_ values: [Int64]) -> Int64 {
    var total: Int64 = 0
    for v in values {
        let (sum, overflow) = total.addingReportingOverflow(v)
        total = overflow ? (v > 0 ? .max : .min) : sum
    }
    return total
}

extension KeyedDecodingContainer {
    func lossyInt64(_ key: Key) -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        // Fractional or out-of-Int64-range numbers used to silently become 0,
        // dropping sizes/speeds. Round + clamp them instead (audit #46).
        if let value = try? decode(Double.self, forKey: key) { return safeInt64(value) }
        if let value = try? decode(String.self, forKey: key) {
            if let i = Int64(value) { return i }
            if let d = Double(value) { return safeInt64(d) }
        }
        return 0
    }
}

enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): value }
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

func readable(_ error: Error) -> String {
    if let apiError = error as? APIError {
        switch apiError.code {
        case 400: return "Wrong DSM username/password."
        case 101: return "Invalid Synology API parameters. Try this updated build; if it repeats, use a magnet link."
        case 403: return "DSM requires a two-step verification code."
        case 404: return "The two-step verification code was incorrect. Try again."
        case 406: return "Download Station: no download folder is set. Open DSM → Download Station → Settings → Location and set a default folder."
        case 105, 402: return "Permission denied. Give this DSM user access to Download Station."
        case 106, 107, 119: return "Synology session expired. Press Connect again."
        case 407: return "DSM blocked this computer's IP (Auto Block) after several failed logins. Unblock it from another device: DSM → Control Panel → Security → Auto Block."
        default: return "Synology error \(apiError.code)."
        }
    }
    if let httpError = error as? HTTPStatusError {
        return "Synology returned HTTP \(httpError.code). Please try again."
    }
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    // A raw JSON DecodingError is meaningless to the user (audit #47).
    if error is DecodingError {
        return "Synology returned an unexpected response. Try reconnecting; if it repeats, this DSM version may not be supported."
    }
    return error.localizedDescription
}

func formatBytes(_ value: Int64, precision: Int = 2) -> String {
    var number = Double(max(value, 0))
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var index = 0
    while number >= 1024, index < units.count - 1 {
        number /= 1024
        index += 1
    }
    // Rounding edge: 1023.9996 GB must roll up to "1.00 TB", not show "1024.00 GB".
    if index < units.count - 1 {
        let factor = pow(10.0, Double(precision))
        if (number * factor).rounded() / factor >= 1024 {
            number /= 1024
            index += 1
        }
    }
    if index == 0 { return "\(Int(number)) B" }
    return String(format: "%.\(precision)f %@", number, units[index])
}

func formatSpeed(_ value: Int64) -> String {
    "\(formatBytes(value, precision: 1))/s"
}

func formatTime(_ interval: TimeInterval?) -> String {
    // Guard NaN/Infinity/negative and cap before Int() to avoid a trap on a garbage
    // time-left from the NAS (audit #48/#37).
    guard let interval, interval.isFinite, interval >= 0 else { return "-" }
    let seconds = Int(min(interval, 86_400_000))  // cap ~1000 days
    if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
}

func decodedPercentTitle(_ value: String) -> String {
    guard value.contains("%"),
          let decoded = value.removingPercentEncoding,
          !decoded.isEmpty else {
        return value
    }
    return decoded
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)."
    }
}

enum KeychainService {
    static let service = "SynologyDownloadStationMonitor.password"

    static func save(password: String, host: String, username: String) throws {
        let account = "\(host)|\(username)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            // Re-assert ThisDeviceOnly on every save so the accessibility class can't
            // drift to a syncable default on the update path (audit F08).
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(password.utf8)
            // Never sync to iCloud Keychain / migrate off this Mac (audit #6).
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
            return
        }
        throw KeychainError(status: status)
    }

    /// Remove a stored password (e.g. when the user switches account so the old
    /// credential is not orphaned in Keychain — audit #4). Missing item is fine.
    static func delete(host: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(host)|\(username)"
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func load(host: String, username: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(host)|\(username)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - TLS certificate pinning (audit H1)

enum CertPinning {
    /// SHA-256 over the leaf certificate's PUBLIC KEY (SPKI-equivalent), lowercase hex.
    /// Pinning the key — not the whole DER — means a routine cert RE-ISSUE that keeps the
    /// same key still matches, avoiding needless lockouts (audit R2-03).
    static func spkiPin(from trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// Constant-time comparison of two hex pin strings.
private func pinsEqual(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8), rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
    return diff == 0
}

extension KeychainService {
    static let pinService = "SynologyDownloadStationMonitor.pin"

    /// The pinned cert hash for host, or nil on first use (TOFU).
    static func loadPin(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persist the confirmed cert pin. Returns true on success. The pin is a public-key
    /// hash (not a secret), but it is the MITM trust anchor, so it must never sync off
    /// this Mac (ThisDeviceOnly) and a write failure must be visible rather than silently
    /// disabling pinning (audit F07).
    @discardableResult
    static func savePin(_ pin: String, host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(pin.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(pin.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Forget the pinned identity so the next connect re-learns it (TOFU reset).
    /// Called by the "Reset certificate" action when the NAS rotates its cert.
    static func deletePin(host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinService,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension KeychainService {
    // A 2-step-verification "remember this device" token. It lets a 2FA account log in
    // without the OTP code, so it is a 2FA bypass secret: stored ThisDeviceOnly, keyed per
    // host|username, and wiped on Forget login details / Uninstall.
    static let deviceTokenService = "SynologyDownloadStationMonitor.devicetoken"

    static func loadDeviceToken(host: String, username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceTokenService,
            kSecAttrAccount as String: "\(host)|\(username)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveDeviceToken(_ token: String, host: String, username: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceTokenService,
            kSecAttrAccount as String: "\(host)|\(username)"
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func deleteDeviceToken(host: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceTokenService,
            kSecAttrAccount as String: "\(host)|\(username)"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Full self-uninstall (Phase 2)
// Removes every on-disk / Keychain trace belonging to THIS bundle id, then
// trashes the .app and quits. SAFETY: only paths whose last component contains
// the bundle id (or the whitelisted CFBundleName) are ever touched; nothing is
// removed by a broad or user-supplied path, and everything goes to the Trash
// (recoverable), never an irreversible unlink.

struct UninstallReport {
    var removed: [String] = []
    var skipped: [String] = []
    var failed: [String] = []

    var summary: String {
        var lines: [String] = []
        if !removed.isEmpty { lines.append("Removed:\n• " + removed.joined(separator: "\n• ")) }
        if !failed.isEmpty  { lines.append("Failed:\n• " + failed.joined(separator: "\n• ")) }
        if lines.isEmpty { lines.append("No traces found.") }
        return lines.joined(separator: "\n\n")
    }
}

enum SelfUninstall {
    static let bundleID = "com.abgitdev.SynologyDownloadStationMonitor"
    static let bundleName = "Synology Download Station Monitor" // CFBundleName

    // Service-only delete nukes every host|user account at once. Deleting a
    // missing service is a harmless no-op (errSecItemNotFound).
    static let keychainServices = [
        "SynologyDownloadStationMonitor.password",
        "SynologyDownloadStationMonitor.pin",
        "SynologyDownloadStationMonitor.devicetoken"
    ]

    private static func wipeKeychain(into report: inout UninstallReport) {
        for service in keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            // On macOS each SecItemDelete removes only ONE matching generic-password
            // item, so loop until none remain — otherwise extra host|user accounts
            // would survive the uninstall (verified empirically).
            var deleted = 0
            var lastStatus: OSStatus = errSecItemNotFound
            while deleted < 1000 {
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess { deleted += 1; continue }
                lastStatus = status
                break
            }
            switch lastStatus {
            case errSecItemNotFound:
                if deleted > 0 {
                    report.removed.append("Keychain: \(service) (\(deleted) account(s))")
                } else {
                    report.skipped.append("Keychain: \(service) (empty)")
                }
            default:
                let msg = (SecCopyErrorMessageString(lastStatus, nil) as String?) ?? "OSStatus \(lastStatus)"
                report.failed.append("Keychain \(service): \(msg) (removed \(deleted))")
            }
        }
    }

    private static func wipeFiles(into report: inout UninstallReport) {
        let targets: [(URL, String)] = [
            (libraryURL("Caches/\(bundleID)"),                             "Caches"),
            (libraryURL("HTTPStorages/\(bundleID)"),                       "HTTPStorages"),
            (libraryURL("HTTPStorages/\(bundleID).binarycookies"),         "HTTPStorages cookies"),
            (libraryURL("WebKit/\(bundleID)"),                             "WebKit"),
            (libraryURL("Saved Application State/\(bundleID).savedState"), "Saved Application State"),
            (libraryURL("Application Support/\(bundleID)"),                "Application Support (by id)"),
            (libraryURL("Application Support/\(bundleName)"),              "Application Support (by name)"),
            (libraryURL("Logs/\(bundleID)"),                              "Logs (by id)")   // audit R2-08
        ]
        for (url, label) in targets {
            trashIfBundleScoped(url, label: label, into: &report, allowName: bundleName)
        }
    }

    private static func wipeDefaults(into report: inout UninstallReport) {
        let defaults = UserDefaults.standard
        if defaults.persistentDomain(forName: bundleID) != nil {
            defaults.removePersistentDomain(forName: bundleID)
            defaults.synchronize()
            report.removed.append("UserDefaults (domain \(bundleID))")
        } else {
            report.skipped.append("UserDefaults (domain empty)")
        }
        // Trash the backing plist LAST (after synchronize) so cfprefsd doesn't
        // re-create it on top of our deletion.
        trashIfBundleScoped(libraryURL("Preferences/\(bundleID).plist"),
                            label: "Preferences plist", into: &report)
    }

    @discardableResult
    private static func trashOwnBundle(into report: inout UninstallReport) -> Bool {
        // Honour the bundle-id scoping invariant: only ever trash OUR bundle (audit F36).
        guard Bundle.main.bundleIdentifier == bundleID else {
            report.failed.append(".app: bundle id mismatch — leaving it alone (\(Bundle.main.bundleIdentifier ?? "nil"))")
            return false
        }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            report.failed.append(".app: unexpected path \(bundleURL.path)")
            return false
        }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: &resulting)
            report.removed.append(".app moved to Trash (\(bundleURL.lastPathComponent))")
            return true
        } catch {
            report.failed.append(".app: \(error.localizedDescription)")
            return false
        }
    }

    private static func libraryURL(_ relative: String) -> URL {
        let lib = (NSHomeDirectory() as NSString).appendingPathComponent("Library")
        return URL(fileURLWithPath: (lib as NSString).appendingPathComponent(relative))
    }

    /// Trash a path ONLY if its last component contains the bundle id (or the
    /// explicitly whitelisted app name). Never deletes anything else.
    private static func trashIfBundleScoped(_ url: URL, label: String,
                                            into report: inout UninstallReport,
                                            allowName: String? = nil) {
        let last = url.lastPathComponent
        let scoped = last.contains(bundleID) || (allowName != nil && last == allowName)
        guard scoped else {
            report.failed.append("\(label): skipped (path outside the app's domain: \(last))")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            report.skipped.append("\(label) (none)")
            return
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            report.removed.append("\(label): \(last)")
        } catch {
            report.failed.append("\(label): \(error.localizedDescription)")
        }
    }

    /// Trash this app's own crash logs (which can contain credentials/process memory) from
    /// ~/Library/Logs/DiagnosticReports — scoped strictly to our executable name (audit F29).
    private static func wipeCrashReports(into report: inout UninstallReport) {
        let execName = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "SynologyDownloadStationMonitor"
        let dir = libraryURL("Logs/DiagnosticReports")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            report.skipped.append("DiagnosticReports (none)")
            return
        }
        var removed = 0
        for name in entries where name.hasPrefix(execName) {
            do { try FileManager.default.trashItem(at: dir.appendingPathComponent(name), resultingItemURL: nil); removed += 1 }
            catch { report.failed.append("Crash log \(name): \(error.localizedDescription)") }
        }
        if removed > 0 { report.removed.append("DiagnosticReports: \(removed) crash log(s)") }
        else { report.skipped.append("DiagnosticReports (none of ours)") }
    }

    /// Wipe all data/Keychain/defaults/crash logs, then trash the .app bundle.
    static func wipeAll() -> UninstallReport {
        var report = UninstallReport()
        wipeKeychain(into: &report)
        wipeFiles(into: &report)
        wipeDefaults(into: &report)
        wipeCrashReports(into: &report)
        trashOwnBundle(into: &report)
        return report
    }

    /// `cfprefsd` re-writes ~/Library/Preferences/<id>.plist when our process exits, so the
    /// in-process domain wipe above can't make it stick — a live forensic check found the
    /// plist resurrected after a self-uninstall. Spawn a detached `/bin/sh` that waits for
    /// THIS process to die (so cfprefsd has done its final flush), then clears the cfprefsd
    /// cache and removes the backing plist files. Orphaned to launchd, it outlives our own
    /// terminate(). The plist holds only host/username/settings (no secrets — the password
    /// lives in the Keychain, wiped separately), so a hard delete here leaves no trace.
    /// bundleID is a fixed reverse-DNS literal (no shell metacharacters), safe to inline.
    static func schedulePostExitPrefsPurge() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        defaults delete \(bundleID) >/dev/null 2>&1
        rm -f "$HOME/Library/Preferences/\(bundleID).plist"
        rm -f "$HOME/Library/Preferences/ByHost/\(bundleID)."*.plist
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()   // do NOT wait — detach and let it finish after we terminate
    }
}
