import CoreML
import Foundation

struct CoreMLCandidateRanker: UnifiedCandidateRanker {
    private let fallback = HeuristicCandidateRanker()
    private let encoder = RankingFeatureEncoder()
    private let listwiseRanker = CoreMLListwiseCandidateRanker()
    private let model: MLModel?
    private let resolvedModelPath: String?
    private let resolvedComputeUnits: MLComputeUnits?
    private let resolvedInputShape: [NSNumber]
    private let resolvedInputDataType: MLMultiArrayDataType
    private let resolvedOutputDescription: String
    let isModelLoaded: Bool

    var isListwiseRerankingAvailable: Bool { listwiseRanker.isModelLoaded }

    init(modelName: String = "CandidateRanker") {
        let env = ProcessInfo.processInfo.environment
        if env["UNIFYIME_DISABLE_COREML_RANKER"] == "1" || env["FASTCHIME_DISABLE_COREML_RANKER"] == "1" {
            model = nil
            resolvedModelPath = nil
            resolvedComputeUnits = nil
            resolvedInputShape = [1, NSNumber(value: RankingFeatureVector.expectedDimension)]
            resolvedInputDataType = .float32
            resolvedOutputDescription = "disabled"
        } else {
            let url = Self.resolveExternalModelURL(modelName: modelName)
            let configuration = Self.makeModelConfiguration()
            resolvedComputeUnits = configuration.computeUnits
            let loadedModel = url.flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
            let constraint = loadedModel?.modelDescription
                .inputDescriptionsByName["features"]?.multiArrayConstraint
            let shape = constraint?.shape ?? [1, NSNumber(value: RankingFeatureVector.expectedDimension)]
            let featureCount = shape.map(\.intValue).reduce(1, *)
            if featureCount == RankingFeatureVector.expectedDimension {
                model = loadedModel
                resolvedModelPath = loadedModel == nil ? nil : url?.path
                resolvedInputShape = shape
                resolvedInputDataType = constraint?.dataType ?? .float32
                resolvedOutputDescription = loadedModel.map {
                    CoreMLScoreReader.outputDescription(model: $0)
                } ?? "missing"
            } else {
                model = nil
                resolvedModelPath = nil
                resolvedInputShape = [1, NSNumber(value: RankingFeatureVector.expectedDimension)]
                resolvedInputDataType = .float32
                resolvedOutputDescription = "invalid_input_dimension=\(featureCount)"
            }
        }
        isModelLoaded = model != nil
    }

    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let heuristicScore = fallback.score(unit: unit, context: context)
        let engineMode = currentCandidateEngineMode
        let processEnv = ProcessInfo.processInfo.environment
        let coreMLOutputOnly = processEnv["UNIFYIME_COREML_ONLY_RANKER"] == "1"
            || processEnv["FASTCHIME_COREML_ONLY_RANKER"] == "1"
            || engineMode == .aiDecides
        if engineMode == .traditionalOnly {
            return heuristicScore
        }
        guard let model else {
            return heuristicScore
        }

        let vector = encoder.encode(unit: unit, context: context)
        do {
            let input = try MLMultiArray(
                shape: resolvedInputShape,
                dataType: resolvedInputDataType
            )
            for (index, value) in vector.values.enumerated() {
                input[index] = NSNumber(value: value)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: input)])
            let output = try model.prediction(from: provider)
            if let rawScore = CoreMLScoreReader.scalar(from: output) {
                return blendedScore(
                    heuristicScore: heuristicScore,
                    aiScore: rawScore,
                    mode: engineMode,
                    coreMLOutputOnly: coreMLOutputOnly
                )
            }
        } catch {
            return heuristicScore
        }

        return heuristicScore
    }

    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double] {
        guard !units.isEmpty else { return [] }
        let heuristicScores = units.map { fallback.score(unit: $0, context: context) }
        if let listwiseScores = listwiseRanker.scores(
            units: units,
            context: context,
            heuristicScores: heuristicScores
        ) {
            return listwiseScores
        }
        return units.map { score(unit: $0, context: context) }
    }

    private func blendedScore(
        heuristicScore: Double,
        aiScore: Double,
        mode: CandidateEngineMode,
        coreMLOutputOnly: Bool
    ) -> Double {
        let processEnv = ProcessInfo.processInfo.environment
        let configuredScale = processEnv["UNIFYIME_COREML_SCORE_SCALE"]
            .flatMap(Double.init) ?? 160.0
        let scaledAI = tanh(aiScore / 3.0) * configuredScale
        if coreMLOutputOnly {
            return scaledAI
        }
        switch mode {
        case .aiPreferredTraditionalAssist:
            return heuristicScore + scaledAI
        case .traditionalPreferredAIAssist:
            return heuristicScore * 1.0 + scaledAI * 0.35
        case .aiDecides:
            return scaledAI
        case .traditionalOnly:
            return heuristicScore
        }
    }

    func debugStatus() -> String {
        let processEnv = ProcessInfo.processInfo.environment
        let disabled = processEnv["UNIFYIME_DISABLE_COREML_RANKER"] == "1"
            || processEnv["FASTCHIME_DISABLE_COREML_RANKER"] == "1"
        let bundlePath = Bundle.main.bundlePath
        return ([
            "coreml_disabled=\(disabled)",
            "model_loaded=\(isModelLoaded)",
            "bundle=\(bundlePath)",
            "model_path=\(resolvedModelPath ?? "missing")",
            "compute_units=\(resolvedComputeUnits.map(Self.computeUnitDescription(for:)) ?? "n/a")",
            "input_shape=\(resolvedInputShape.map(\.intValue))",
            "output=\(resolvedOutputDescription)"
        ] + [listwiseRanker.debugStatus()]).joined(separator: "\n")
    }

    private static func makeModelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = preferredComputeUnits()
        return configuration
    }

    private static func preferredComputeUnits() -> MLComputeUnits {
        let env = ProcessInfo.processInfo.environment
        let unitsKey = env["UNIFYIME_COREML_COMPUTE_UNITS"] ?? env["FASTCHIME_COREML_COMPUTE_UNITS"]
        switch unitsKey?.lowercased() {
        case "cpu":
            return .cpuOnly
        case "cpu_gpu":
            return .cpuAndGPU
        case "cpu_ane":
            if #available(macOS 13.0, *) {
                return .cpuAndNeuralEngine
            }
            return .all
        case "all":
            return .all
        default:
            return .all
        }
    }

    private static func computeUnitDescription(for units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly:
            return "cpu"
        case .cpuAndGPU:
            return "cpu_gpu"
        case .cpuAndNeuralEngine:
            return "cpu_ane"
        case .all:
            return "all"
        @unknown default:
            return "unknown"
        }
    }

    private static func resolveExternalModelURL(modelName: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let explicitModelPath = env["UNIFYIME_RANKER_MODEL_PATH"] ?? env["FASTCHIME_RANKER_MODEL_PATH"]
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
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Models/\(modelName).mlmodelc"),
        ]

        for url in candidatePaths where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}
