import Foundation
import Synchronization

@testable import LintelProviders
@testable import MeetingsPlugin

/// A `ProviderChoiceModel` over fakes: probes and tests answer from the rig, nothing starts a process, the pasteboard
/// and URLs are recorded.
@MainActor
final class ProviderChoiceRig {
    let model: ProviderChoiceModel
    let probes = Cell(0)
    let tryOuts = Cell([String]())
    let urls = Cell([URL]())
    let copied = Cell([String]())
    let changes = Cell(0)
    let report = Cell(ProviderStatusReport(status: .ready, version: "2.1.329"))
    let tryResult = Cell(TryOutResult.worked)
    let pickedFile = Cell<URL?>(nil)

    init(settings: MeetingsSettings, service: NotesService) {
        let probes = probes
        let tryOuts = tryOuts
        let urls = urls
        let copied = copied
        let changes = changes
        let report = report
        let tryResult = tryResult
        let pickedFile = pickedFile
        model = ProviderChoiceModel(
            settings: settings, service: service,
            probe: { _ in
                probes.withLock { $0 += 1 }
                return report.withLock { $0 }
            },
            tryOut: { _, model in
                tryOuts.withLock { $0.append(model) }
                return tryResult.withLock { $0 }
            },
            openURL: { url in urls.withLock { $0.append(url) } },
            copyText: { text in copied.withLock { $0.append(text) } },
            chooseFile: { pickedFile.withLock { $0 } },
            changed: { changes.withLock { $0 += 1 } })
    }
}

/// A value shared between the model's closures and the test.
final class Cell<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func withLock<T: Sendable>(_ body: (inout Value) -> T) -> T { state.withLock { body(&$0) } }
}
