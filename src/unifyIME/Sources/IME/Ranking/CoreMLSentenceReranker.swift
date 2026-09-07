import CoreML
import Foundation

struct CoreMLSentenceReranker: UnifiedSentenceReranker {
    private let fallback = HeuristicSentenceReranker()
    private let encoder = SentenceFeatureEncoder()
    private let model: MLModel?
    let isModelLoaded: Bool

    init(modelName: String = "SentenceRanker") {
        let env = ProcessInfo.processInfo.environment
        if env["UNIFYIME_DISABLE_COREML_SENTENCE_RERANKER"] == "1" || env["FASTCHIME_DISABLE_COREML_SENTENCE_RERANKER"] == "1" {
            model = nil
        } else {
            let url = Self.resolveExternalModelURL(modelName: modelName)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = url.flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
        }
        isModelLoaded = model != nil
    }

    func score(path: SentenceCandidatePath, context: SentenceRerankerContext) -> Double {
        let heuristicScore = fallback.score(path: path, context: context)
        guard let model else { return heuristicScore }
        let vector = encoder.encode(path: path, context: context)
        do {
            let input = try MLMultiArray(shape: [NSNumber(value: vector.count)], dataType: .float32)
            for (index, value) in vector.enumerated() {
                input[index] = NSNumber(value: Float(value))
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: input)])
            let output = try model.prediction(from: provider)
            if let score = CoreMLScoreReader.scalar(from: output) {
                return heuristicScore + score * 200.0
            }
        } catch {
            return heuristicScore
        }
        return heuristicScore
    }

    func debugStatus() -> String {
        let processEnv = ProcessInfo.processInfo.environment
        let disabled = processEnv["UNIFYIME_DISABLE_COREML_SENTENCE_RERANKER"] == "1"
            || processEnv["FASTCHIME_DISABLE_COREML_SENTENCE_RERANKER"] == "1"
        return [
            "coreml_disabled=\(disabled)",
            "model_loaded=\(isModelLoaded)",
            "feature_dimension=\(SentenceFeatureEncoder.expectedDimension)"
        ].joined(separator: "\n")
    }

    private static func resolveExternalModelURL(modelName: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let explicitModelPath = env["UNIFYIME_SENTENCE_RERANKER_MODEL_PATH"] ?? env["FASTCHIME_SENTENCE_RERANKER_MODEL_PATH"]
        if let explicitPath = explicitModelPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let candidatePaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/UnifyIME/Models/\(modelName).mlmodelc"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".fastchime/Models/\(modelName).mlmodelc"),
        ]
        for url in candidatePaths where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}
