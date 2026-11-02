import Foundation

/// One file of a model package: its path inside the package, its size and its SHA-256.
struct ModelFile: Hashable, Sendable {
    let path: String
    let size: Int
    let sha256: String
}

/// One repository on Hugging Face at a pinned revision, with the files taken from it. `into` is the folder
/// inside the model package the files go to ("" for the package root).
struct ModelSource: Hashable, Sendable {
    let repository: String
    let revision: String
    let into: String
    let files: [ModelFile]

    func url(for file: ModelFile) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath = "/" + repository + "/resolve/" + revision + "/" + file.path
        return components.url
    }
}

/// A downloadable speech model package: everything the engine needs, and nothing it would download by
/// itself (spec: `ModelManager`). The catalog is compiled in, so a download can only ever fetch these files
/// from these revisions, and every file is checked against its SHA-256.
struct ModelPackage: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let license: String
    let attribution: String
    let sources: [ModelSource]

    var files: [(source: ModelSource, file: ModelFile)] {
        sources.flatMap { source in source.files.map { (source, $0) } }
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.file.size } }

    /// Where a file lives inside the package folder.
    func relativePath(of file: ModelFile, in source: ModelSource) -> String {
        source.into.isEmpty ? file.path : source.into + "/" + file.path
    }
}

enum ModelCatalog {
    /// Parakeet Ultra (Core ML) with the Silero VAD model, ADR 0003.
    static let parakeetUltra = ModelPackage(
        id: "parakeet-ultra",
        title: "Parakeet Ultra",
        license: "CC-BY-4.0",
        attribution:
            "Parakeet Ultra by moondream, a post-trained NVIDIA Parakeet TDT 0.6B v3; Core ML conversion by FluidInference. CC BY 4.0.",
        sources: [
            ModelSource(
                repository: "FluidInference/parakeet-ultra-coreml",
                revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
                into: "",
                files: [
                    ModelFile(
                        path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
                    ModelFile(
                        path: "Decoder.mlmodelc/coremldata.bin", size: 560,
                        sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
                    ModelFile(
                        path: "Decoder.mlmodelc/model.mil", size: 13110,
                        sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                    ModelFile(
                        path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992,
                        sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
                    ModelFile(
                        path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
                    ModelFile(
                        path: "Encoder.mlmodelc/coremldata.bin", size: 514,
                        sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
                    ModelFile(
                        path: "Encoder.mlmodelc/model.mil", size: 1_002_653,
                        sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
                    ModelFile(
                        path: "Encoder.mlmodelc/weights/weight.bin", size: 594_211_328,
                        sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
                    ModelFile(
                        path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
                    ModelFile(
                        path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592,
                        sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
                    ModelFile(
                        path: "JointDecisionv3.mlmodelc/model.mil", size: 11777,
                        sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                    ModelFile(
                        path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764,
                        sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
                    ModelFile(
                        path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                    ModelFile(
                        path: "Preprocessor.mlmodelc/coremldata.bin", size: 486,
                        sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                    ModelFile(
                        path: "Preprocessor.mlmodelc/metadata.json", size: 2841,
                        sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                    ModelFile(
                        path: "Preprocessor.mlmodelc/model.mil", size: 28181,
                        sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                    ModelFile(
                        path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072,
                        sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                    ModelFile(
                        path: "parakeet_vocab.json", size: 151122,
                        sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
                ]),
            ModelSource(
                repository: "FluidInference/silero-vad-coreml",
                revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
                into: "vad",
                files: [
                    ModelFile(
                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
                    ModelFile(
                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin", size: 625,
                        sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
                    ModelFile(
                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json", size: 3335,
                        sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
                    ModelFile(
                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", size: 176918,
                        sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
                    ModelFile(
                        path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin", size: 882304,
                        sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
                ]),
        ])

    static let all: [ModelPackage] = [parakeetUltra]

    static func package(id: String) -> ModelPackage? {
        all.first { $0.id == id }
    }

    /// The only hosts a model download may talk to or be redirected to (spec: `LoopbackPolicy`).
    static func isAllowedDownloadHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "huggingface.co" || host == "cdn-lfs.hf.co" || host == "cas-bridge.xethub.hf.co" {
            return true
        }
        return host.hasPrefix("cdn-lfs-") && host.hasSuffix(".hf.co") && !host.contains("..")
    }
}
