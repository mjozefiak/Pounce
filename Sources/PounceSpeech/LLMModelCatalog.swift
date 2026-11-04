import Foundation

/// A formatting model the user can download in Settings (ADR 0005). A GGUF file is a one-file `ModelPackage`,
/// so `ModelManager` downloads, verifies, resumes and deletes it exactly like a speech model.
public struct LLMModel: Hashable, Sendable, Identifiable {
    public let package: ModelPackage
    /// Memory the loaded model takes, measured with llama.cpp on an M4 Max (ADR 0005), for the Settings hint.
    public let residentBytes: Int
    /// The least installed memory the model is offered on.
    public let minimumMemoryBytes: Int

    public init(package: ModelPackage, residentBytes: Int, minimumMemoryBytes: Int) {
        self.package = package
        self.residentBytes = residentBytes
        self.minimumMemoryBytes = minimumMemoryBytes
    }

    public var id: String { package.id }

    /// The GGUF file inside the installed folder.
    public func fileURL(in folder: URL) -> URL? {
        guard let entry = package.files.first else { return nil }
        return folder.appending(path: package.relativePath(of: entry.file, in: entry.source))
    }
}

/// The formatting models Pounce can download. Compiled in: only these files, from these revisions, with these
/// hashes, are ever fetched (an arbitrary GGUF is parsed in the Pounce process, so v1 offers none).
public enum LLMModelCatalog {
    private static let gibibyte = 1 << 30

    /// Qwen3-4B-Instruct-2507, Q4_K_M: the default, fast and small.
    public static let qwen3Small = LLMModel(
        package: ModelPackage(
            id: "llm-qwen3-4b-instruct-2507-q4km",
            title: "Qwen3 4B Instruct 2507",
            license: "Apache-2.0",
            attribution: "Qwen3-4B-Instruct-2507 by Alibaba Cloud (Qwen), GGUF quantization by Unsloth. Apache 2.0.",
            sources: [
                ModelSource(
                    repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
                    revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
                    into: "",
                    files: [
                        ModelFile(
                            path: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", size: 2_497_281_120,
                            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
                    ])
            ]),
        residentBytes: 3_274_784_768,
        minimumMemoryBytes: 8 * gibibyte)

    /// Qwen3-30B-A3B-Instruct-2507, Q4_K_M: the best quality measured, for Macs with plenty of memory.
    public static let qwen3Large = LLMModel(
        package: ModelPackage(
            id: "llm-qwen3-30b-a3b-instruct-2507-q4km",
            title: "Qwen3 30B-A3B Instruct 2507",
            license: "Apache-2.0",
            attribution:
                "Qwen3-30B-A3B-Instruct-2507 by Alibaba Cloud (Qwen), GGUF quantization by Unsloth. Apache 2.0.",
            sources: [
                ModelSource(
                    repository: "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF",
                    revision: "eea7b2be5805a5f151f8847ede8e5f9a9284bf77",
                    into: "",
                    files: [
                        ModelFile(
                            path: "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf", size: 18_556_686_752,
                            sha256: "6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0")
                    ])
            ]),
        residentBytes: 18_893_225_984,
        minimumMemoryBytes: 32 * gibibyte)

    public static let all: [LLMModel] = [qwen3Small, qwen3Large]

    public static let defaultModel = qwen3Small

    public static func model(id: String) -> LLMModel? {
        all.first { $0.id == id }
    }

    /// The models offered on a Mac with this much memory, smallest first.
    public static func available(physicalMemory: UInt64) -> [LLMModel] {
        all.filter { physicalMemory >= UInt64($0.minimumMemoryBytes) }
    }
}
