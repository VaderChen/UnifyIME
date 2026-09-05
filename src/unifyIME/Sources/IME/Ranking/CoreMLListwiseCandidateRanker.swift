import CoreML
import Foundation

struct CoreMLListwiseCandidateRanker {
    private struct ArrayContract {
        let shape: [NSNumber]
        let dataType: MLMultiArrayDataType

        var integerShape: [Int] { shape.map(\.intValue) }
    }

    private final class ResidualCache {
        private let lock = NSLock()
        private let capacity: Int
        private var values: [UInt64: [Double]] = [:]
        private var order: [UInt64] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        func value(for key: UInt64) -> [Double]? {
            lock.lock()
            defer { lock.unlock() }
            guard let value = values[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }

        func insert(_ value: [Double], for key: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            values[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > capacity {
                let evicted = order.removeFirst()
                values.removeValue(forKey: evicted)
            }
        }
    }

    private let encoder = ListwiseFeatureEncoder()
    private let residualCache = ResidualCache(capacity: 2_048)
    private let model: MLModel?
    private let modelPath: String?
    private var tokenIDsContract: ArrayContract
    private var tokenTypesContract: ArrayContract
    private var numericContract: ArrayContract
    private var maskContract: ArrayContract
    private let outputShape: [Int]
    private let statusReason: String

    let isModelLoaded: Bool

    init(modelName: String = "ListwiseCandidateRanker") {
        let defaults = Self.defaultContracts
        tokenIDsContract = defaults.tokenIDs
        tokenTypesContract = defaults.tokenTypes
        numericContract = defaults.numeric
        maskContract = defaults.mask

        let environment = ProcessInfo.processInfo.environment
        let disabled = environment["UNIFYIME_DISABLE_COREML_LISTWISE_RANKER"] == "1"
            || environment["FASTCHIME_DISABLE_COREML_LISTWISE_RANKER"] == "1"
        guard !disabled else {
            model = nil
            modelPath = nil
            outputShape = [1, ListwiseEncodedInput.maxCandidates]
            statusReason = "disabled"
            isModelLoaded = false
            return
        }

        let url = Self.resolveModelURL(modelName: modelName)
        let configuration = MLModelConfiguration()
        // This model is accepted for runtime only after its Compute Plan shows
        // that the Transformer heavy ops prefer ANE.  Do not allow GPU use in
        // the IME hot path.
        configuration.computeUnits = .cpuAndNeuralEngine
        if #available(macOS 14.4, *) {
            configuration.optimizationHints.reshapeFrequency = .infrequent
        }
        if #available(macOS 15.0, *) {
            configuration.optimizationHints.specializationStrategy = .fastPrediction
        }
        let loaded = url.flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
        guard let loaded else {
            model = nil
            modelPath = nil
            outputShape = [1, ListwiseEncodedInput.maxCandidates]
            statusReason = url == nil ? "model_missing" : "model_load_failed"
            isModelLoaded = false
            return
        }

        guard
            let tokenIDs = Self.contract(named: "token_ids", model: loaded),
            let tokenTypes = Self.contract(named: "token_types", model: loaded),
            let numeric = Self.contract(named: "numeric_features", model: loaded),
            let mask = Self.contract(named: "candidate_mask", model: loaded),
            tokenIDs.integerShape == [1, ListwiseEncodedInput.maxCandidates, ListwiseEncodedInput.sequenceLength],
            tokenTypes.integerShape == [1, ListwiseEncodedInput.maxCandidates, ListwiseEncodedInput.sequenceLength],
            numeric.integerShape == [1, ListwiseEncodedInput.maxCandidates, ListwiseEncodedInput.numericDimension],
            mask.integerShape == [1, ListwiseEncodedInput.maxCandidates],
            let outputConstraint = loaded.modelDescription
                .outputDescriptionsByName["residual_scores"]?.multiArrayConstraint,
            outputConstraint.shape.map(\.intValue) == [1, ListwiseEncodedInput.maxCandidates]
        else {
            model = nil
            modelPath = nil
            outputShape = [1, ListwiseEncodedInput.maxCandidates]
            statusReason = "invalid_model_contract"
            isModelLoaded = false
            return
        }

        self.tokenIDsContract = tokenIDs
        self.tokenTypesContract = tokenTypes
        numericContract = numeric
        maskContract = mask
        model = loaded
        modelPath = url?.path
        outputShape = outputConstraint.shape.map(\.intValue)
        statusReason = "ready"
        isModelLoaded = true
    }

    func scores(
        units: [CandidateUnit],
        context: CandidateSelectionContext,
        heuristicScores: [Double]
    ) -> [Double]? {
        guard let model, !units.isEmpty, heuristicScores.count == units.count else { return nil }
        let mode = currentCandidateEngineMode
        if mode == .traditionalOnly { return heuristicScores }
        let encoded = encoder.encode(units: units, context: context)
        let cacheKey = Self.cacheKey(for: encoded)
        let residualValues: [Double]
        if let cached = residualCache.value(for: cacheKey) {
            residualValues = cached
        } else {
            do {
                residualValues = try predictResiduals(model: model, encoded: encoded)
            } catch {
                return nil
            }
            residualCache.insert(residualValues, for: cacheKey)
        }
        let environment = ProcessInfo.processInfo.environment
        let configuredScale = environment["UNIFYIME_LISTWISE_RESIDUAL_SCALE"]
            .flatMap(Double.init) ?? 0.5
        let modeScale: Double
        switch mode {
        case .aiPreferredTraditionalAssist:
            modeScale = configuredScale
        case .traditionalPreferredAIAssist:
            modeScale = configuredScale * 0.35
        case .aiDecides:
            modeScale = configuredScale
        case .traditionalOnly:
            modeScale = 0
        }
        let outputOnly = environment["UNIFYIME_COREML_ONLY_RANKER"] == "1"
            || environment["FASTCHIME_COREML_ONLY_RANKER"] == "1"
            || mode == .aiDecides
        return units.indices.map { index in
            if index >= ListwiseEncodedInput.maxCandidates {
                return heuristicScores[index]
            }
            let residual = residualValues[index]
            guard residual.isFinite else { return heuristicScores[index] }
            let scaledResidual = residual * modeScale
            return outputOnly ? scaledResidual : heuristicScores[index] + scaledResidual
        }
    }

    private func predictResiduals(
        model: MLModel,
        encoded: ListwiseEncodedInput
    ) throws -> [Double] {
        let tokenIDs = try Self.makeArray(
            contract: tokenIDsContract,
            integers: encoded.tokenIDs
        )
        let tokenTypes = try Self.makeArray(
            contract: tokenTypesContract,
            integers: encoded.tokenTypes
        )
        let numeric = try Self.makeArray(
            contract: numericContract,
            floats: encoded.numericFeatures
        )
        let mask = try Self.makeArray(
            contract: maskContract,
            floats: encoded.candidateMask
        )
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [
                "token_ids": MLFeatureValue(multiArray: tokenIDs),
                "token_types": MLFeatureValue(multiArray: tokenTypes),
                "numeric_features": MLFeatureValue(multiArray: numeric),
                "candidate_mask": MLFeatureValue(multiArray: mask),
            ]
        )
        let prediction = try model.prediction(from: provider)
        guard let residuals = prediction.featureValue(for: "residual_scores")?.multiArrayValue,
              residuals.count >= ListwiseEncodedInput.maxCandidates else {
            throw NSError(
                domain: "FastChIMEListwiseRanker",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing residual_scores output"]
            )
        }
        return (0..<ListwiseEncodedInput.maxCandidates).map {
            Double(truncating: residuals[$0])
        }
    }

    func debugStatus() -> String {
        let scale = ProcessInfo.processInfo.environment["UNIFYIME_LISTWISE_RESIDUAL_SCALE"]
            .flatMap(Double.init) ?? 0.5
        return [
            "listwise_model_loaded=\(isModelLoaded)",
            "listwise_status=\(statusReason)",
            "listwise_model_path=\(modelPath ?? "missing")",
            "listwise_compute_units=cpu_ane",
            "listwise_ane_required=true",
            "listwise_token_shape=\(tokenIDsContract.integerShape)",
            "listwise_numeric_shape=\(numericContract.integerShape)",
            "listwise_output_shape=\(outputShape)",
            "listwise_residual_scale=\(scale)",
        ].joined(separator: "\n")
    }

    private static var defaultContracts: (
        tokenIDs: ArrayContract,
        tokenTypes: ArrayContract,
        numeric: ArrayContract,
        mask: ArrayContract
    ) {
        (
            ArrayContract(
                shape: [1, NSNumber(value: ListwiseEncodedInput.maxCandidates), NSNumber(value: ListwiseEncodedInput.sequenceLength)],
                dataType: .int32
            ),
            ArrayContract(
                shape: [1, NSNumber(value: ListwiseEncodedInput.maxCandidates), NSNumber(value: ListwiseEncodedInput.sequenceLength)],
                dataType: .int32
            ),
            ArrayContract(
                shape: [1, NSNumber(value: ListwiseEncodedInput.maxCandidates), NSNumber(value: ListwiseEncodedInput.numericDimension)],
                dataType: .float32
            ),
            ArrayContract(
                shape: [1, NSNumber(value: ListwiseEncodedInput.maxCandidates)],
                dataType: .float32
            )
        )
    }

    private static func contract(named name: String, model: MLModel) -> ArrayContract? {
        guard let constraint = model.modelDescription
            .inputDescriptionsByName[name]?.multiArrayConstraint else { return nil }
        return ArrayContract(shape: constraint.shape, dataType: constraint.dataType)
    }

    private static func makeArray(
        contract: ArrayContract,
        integers: [Int32]
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: contract.shape, dataType: contract.dataType)
        guard array.count == integers.count else { return array }
        for index in integers.indices {
            array[index] = NSNumber(value: integers[index])
        }
        return array
    }

    private static func cacheKey(for encoded: ListwiseEncodedInput) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 1_099_511_628_211
        }
        for value in encoded.tokenIDs {
            mix(UInt64(UInt32(bitPattern: value)))
        }
        for value in encoded.tokenTypes {
            mix(UInt64(UInt32(bitPattern: value)))
        }
        for value in encoded.numericFeatures {
            mix(UInt64(value.bitPattern))
        }
        for value in encoded.candidateMask {
            mix(UInt64(value.bitPattern))
        }
        return hash
    }

    private static func makeArray(
        contract: ArrayContract,
        floats: [Float]
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: contract.shape, dataType: contract.dataType)
        guard array.count == floats.count else { return array }
        for index in floats.indices {
            array[index] = NSNumber(value: floats[index])
        }
        return array
    }

    private static func resolveModelURL(modelName: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let explicit = environment["UNIFYIME_LISTWISE_RANKER_MODEL_PATH"]
            ?? environment["FASTCHIME_LISTWISE_RANKER_MODEL_PATH"]
        if let explicit, !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/UnifyIME/Models/\(modelName).mlmodelc"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".fastchime/Models/\(modelName).mlmodelc"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Models/\(modelName).mlmodelc"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
