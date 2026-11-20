#if DEBUG
import Foundation
import LintelKit

/// DEBUG builds only: shows the Vocabulary section in any state of part A of the mockup with an invented
/// vocabulary, so QA never needs a real one. `--qa-setting plugins.dictation.qaVocabulary=<state>`, with
/// Dictation switched on (`--qa-setting plugins.dictation.enabled=true`). The seed file is written into the QA run's
/// own data root at every launch. Not a contract; documented in `docs/qa.md`.
///
/// States: `empty`, `few` (5 terms), `long` (47), `search:<text>` (47 and that search), `add`, `edit`,
/// `err-empty`, `err-dupterm`, `err-alias`, `err-rule`, `err-long`, `noalias`, `limit` (2000), `short`,
/// `short-ok`, `off`, `delete`, `readonly` (a file from a newer version), `corrupt` (a damaged file),
/// `saveerror` (the write fails), `keyboard` (the list has the keyboard on the second row).
enum VocabularyQA {
    static let key = "qaVocabulary"

    static func state(_ context: PluginContext) -> String? {
        let value = context.settings.string(key)
        return value?.isEmpty == false ? value : nil
    }

    /// The store, with its file seeded for the state. `saveerror` makes every write fail.
    static func makeStore(context: PluginContext) -> VocabularyStore {
        guard let state = state(context) else {
            return VocabularyStore(directory: context.storageDirectory, logger: context.logger)
        }
        seed(state, into: context.storageDirectory, fileName: VocabularyStore.fileName)
        guard state == "saveerror" else {
            return VocabularyStore(directory: context.storageDirectory, logger: context.logger)
        }
        return VocabularyStore(
            directory: context.storageDirectory, logger: context.logger,
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    }

    /// Opens the form, the sheet or the search the state asks for. Runs after the store is loaded.
    @MainActor static func apply(to model: VocabularyPanelModel, context: PluginContext) {
        guard let state = state(context) else { return }
        let name = state.split(separator: ":", maxSplits: 1).first.map(String.init) ?? state
        let argument = state.contains(":") ? String(state.split(separator: ":", maxSplits: 1)[1]) : ""
        func index(of term: String) -> Int? { model.entries.firstIndex { $0.term == term } }
        switch name {
        case "search": model.query = argument
        case "add":
            model.beginAdding()
        case "edit":
            if let id = index(of: "AuthService") {
                model.beginEditing(id)
                model.setPending("auth serwis")
            }
        case "err-empty":
            model.beginAdding()
            model.fill(term: "", aliases: ["kubernetis"])
            model.submit()
        case "err-dupterm":
            model.beginAdding()
            model.fill(term: "authservice", aliases: [])
            model.submit()
        case "err-alias":
            model.beginAdding()
            model.fill(term: "AuthServer", aliases: ["auth service", "auth serwer"])
            model.submit()
        case "err-rule":
            // Editing SwiftUI: its new variant "swift" is the term Swift (prototype `err-rule`, "Save").
            if let id = index(of: "SwiftUI") {
                model.beginEditing(id)
                model.fill(term: "SwiftUI", aliases: ["swift ui", "swift"])
                model.submit()
            }
        case "err-long":
            model.beginAdding()
            model.fill(term: "RFC 9110", aliases: ["er ef ce dziewięć tysięcy sto dziesięć http semantics spec"])
            model.submit()
        case "noalias":
            model.beginAdding()
            model.fill(term: "Verdigris", aliases: [])
            model.returnInTerm()
        case "short", "short-ok":
            model.beginAdding()
            model.fill(term: "Zed", aliases: ["zet", "zed edytor"])
            if name == "short-ok" { model.setShortAliasesConfirmed(true) }
        case "off":
            model.isEnabled = false
        case "delete":
            if let id = index(of: "AuthService") { model.requestDelete(id) }
        case "saveerror":
            model.beginAdding()
            model.fill(term: "Orchard", aliases: ["orczard", "orczardu"])
            model.submit()
        case "keyboard":
            model.selectedID = model.allRows.dropFirst().first?.id
            model.focusListOnAppear = true
        default:
            break
        }
    }

    // MARK: Seed

    private static func seed(_ state: String, into directory: URL, fileName: String) {
        let name = state.split(separator: ":", maxSplits: 1).first.map(String.init) ?? state
        let terms: [VocabularyStore.Term]
        var version = VocabularyStore.version
        var raw: String?
        switch name {
        case "empty": terms = []
        case "long", "search": terms = longList()
        case "limit": terms = (1...VocabularyStore.maximumTerms).map(generated)
        case "readonly":
            terms = Array(fewList().prefix(3))
            version = VocabularyStore.version + 1
        case "corrupt":
            terms = []
            raw = "{ not a vocabulary"
        case "err-rule": terms = fewList() + [.init(term: "Swift", aliases: ["słift"])]
        default: terms = fewList()
        }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: fileName)
        // A leftover copy of a damaged file would show the notice of an earlier run.
        if name != "corrupt" { try? manager.removeItem(at: directory.appending(path: VocabularyStore.corruptFileName)) }
        let data: Data
        if let raw {
            data = Data(raw.utf8)
        } else {
            let object: [String: Any] = [
                "version": version,
                "terms": terms.map { ["term": $0.term, "aliases": $0.aliases] },
            ]
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
        try? data.write(to: file, options: .atomic)
    }

    private static func fewList() -> [VocabularyStore.Term] {
        [
            .init(term: "AuthService", aliases: ["auth service", "ałt serwis"]),
            .init(term: "gRPC", aliases: ["gie er pe ce", "dżi ar pi si"]),
            .init(term: "Jagna Zdrojewska", aliases: ["jagna zdrojeska", "jagnę zdrojewską", "jagny zdrojewskiej"]),
            .init(term: "PostgreSQL", aliases: ["postgres", "post gres ku el"]),
            .init(term: "SwiftUI", aliases: ["swift ui", "słift ju aj"]),
        ]
    }

    private static let names = [
        "Figma", "FSEvents", "Kubernetes", "llama.cpp", "Orchard", "Nextcloud", "Terraform", "Grafana",
        "Prometheus", "Redis", "Kafka", "RabbitMQ", "Elasticsearch", "Webpack", "Vite", "Svelte", "Tailwind",
        "Docker", "Podman", "Ansible", "Vagrant", "Consul", "Nomad", "Vault", "Traefik", "Caddy", "Nginx",
        "Envoy", "Istio", "Linkerd", "Jaeger", "Zipkin", "Loki", "Tempo", "Mimir", "Thanos", "Cortex",
        "Sentry", "Honeycomb", "Lightstep", "Rollbar", "Bazel", "Gradle",
    ]

    private static func longList() -> [VocabularyStore.Term] {
        var terms = fewList()
        for name in names {
            switch name {
            case "Nextcloud": terms.append(.init(term: name, aliases: ["nekst klałd", "post klałd"]))
            case "Figma": terms.append(.init(term: name, aliases: ["figmę", "figmie"]))
            case "Kubernetes": terms.append(.init(term: name, aliases: ["kubernetis", "kubernetesa"]))
            case "Orchard": terms.append(.init(term: name, aliases: ["orczard", "orczardu"]))
            default: terms.append(.init(term: name, aliases: [name.lowercased() + "a"]))
            }
        }
        return Array(terms.prefix(47))
    }

    private static func generated(_ number: Int) -> VocabularyStore.Term {
        let label = String(format: "%04d", number)
        return .init(term: "Term \(label)", aliases: ["termin \(label)"])
    }
}
#endif
