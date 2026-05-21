import SwiftUI

// MARK: - NavigationCoordinator
// View-factory methods extracted from AppDelegate to separate navigation
// concerns from panel lifecycle.

extension AppDelegate {

    func mainView() -> AnyView {
        savedNavState = nil
        return wrapEnv(PopoverMainView(
            store: observable,
            onSelectJob: { _ in },
            onSelectAction: { _ in },
            onStepTap: { [weak self] job, step in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enriched = self.enrichStepsIfNeeded(job)
                    DispatchQueue.main.async {
                        guard self.panelIsOpen else { return }
                        self.navigate(to: self.stepLogFromMain(job: enriched, step: step))
                    }
                }
            },
            onSelectSettings: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    func stepLogFromMain(job: ActiveJob, step: JobStep) -> AnyView {
        savedNavState = .stepLog(job, step)
        return wrapEnv(StepLogView(
            job: job,
            step: step,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onLogLoaded: nil
        ))
    }

    func settingsView() -> AnyView {
        savedNavState = .settings
        makeKeyForTextInput()
        return wrapEnv(SettingsView(
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.mainView())
            },
            onSelectRunner: { [weak self] runner in
                guard let self else { return }
                self.navigate(to: self.runnerDetailView(runner: runner))
            },
            onSelectScope: { [weak self] entry in
                guard let self else { return }
                self.navigate(to: self.scopeDetailView(entry: entry))
            },
            store: observable
        ))
    }

    func runnerDetailView(runner: RunnerModel) -> AnyView {
        savedNavState = .runnerDetail(runner)
        makeKeyForTextInput()
        return wrapEnv(RunnerDetailView(
            runner: runner,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    func scopeDetailView(entry: ScopeEntry) -> AnyView {
        savedNavState = .scopeDetail(entry)
        makeKeyForTextInput()
        let live = ScopeStore.shared.entries.first(where: { $0.id == entry.id }) ?? entry
        return wrapEnv(ScopeDetailView(
            scopeEntry: live,
            onBack: { [weak self] in
                guard let self else { return }
                self.navigate(to: self.settingsView())
            }
        ))
    }

    func validatedView(for state: NavState) -> AnyView? {
        savedNavState = nil
        let store = RunnerStore.shared
        switch state {
        case .main:
            return nil
        case .stepLog(let job, let step):
            let live = store.jobs.first(where: { $0.id == job.id }) ?? job
            return stepLogFromMain(job: live, step: step)
        case .settings:
            return settingsView()
        case .runnerDetail(let runner):
            let live = LocalRunnerStore.shared.runners.first(where: { $0.id == runner.id }) ?? runner
            return runnerDetailView(runner: live)
        case .scopeDetail(let entry):
            guard let live = ScopeStore.shared.entries.first(where: { $0.id == entry.id }) else {
                return settingsView()
            }
            return scopeDetailView(entry: live)
        }
    }
}
