import CoreML
import Foundation

struct CoreMLCandidateRanker: UnifiedCandidateRanker {
    private let fallback = HeuristicCandidateRanker()
    private let encoder = RankingFeatureEncoder()
    private let predictionCache = BoundedLRUCache<[Double], Double>(capacity: 512)
    private let configuredOutputOnly: Bool
    private let scoreScale: Double
    private let model: MLModel?
    private let resolvedModelPath: String?
    private let resolvedComputeUnits: MLComputeUnits?
    private let resolvedInputShape: [NSNumber]
    private let resolvedInputDataType: MLMultiArrayDataType
    private let resolvedOutputDescription: String
    private let featureContract: CandidateFeatureContract
    private let featureContractDescription: String
    let isModelLoaded: Bool

    // Listwise 分數依賴候選集合，尚未符合共用句子評分契約；保留離線實驗程式。
    var isListwiseRerankingAvailable: Bool { false }

    init(modelName: String = "CandidateRanker") {
        let env = ProcessInfo.processInfo.environment
        configuredOutputOnly = env["UNIFYIME_COREML_ONLY_RANKER"] == "1"
            || env["FASTCHIME_COREML_ONLY_RANKER"] == "1"
        let scale = env["UNIFYIME_COREML_SCORE_SCALE"].flatMap(Double.init) ?? 160.0
        scoreScale = scale.isFinite ? min(max(0.0, scale), 160.0) : 160.0
        if env["UNIFYIME_DISABLE_COREML_RANKER"] == "1" || env["FASTCHIME_DISABLE_COREML_RANKER"] == "1" {
            model = nil
            resolvedModelPath = nil
            resolvedComputeUnits = nil
            resolvedInputShape = [1, NSNumber(value: RankingFeatureVector.expectedDimension)]
            resolvedInputDataType = .float32
            resolvedOutputDescription = "disabled"
            featureContract = .legacySegmentsV1
            featureContractDescription = "disabled"
        } else {
            let url = Self.resolveExternalModelURL(modelName: modelName)
            let configuration = Self.makeModelConfiguration()
            resolvedComputeUnits = configuration.computeUnits
            let loadedModel = url.flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
            let metadata = loadedModel?.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            let declaredContract = metadata?["unifyime.feature_contract"]
            // 已發布且未標記的舊模型採舊片段格式；不將相同維度視為新格式相容。
            let contractName = declaredContract ?? CandidateFeatureContract.legacySegmentsV1.rawValue
            let parsedContract = CandidateFeatureContract(rawValue: contractName)
            featureContract = parsedContract ?? .legacySegmentsV1
            featureContractDescription = declaredContract ?? "legacy_segments_v1 (metadata_missing)"
            let constraint = loadedModel?.modelDescription
                .inputDescriptionsByName["features"]?.multiArrayConstraint
            let shape = constraint?.shape ?? [1, NSNumber(value: RankingFeatureVector.expectedDimension)]
            let featureCount = shape.map(\.intValue).reduce(1, *)
            if featureCount == RankingFeatureVector.expectedDimension, parsedContract != nil {
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
                resolvedOutputDescription = parsedContract == nil
                    ? "unsupported_feature_contract" : "invalid_input_dimension=\(featureCount)"
            }
        }
        isModelLoaded = model != nil
    }

    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let heuristicScore = fallback.score(unit: unit, context: context)
        return score(unit: unit, context: context, heuristicScore: heuristicScore,
            engineMode: currentCandidateEngineMode)
    }

    private func score(unit: CandidateUnit, context: CandidateSelectionContext,
                       heuristicScore: Double, engineMode: CandidateEngineMode) -> Double {
        let coreMLOutputOnly = configuredOutputOnly || engineMode == .aiDecides
        if engineMode == .traditionalOnly {
            return heuristicScore
        }
        guard let model else {
            return heuristicScore
        }

        let vector = encoder.encode(unit: unit, context: context, contract: featureContract)
        if let rawScore = predictionCache.value(for: vector.values) {
            return blendedScore(heuristicScore: heuristicScore, aiScore: rawScore,
                mode: engineMode, coreMLOutputOnly: coreMLOutputOnly)
        }
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
                predictionCache.store(rawScore, for: vector.values)
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
        // 有模型時同樣共用批次詞頻查詢，且沿用已算出的基礎分數。
        let mode = currentCandidateEngineMode
        let base = fallback.scores(units: units, context: context)
        if model == nil || mode == .traditionalOnly {
            return base
        }
        return zip(units, base).map { unit, heuristicScore in
            score(unit: unit, context: context, heuristicScore: heuristicScore, engineMode: mode)
        }
    }

    func ranked(units: [CandidateUnit], context: CandidateSelectionContext, limit: Int) -> [RankedCandidate] {
        guard limit > 0, !units.isEmpty else { return [] }
        let mode = currentCandidateEngineMode
        guard model != nil, mode != .traditionalOnly else {
            return fallback.ranked(units: units, context: context, limit: limit)
        }
        let onlyAI = mode == .aiDecides || configuredOutputOnly
        // 純模型模式沒有可用的基礎分數上界，維持完整推論。
        if onlyAI && mode != .traditionalOnly {
            var selection = CandidateTopK(limit: min(limit, units.count))
            for (unit, value) in zip(units, scores(units: units, context: context)) {
                selection.insert(RankedCandidate(unit: unit, score: value))
            }
            return selection.ranked()
        }
        let base = zip(units, fallback.scores(units: units, context: context)).map {
            RankedCandidate(unit: $0.0, score: $0.1)
        }.sorted(by: candidateRanksBefore)
        let bound = scoreScale * (mode == .traditionalPreferredAIAssist ? 0.35 : 1.0)
        var selected = CandidateTopK(limit: min(limit, units.count))
        for candidate in base {
            // 只有連理論最高分也嚴格落後第 K 名時才停止；平手仍須評分。
            if let cutoff = selected.cutoffScore, candidate.score + bound < cutoff { break }
            let value = score(unit: candidate.unit, context: context,
                heuristicScore: candidate.score, engineMode: mode)
            guard value.isFinite else { continue }
            selected.insert(RankedCandidate(unit: candidate.unit, score: value))
        }
        return selected.ranked()
    }

    private func blendedScore(
        heuristicScore: Double,
        aiScore: Double,
        mode: CandidateEngineMode,
        coreMLOutputOnly: Bool
    ) -> Double {
        let scaledAI = tanh(aiScore / 3.0) * scoreScale
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
            "output=\(resolvedOutputDescription)",
            "feature_contract=\(featureContractDescription)",
            "listwise_model_loaded=false",
            "listwise_runtime_enabled=false",
            "listwise_status=disabled_pending_sentence_scoring_contract"
        ]).joined(separator: "\n")
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
