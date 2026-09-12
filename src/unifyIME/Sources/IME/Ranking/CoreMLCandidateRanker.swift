import CoreML
import Foundation

struct CoreMLCandidateRanker: UnifiedCandidateRanker {
    private let fallback = HeuristicCandidateRanker()
    private let encoder = RankingFeatureEncoder()
    private let predictionCache = CandidatePredictionCache()
    private let listwiseRanker = CoreMLListwiseCandidateRanker()
    private let model: MLModel?
    private let resolvedModelPath: String?
    private let resolvedComputeUnits: MLComputeUnits?
    private let resolvedInputShape: [NSNumber]
    private let resolvedInputDataType: MLMultiArrayDataType
    private let resolvedOutputDescription: String
    private let featureContract: CandidateFeatureContract
    private let featureContractDescription: String
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
        units.map { score(unit: $0, context: context) }
    }

    func ranked(units: [CandidateUnit], context: CandidateSelectionContext, limit: Int) -> [RankedCandidate] {
        guard limit > 0, !units.isEmpty else { return [] }
        let mode = currentCandidateEngineMode
        let env = ProcessInfo.processInfo.environment
        let onlyAI = mode == .aiDecides || env["UNIFYIME_COREML_ONLY_RANKER"] == "1"
            || env["FASTCHIME_COREML_ONLY_RANKER"] == "1"
        // 純模型模式沒有可用的基礎分數上界，維持完整推論。
        if onlyAI && mode != .traditionalOnly {
            return Array(zip(units, scores(units: units, context: context)).compactMap { unit, score in
                score.isFinite ? RankedCandidate(unit: unit, score: score) : nil
            }.sorted(by: candidateRanksBefore).prefix(limit))
        }
        let base = zip(units, fallback.scores(units: units, context: context)).map {
            RankedCandidate(unit: $0.0, score: $0.1)
        }.sorted(by: candidateRanksBefore)
        guard model != nil, mode != .traditionalOnly else { return Array(base.prefix(limit)) }
        let bound = scoreScale * (mode == .traditionalPreferredAIAssist ? 0.35 : 1.0)
        var selected: [RankedCandidate] = []
        for candidate in base {
            // 只有連理論最高分也嚴格落後第 K 名時才停止；平手仍須評分。
            if selected.count == limit, let last = selected.last,
               candidate.score + bound < last.score { break }
            let value = score(unit: candidate.unit, context: context)
            guard value.isFinite else { continue }
            selected.append(RankedCandidate(unit: candidate.unit, score: value))
            selected.sort(by: candidateRanksBefore)
            if selected.count > limit { selected.removeLast() }
        }
        return selected
    }

    private var scoreScale: Double {
        let configured = ProcessInfo.processInfo.environment["UNIFYIME_COREML_SCORE_SCALE"]
            .flatMap(Double.init) ?? 160.0
        return configured.isFinite ? min(max(0.0, configured), 160.0) : 160.0
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
            "feature_contract=\(featureContractDescription)"
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

/// 每個模型實例獨立保存原始預測；不快取會隨個人紀錄改變的混合分數。
private final class CandidatePredictionCache {
    private let lock = NSLock()
    private var values: [[Double]: Double] = [:]
    private var order: [[Double]] = []
    private let capacity = 512

    func value(for key: [Double]) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: Double, for key: [Double]) {
        lock.lock(); defer { lock.unlock() }
        guard values[key] == nil else { return }
        if order.count >= capacity { values.removeValue(forKey: order.removeFirst()) }
        order.append(key)
        values[key] = value
    }
}
