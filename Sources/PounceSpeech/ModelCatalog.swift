import Foundation

/// One file of a model package: its path inside the package, its size and its SHA-256.
public struct ModelFile: Hashable, Sendable {
    public let path: String
    public let size: Int
    public let sha256: String

    public init(path: String, size: Int, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// One repository on Hugging Face at a pinned revision, with the files taken from it. `into` is the folder
/// inside the model package the files go to ("" for the package root).
public struct ModelSource: Hashable, Sendable {
    public let repository: String
    public let revision: String
    public let into: String
    public let files: [ModelFile]
    /// A folder of the repository that is dropped from the local path (the package keeps one model's files at
    /// its root, while the repository holds many).
    public var stripPrefix = ""

    public init(repository: String, revision: String, into: String, files: [ModelFile], stripPrefix: String = "") {
        self.repository = repository
        self.revision = revision
        self.into = into
        self.files = files
        self.stripPrefix = stripPrefix
    }

    /// Where a file goes inside the package, below `into`.
    public func localPath(of file: ModelFile) -> String {
        stripPrefix.isEmpty || !file.path.hasPrefix(stripPrefix)
            ? file.path : String(file.path.dropFirst(stripPrefix.count))
    }

    public func url(for file: ModelFile) -> URL? {
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
public struct ModelPackage: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let license: String
    public let attribution: String
    public let sources: [ModelSource]

    public init(id: String, title: String, license: String, attribution: String, sources: [ModelSource]) {
        self.id = id
        self.title = title
        self.license = license
        self.attribution = attribution
        self.sources = sources
    }

    public var files: [(source: ModelSource, file: ModelFile)] {
        sources.flatMap { source in source.files.map { (source, $0) } }
    }

    public var totalBytes: Int { files.reduce(0) { $0 + $1.file.size } }

    /// Where a file lives inside the package folder.
    public func relativePath(of file: ModelFile, in source: ModelSource) -> String {
        source.into.isEmpty ? source.localPath(of: file) : source.into + "/" + source.localPath(of: file)
    }
}

public enum ModelCatalog {
    /// The Silero voice activity model, part of every package (the recording is cut into speech segments with it).
    public static let sileroVAD = ModelSource(
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
        ])

    /// The Silero model inside a package, relative to the package folder.
    public static let sileroVADPath = "vad/silero-vad-unified-256ms-v6.2.1.mlmodelc"

    /// Parakeet Ultra (Core ML) with the Silero VAD model, ADR 0003.
    public static let parakeetUltra = ModelPackage(
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
            sileroVAD,
        ])

    /// Whisper large-v3-turbo (Core ML, 632 MB build) with the tokenizer WhisperKit needs next to it. WhisperKit
    /// downloads a missing tokenizer by itself, so the tokenizer files are part of the package (ADR 0003).
    public static let whisperLargeV3Turbo = ModelPackage(
        id: "whisper-large-v3-turbo",
        title: "Whisper large-v3-turbo",
        license: "MIT",
        attribution:
            "Whisper by OpenAI (MIT), Core ML conversion by Argmax (MIT); tokenizer files from openai/whisper-large-v3 (Apache-2.0).",
        sources: [
            ModelSource(
                repository: "argmaxinc/whisperkit-coreml",
                revision: "0f63a7800b00dd0226abd051b906c246e1907482",
                into: "",
                files: [
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/analytics/coremldata.bin",
                        size: 243, sha256: "0dd9f529c744ed3c6be67f699588f7aadc4f366b5b7301dc31bd3f199944fbcc"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/coremldata.bin",
                        size: 348, sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/metadata.json",
                        size: 1974, sha256: "2cd0538f90a012de3f07d38669026d527490eff1dcfd2479a81c48206a90f0a2"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/model.mil",
                        size: 7_589_739, sha256: "ef5a252831e61bb91d6547fe1add3d0658895b518d47d70004322b40a2192668"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin",
                        size: 421_968_768, sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin",
                        size: 243, sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/coremldata.bin",
                        size: 329, sha256: "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/metadata.json",
                        size: 1850, sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/model.mil",
                        size: 10143, sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/weights/weight.bin",
                        size: 373376, sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/analytics/coremldata.bin",
                        size: 243, sha256: "4b5119bdc621c3c494f63846dc3ed43852e88826fc3b6345d42272d4b7e67724"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/coremldata.bin",
                        size: 633, sha256: "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/metadata.json",
                        size: 4924, sha256: "e3ce6d83884552ffcc2c34799e8e1211dcda59f1aaea5a79bf988c6cd16abbf0"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/model.mil",
                        size: 217177, sha256: "ebaf8566f367b6465276c3ed57bb99063888fa955b67828585bf19db24c85f56"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/weights/weight.bin",
                        size: 203_199_860, sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin",
                        size: 243, sha256: "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/coremldata.bin",
                        size: 380, sha256: "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/metadata.json",
                        size: 2240, sha256: "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/model.mil",
                        size: 4092, sha256: "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34"),
                    ModelFile(
                        path:
                            "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/weights/weight.bin",
                        size: 12_288_192, sha256: "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/config.json", size: 1149,
                        sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
                    ModelFile(
                        path: "openai_whisper-large-v3-v20240930_turbo_632MB/generation_config.json", size: 2767,
                        sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
                ],
                stripPrefix: "openai_whisper-large-v3-v20240930_turbo_632MB/"),
            ModelSource(
                repository: "openai/whisper-large-v3",
                revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
                into: "",
                files: [
                    ModelFile(
                        path: "tokenizer.json", size: 2_480_617,
                        sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
                    ModelFile(
                        path: "tokenizer_config.json", size: 282843,
                        sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
                ]),
            sileroVAD,
        ])

    /// Speaker diarization (pyannote Community-1, Core ML conversion by FluidInference) for meetings, ADR 0007.
    /// Only the files FluidAudio 0.18.2's offline pipeline loads (`ModelNames.OfflineDiarizer.requiredModels`);
    /// the repository's `PLDA.mlmodelc`, the legacy models and the `.mlpackage` sources are left out. Pinned to the
    /// repository commit below; every SHA-256 is that of the file at the revision (LFS files match the `lfs.oid`
    /// of the tree API, small files were hashed after download; both match the repository's `provenance.json`).
    /// About 21.6 MB in total. The license of these files is CC-BY-4.0 (`NOTICE.md` of the repository, a scope
    /// limited to exactly these artifacts); the attribution is in `Resources/THIRD_PARTY_NOTICES.txt`.
    public static let diarizationCommunity1 = ModelPackage(
        id: "diarization-community-1",
        title: "Speaker diarization (pyannote Community-1)",
        license: "CC-BY-4.0",
        attribution:
            "pyannote speaker-diarization-community-1 (pyannote.audio, CC BY 4.0) with WeSpeaker embeddings and PLDA parameters from BUT Speech@FIT (CC BY 4.0); modified Core ML conversion by FluidInference. CC BY 4.0.",
        sources: [
            ModelSource(
                repository: "FluidInference/speaker-diarization-coreml",
                revision: "7eab74f3463c736418d0eb10296261ae581146c9",
                into: "",
                files: [
                    ModelFile(
                        path: "Embedding.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
                    ModelFile(
                        path: "Embedding.mlmodelc/coremldata.bin", size: 704,
                        sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
                    ModelFile(
                        path: "Embedding.mlmodelc/metadata.json", size: 2818,
                        sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
                    ModelFile(
                        path: "Embedding.mlmodelc/model.mil", size: 78_432,
                        sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
                    ModelFile(
                        path: "Embedding.mlmodelc/weights/weight.bin", size: 13_412_288,
                        sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
                    ModelFile(
                        path: "FBank.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
                    ModelFile(
                        path: "FBank.mlmodelc/coremldata.bin", size: 853,
                        sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
                    ModelFile(
                        path: "FBank.mlmodelc/metadata.json", size: 3409,
                        sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
                    ModelFile(
                        path: "FBank.mlmodelc/model.mil", size: 15_667,
                        sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
                    ModelFile(
                        path: "FBank.mlmodelc/weights/weight.bin", size: 1_776_896,
                        sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
                    ModelFile(
                        path: "PldaRho.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
                    ModelFile(
                        path: "PldaRho.mlmodelc/coremldata.bin", size: 763,
                        sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
                    ModelFile(
                        path: "PldaRho.mlmodelc/metadata.json", size: 2749,
                        sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
                    ModelFile(
                        path: "PldaRho.mlmodelc/model.mil", size: 7613,
                        sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
                    ModelFile(
                        path: "PldaRho.mlmodelc/weights/weight.bin", size: 200_192,
                        sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
                    ModelFile(
                        path: "Segmentation.mlmodelc/analytics/coremldata.bin", size: 243,
                        sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
                    ModelFile(
                        path: "Segmentation.mlmodelc/coremldata.bin", size: 812,
                        sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
                    ModelFile(
                        path: "Segmentation.mlmodelc/metadata.json", size: 3410,
                        sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
                    ModelFile(
                        path: "Segmentation.mlmodelc/model.mil", size: 43_063,
                        sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
                    ModelFile(
                        path: "Segmentation.mlmodelc/weights/weight.bin", size: 5_959_360,
                        sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
                    ModelFile(
                        path: "plda-parameters.json", size: 89_416,
                        sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
                ])
        ])

    /// The files the diarizer loads, relative to the package folder (what `FluidDiarizer` opens).
    public static let diarizationModelNames = [
        "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc",
    ]
    public static let diarizationParametersFile = "plda-parameters.json"

    /// The speech to text packages a user can pick (dictation and meetings). The diarization package is not one of
    /// them: it is not a speech model and never appears in a speech model list.
    public static let all: [ModelPackage] = [parakeetUltra, whisperLargeV3Turbo]

    /// The diarization packages (meetings only).
    public static let diarization: [ModelPackage] = [diarizationCommunity1]

    public static func diarizationPackage(id: String) -> ModelPackage? {
        diarization.first { $0.id == id }
    }

    public static func package(id: String) -> ModelPackage? {
        all.first { $0.id == id }
    }

    /// The only hosts a model download may talk to or be redirected to (spec: `LoopbackPolicy`).
    public static func isAllowedDownloadHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "huggingface.co" || host == "cdn-lfs.hf.co" || host == "cas-bridge.xethub.hf.co" {
            return true
        }
        // Hugging Face's CDN hosts, e.g. `us.aws.cdn.hf.co` (the Xet bridge that the `resolve` URLs redirect to).
        if host.hasSuffix(".cdn.hf.co"), !host.hasPrefix("."), !host.contains("..") { return true }
        return host.hasPrefix("cdn-lfs-") && host.hasSuffix(".hf.co") && !host.contains("..")
    }
}
