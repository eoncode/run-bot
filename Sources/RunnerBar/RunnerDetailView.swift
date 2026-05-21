import AppKit
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// #491: Scaffold + read-only info block
// #492: Editable config fields (labels, workFolder, autoUpdate, proxy)
// #493: Danger Zone (remove only)
// #532: Redesign — two-row header, slim info section, unified proxy card
// #533: OS/Arch + Version rows in Runner Info; Danger Zone always expanded

// MARK: - Save state helper
enum SaveState: Equatable {
    case idle
    case saving
    case success
    case failure(String)
}

// MARK: - Danger action
enum DangerAction: Identifiable, Equatable {
    case remove

    var id: String { "remove" }
    var title: String { "Remove runner" }
    var confirmLabel: String { "Remove" }
    var destructive: Bool { true }
}

// swiftlint:disable:next type_body_length
struct RunnerDetailView: View {
    let runner: RunnerModel
    let onBack: () -> Void

    @State var isRunning: Bool
    @State var displayStatus: String
    @ObservedObject var localRunnerStore = LocalRunnerStore.shared

    @State var labelsText: String
    @State var labelsSaveState: SaveState = .idle
    @State var workFolderText: String
    @State var workFolderSaveState: SaveState = .idle
    @State var autoUpdate: Bool
    @State var autoUpdateSaveState: SaveState = .idle
    @State var proxyUrl: String
    @State var proxyUser: String
    @State var proxyPassword: String
    @State var proxySaveState: SaveState = .idle
    @State var displayOsArch: String = ""
    @State var displayVersion: String = ""
    @State var pendingDangerAction: DangerAction?
    @State var dangerActionState: SaveState = .idle

    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        self._isRunning = State(initialValue: runner.isRunning)
        self._displayStatus = State(initialValue: runner.displayStatus)
        self._labelsText = State(initialValue: runner.labels
            .filter { !["self-hosted"].contains($0)
                && !$0.lowercased().contains("x64")
                && !$0.lowercased().contains("arm64")
                && !$0.lowercased().contains("linux")
                && !$0.lowercased().contains("macos")
                && !$0.lowercased().contains("windows") }
            .joined(separator: ", ")
        )
        self._workFolderText = State(initialValue: runner.workFolder ?? "_work")
        self._autoUpdate = State(initialValue: true)
        self._proxyUrl = State(initialValue: "")
        self._proxyUser = State(initialValue: "")
        self._proxyPassword = State(initialValue: "")
        let osArch = [runner.platform, runner.platformArchitecture]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        self._displayOsArch = State(initialValue: osArch)
        self._displayVersion = State(initialValue: runner.agentVersion ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    configSection
                    dangerZoneSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onAppear(perform: loadEditableFields)
        .onChange(of: localRunnerStore.runners) { updated in
            if let fresh = updated.first(where: { $0.id == runner.id }) {
                isRunning = fresh.isRunning
                displayStatus = fresh.displayStatus
            }
        }
        .sheet(item: $pendingDangerAction, content: dangerActionSheet)
    }

    // MARK: - Save Actions

    func saveLabels() {
        guard let agentId = runner.agentId,
              let gitHubUrl = runner.gitHubUrl,
              let scope = scopeFromHtmlUrl(gitHubUrl)
        else {
            labelsSaveState = .failure("No agent ID or GitHub URL — cannot save via API")
            return
        }
        let parsed = labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        labelsSaveState = .saving
        DispatchQueue.global(qos: .userInitiated).async {
            let result = patchRunnerLabels(scope: scope, runnerID: agentId, labels: parsed)
            DispatchQueue.main.async {
                if result != nil {
                    labelsSaveState = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if labelsSaveState == .success { labelsSaveState = .idle }
                    }
                } else {
                    labelsSaveState = .failure("Failed to save labels via GitHub API")
                }
            }
        }
    }

    func saveWorkFolder() {
        guard let installPath = runner.installPath else {
            workFolderSaveState = .failure("Install path unknown"); return
        }
        workFolderSaveState = .saving
        let value = workFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "workFolder", stringValue: value)
            DispatchQueue.main.async {
                workFolderSaveState = ok ? .success : .failure("Failed to write .runner JSON")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if workFolderSaveState == .success { workFolderSaveState = .idle }
                    }
                }
            }
        }
    }

    func saveAutoUpdate() {
        guard let installPath = runner.installPath else {
            autoUpdateSaveState = .failure("Install path unknown"); return
        }
        autoUpdateSaveState = .saving
        let disableUpdate = !autoUpdate
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "disableUpdate", boolValue: disableUpdate)
            DispatchQueue.main.async {
                autoUpdateSaveState = ok ? .success : .failure("Failed to write .runner JSON")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if autoUpdateSaveState == .success { autoUpdateSaveState = .idle }
                    }
                }
            }
        }
    }

    func saveProxy() {
        guard let installPath = runner.installPath else {
            proxySaveState = .failure("Install path unknown"); return
        }
        proxySaveState = .saving
        let urlValue = proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = proxyUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            let proxyFilePath = installPath + "/.proxy"
            do {
                if urlValue.isEmpty {
                    if FileManager.default.fileExists(atPath: proxyFilePath) {
                        try FileManager.default.removeItem(atPath: proxyFilePath)
                    }
                } else {
                    try urlValue.write(toFile: proxyFilePath, atomically: true, encoding: .utf8)
                }
            } catch { ok = false }
            let credPath = installPath + "/.proxycredentials"
            do {
                if user.isEmpty && pass.isEmpty {
                    if FileManager.default.fileExists(atPath: credPath) {
                        try FileManager.default.removeItem(atPath: credPath)
                    }
                } else {
                    try "\(user)\n\(pass)".write(toFile: credPath, atomically: true, encoding: .utf8)
                }
            } catch { ok = false }
            DispatchQueue.main.async {
                proxySaveState = ok ? .success : .failure("Failed to save proxy settings")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if proxySaveState == .success { proxySaveState = .idle }
                    }
                }
            }
        }
    }

    func startRunner() {
        isRunning = true
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = false
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    func stopRunner() {
        isRunning = false
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = true
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    func triggerDangerAction(_ action: DangerAction) {
        dangerActionState = .idle
        pendingDangerAction = action
    }

    func executeDangerAction(_ action: DangerAction) {
        dangerActionState = .saving
        performRemove()
    }

    func performRemove() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = RunnerLifecycleService.shared.remove(runner: runner)
            DispatchQueue.main.async {
                if ok {
                    dangerActionState = .success
                    LocalRunnerStore.shared.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        pendingDangerAction = nil
                        onBack()
                    }
                } else {
                    dangerActionState = .failure("Removal failed. Check logs.")
                }
            }
        }
    }

    // swiftlint:disable:next function_body_length
    func loadEditableFields() {
        log("RunnerDetailView loadEditableFields ENTER runner=\(runner.runnerName)")
        guard let installPath = runner.installPath else {
            log("RunnerDetailView loadEditableFields BAIL installPath is nil")
            return
        }
        let runnerJSONPath = installPath + "/.runner"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: runnerJSONPath)) else {
            log("RunnerDetailView loadEditableFields ERROR could not read .runner file")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("RunnerDetailView loadEditableFields ERROR could not parse JSON")
            return
        }
        let disableUpdate = json["disableUpdate"] as? Bool ?? false
        autoUpdate = !disableUpdate
        if displayOsArch.isEmpty {
            let platform = json["platform"] as? String ?? ""
            let arch = json["platformArchitecture"] as? String ?? ""
            let combined = [platform, arch].filter { !$0.isEmpty }.joined(separator: " / ")
            if !combined.isEmpty { displayOsArch = combined }
        }
        if displayVersion.isEmpty {
            if let version = json["agentVersion"] as? String, !version.isEmpty {
                displayVersion = version
            }
        }
        let proxyFilePath = installPath + "/.proxy"
        proxyUrl = (try? String(contentsOfFile: proxyFilePath, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let credPath = installPath + "/.proxycredentials"
        if let credContent = try? String(contentsOfFile: credPath, encoding: .utf8) {
            let lines = credContent.components(separatedBy: "\n")
            proxyUser = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            proxyPassword = lines.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        log("RunnerDetailView loadEditableFields EXIT displayOsArch=\(displayOsArch) displayVersion=\(displayVersion)")
    }
}

// MARK: - .runner JSON patch helper

func patchRunnerJSON(
    installPath: String,
    key: String,
    stringValue: String? = nil,
    boolValue: Bool? = nil
) -> Bool {
    let path = installPath + "/.runner"
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        log("patchRunnerJSON › failed to read \(path)")
        return false
    }
    if let sv = stringValue { json[key] = sv }
    if let bv = boolValue   { json[key] = bv }
    guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
        log("patchRunnerJSON › serialization failed for key=\(key)")
        return false
    }
    do {
        try newData.write(to: url, options: .atomic)
        log("patchRunnerJSON › wrote key=\(key) to \(path)")
        return true
    } catch {
        log("patchRunnerJSON › write failed: \(error)")
        return false
    }
}
