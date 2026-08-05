import AppKit
import NibCore
import NibUI

/// The `NIB_SELFTEST*` diagnostic hooks.
///
/// These exist because a GUI bug and an engine bug look identical from the outside — "I clicked
/// send and nothing happened" is equally true when the request failed, and when it succeeded and
/// was rendered somewhere invisible. Driving the app's own model, with the app's own Info.plist,
/// ATS policy and code signature, separates the two. The unit tests cannot: they run in a test
/// bundle that has none of those.
///
/// Every one of them has already paid for itself. The window-geometry dump found a response pane
/// rendered off-screen; the environment hook is how "flip Local to Staging and the same request
/// hits a different host" gets checked by a script rather than by eye; the secret hook is the only
/// way to know whether the *shipped, ad-hoc-signed* bundle can write to the Keychain at all.
///
/// Split into its own file to keep `AppDelegate` about the lifecycle. They are diagnostics, they
/// share no state with it, and they were the reason the class outgrew its length limit.
extension AppDelegate {

    /// Diagnostic hook: open a collection folder and report what loaded.
    ///
    ///     NIB_SELFTEST_COLLECTION=/path/to/folder dist/Nib.app/Contents/MacOS/Nib
    ///
    /// Same reasoning as `NIB_SELFTEST`: a store bug and a sidebar bug are indistinguishable from
    /// outside, and the unit tests cannot exercise the app's own wiring.
    func runCollectionSelfTestIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NIB_SELFTEST_COLLECTION"],
            let model
        else { return }

        func report(_ line: String) {
            FileHandle.standardError.write(Data("[collection] \(line)\n".utf8))
        }

        Task {
            let collectionModel = model.collectionModel
            await collectionModel.open(URL(fileURLWithPath: path))

            guard let collection = collectionModel.collection else {
                report("FAILED: \(collectionModel.loadFailure ?? "nothing loaded")")
                NSApp.terminate(nil)
                return
            }

            reportTree(collection, model: collectionModel, report: report)
            await runSelfTestImport(model: model, report: report)
            reportEnvironments(model: collectionModel, report: report)
            await runSecretSelfTest(model: collectionModel, report: report)
            await sendSelectedAndReport(model: model, report: report)

            NSApp.terminate(nil)
        }
    }

    func reportTree(
        _ collection: NibCore.Collection,
        model: CollectionModel,
        report: (String) -> Void
    ) {
        report("name: \(collection.name)")
        report("children: \(collection.children.map(\.name))")
        report("diagnostics: \(model.diagnostics)")

        for (request, folderPath) in collection.allRequests {
            let location = folderPath.map(\.name).joined(separator: "/")
            let prefix = location.isEmpty ? "" : location + "/"
            report("  \(request.spec.method) \(prefix)\(request.name) -> \(request.spec.url)")
        }

        report("fuzzy candidates: \(model.fuzzyCandidates.count)")
        let matches = FuzzyMatcher.match(query: "swift", in: model.fuzzyCandidates)
        report("Cmd-K 'swift': \(matches.map(\.text))")
    }

    /// Optional second stage: import a Postman export into the collection we just opened.
    func runSelfTestImport(model: AppModel, report: (String) -> Void) async {
        guard let importPath = ProcessInfo.processInfo.environment["NIB_SELFTEST_IMPORT"] else {
            return
        }

        await model.importCoordinator.importFiles([URL(fileURLWithPath: importPath)])
        if let failure = model.importCoordinator.failure {
            report("IMPORT FAILED: \(failure)")
        } else if let imported = model.importCoordinator.report {
            report("imported collections: \(imported.collectionNames)")
            report("imported environments: \(imported.environmentNames)")
            report("imported requests: \(imported.requestCount)")
            for diagnostic in imported.diagnostics {
                report("  [\(diagnostic.severity)] \(diagnostic.path): \(diagnostic.message)")
            }
        }
        report("tree now: \(model.collectionModel.collection?.children.map(\.name) ?? [])")
        report("requests now: \(model.collectionModel.collection?.allRequests.count ?? 0)")
    }

    /// Optional third stage: select an environment by name, so the "flip Local to Staging and the
    /// same request hits a different host" claim can be checked from a script rather than by eye.
    ///
    ///     NIB_SELFTEST_ENVIRONMENT=Staging
    func reportEnvironments(model: CollectionModel, report: (String) -> Void) {
        report("environments: \(model.environments.map(\.name))")
        report("secrets: \(model.secretsFailure ?? "available")")

        if let wanted = ProcessInfo.processInfo.environment["NIB_SELFTEST_ENVIRONMENT"] {
            if let match = model.environments.first(where: { $0.name == wanted }) {
                model.setActiveEnvironment(match.id)
            } else {
                report("NO SUCH ENVIRONMENT: \(wanted)")
            }
        }

        report("active environment: \(model.activeEnvironment?.name ?? "<none>")")
        for variable in model.activeEnvironment?.variables ?? [] {
            let value =
                variable.secret
                ? "<keychain: \(variable.value == nil ? "unset" : "set")>"
                : variable.value ?? "<unset>"
            report("  \(variable.key) = \(value)\(variable.enabled ? "" : " (disabled)")")
        }
    }

    /// Optional fourth stage: store a secret and read it back through the real app.
    ///
    ///     NIB_SELFTEST_SECRET=API_TOKEN=sk-test-123
    ///
    /// This one earns its place. Everything about the Keychain path depends on the app's code
    /// signature, and Nib ships ad-hoc signed — so a unit test running in a test bundle proves
    /// nothing about whether the shipped bundle can write a secret at all. Only the real app can
    /// answer that.
    func runSecretSelfTest(model: CollectionModel, report: (String) -> Void) async {
        guard let raw = ProcessInfo.processInfo.environment["NIB_SELFTEST_SECRET"],
            let separator = raw.firstIndex(of: "="),
            let environment = model.activeEnvironment
        else { return }

        let key = String(raw[raw.startIndex..<separator])
        let value = String(raw[raw.index(after: separator)...])

        var edited = environment
        edited.variables.removeAll { $0.key == key }
        edited.variables.append(.init(key: key, value: value, secret: true))
        model.stage(edited)
        await model.commitEnvironments()

        report("secret write: \(model.secretsFailure ?? "ok")")

        // Read it back through a second model opening the same folder — the launch path, not a
        // shortcut. Blanking the value in place would not do: the next commit would reconcile the
        // Keychain against that blank and delete the entry we are trying to verify.
        guard let root = model.rootURL else { return }
        let fresh = CollectionModel()
        await fresh.open(root)
        defer { fresh.close() }

        let readBack =
            fresh.environments
            .first { $0.name == edited.name }?
            .variables.first { $0.key == key }?.value
        report("secret round trip: \(readBack == value ? "ok" : "MISMATCH (\(readBack ?? "nil"))")")
        report("secret on disk: \(Self.secretAppearsOnDisk(value, in: root) ? "LEAKED" : "no")")
    }

    /// Grep the whole collection folder for the secret. The invariant deserves a check that does
    /// not trust any of our own code paths.
    static func secretAppearsOnDisk(_ value: String, in root: URL) -> Bool {
        guard
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return false }

        for case let url as URL in files {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if contents.contains(value) { return true }
        }
        return false
    }

    func sendSelectedAndReport(model: AppModel, report: (String) -> Void) async {
        report("selected: \(model.collectionModel.selectedRequest?.name ?? "<none>")")
        model.loadSelectedRequest()
        // The picker may have moved since the request was loaded, which is exactly the case
        // `refreshScope` exists for.
        model.refreshScope()

        report("session url: \(model.session.spec.url)")
        report("inherited auth: \(model.session.inheritedAuth)")
        report("canSend: \(model.session.canSend)")
        report("scope baseUrl: \(model.session.scope.value(for: "baseUrl") ?? "<undefined>")")
        report("resolved url: \(model.session.resolvedURL)")
        report("pending unresolved: \(model.session.pendingUnresolved)")

        model.sendCurrentRequest()
        await model.session.inFlight?.value
        report("unresolved: \(model.session.unresolved.map(\.name))")
        report("notes: \(model.session.notes)")
        if let response = model.session.response {
            report("RESPONSE \(response.status) \(response.statusText) in \(response.durationText)")
        } else {
            report("state: \(model.session.state)")
        }
    }

    /// Diagnostic hook: send one request through the real app and report what happened.
    ///
    ///     NIB_SELFTEST=https://example.com dist/Nib.app/Contents/MacOS/Nib
    ///
    /// This exists because a GUI bug and an engine bug look identical from the outside — "I clicked
    /// send and nothing happened" is true whether the request failed, or succeeded and was rendered
    /// somewhere invisible. Exercising the app's own model, with the app's own Info.plist and ATS
    /// policy, separates the two. The unit tests cannot: they run in a test bundle that has neither.
    func runSelfTestIfRequested() {
        guard let target = ProcessInfo.processInfo.environment["NIB_SELFTEST"],
            let controller = mainWindowController
        else { return }

        let session = controller.model.session
        session.spec.url = target

        func report(_ line: String) {
            FileHandle.standardError.write(Data("[selftest] \(line)\n".utf8))
        }

        report("url: \(target)")
        report("canSend: \(session.canSend)")

        // Pane geometry, because "nothing happened" is also what a collapsed response pane looks
        // like, and the autosaved divider position survives across builds.
        if let window = controller.window {
            report("window: \(Int(window.frame.width))x\(Int(window.frame.height))")
            if let split = window.contentViewController as? NSSplitViewController {
                for (index, item) in split.splitViewItems.enumerated() {
                    let size = item.viewController.view.frame
                    report(
                        "  pane \(index): \(Int(size.width))x\(Int(size.height)) "
                            + "collapsed=\(item.isCollapsed)")
                    if let nested = item.viewController as? NSSplitViewController {
                        for (subIndex, subItem) in nested.splitViewItems.enumerated() {
                            let subSize = subItem.viewController.view.frame
                            report(
                                "    subpane \(subIndex): \(Int(subSize.width))x"
                                    + "\(Int(subSize.height)) collapsed=\(subItem.isCollapsed)")
                        }
                    }
                }
            }
        }

        session.send()

        Task {
            await session.inFlight?.value
            report("state: \(session.state)")
            report("notes: \(session.notes)")
            report("unresolved: \(session.unresolved.map(\.name))")
            if let response = session.response {
                report("RESPONSE \(response.status) \(response.statusText)")
                report("  duration: \(response.durationText)  size: \(response.sizeText)")
                report("  body[0..120]: \(response.bodyText.prefix(120))")
            } else {
                report("RESPONSE: none")
            }
            NSApp.terminate(nil)
        }
    }
}
