import CoreML
import Foundation

private struct BenchmarkResult {
    let mode: String
    let loadMilliseconds: Double
    let meanMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let iterations: Int
}

private func percentile(_ sorted: [Double], fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
    return sorted[index]
}

private func makeArray(
    shape: [NSNumber],
    dataType: MLMultiArrayDataType,
    value: (Int) -> NSNumber
) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape, dataType: dataType)
    for index in 0..<array.count {
        array[index] = value(index)
    }
    return array
}

@available(macOS 14.4, *)
private func benchmark(
    modelURL: URL,
    mode: String,
    computeUnits: MLComputeUnits,
    warmups: Int,
    iterations: Int
) throws -> BenchmarkResult {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits
    configuration.optimizationHints.reshapeFrequency = .infrequent
    if #available(macOS 15.0, *) {
        configuration.optimizationHints.specializationStrategy = .fastPrediction
    }
    let loadStart = DispatchTime.now().uptimeNanoseconds
    let model = try MLModel(contentsOf: modelURL, configuration: configuration)
    let loadEnd = DispatchTime.now().uptimeNanoseconds

    func constraint(_ name: String) throws -> MLMultiArrayConstraint {
        guard let value = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint else {
            throw NSError(
                domain: "FastChIMEListwiseBenchmark",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "missing multi-array input \(name)"]
            )
        }
        return value
    }

    let tokenIDsConstraint = try constraint("token_ids")
    let tokenTypesConstraint = try constraint("token_types")
    let numericConstraint = try constraint("numeric_features")
    let maskConstraint = try constraint("candidate_mask")
    let tokenIDs = try makeArray(
        shape: tokenIDsConstraint.shape,
        dataType: tokenIDsConstraint.dataType
    ) { index in
        NSNumber(value: Int32(8 + (index * 131) % 16_000))
    }
    let tokenTypes = try makeArray(
        shape: tokenTypesConstraint.shape,
        dataType: tokenTypesConstraint.dataType
    ) { index in
        NSNumber(value: Int32(1 + (index / 8) % 5))
    }
    let numeric = try makeArray(
        shape: numericConstraint.shape,
        dataType: numericConstraint.dataType
    ) { index in
        NSNumber(value: Float(index % 19) / 19.0)
    }
    let mask = try makeArray(
        shape: maskConstraint.shape,
        dataType: maskConstraint.dataType
    ) { _ in NSNumber(value: Float(1.0)) }
    let provider = try MLDictionaryFeatureProvider(
        dictionary: [
            "token_ids": MLFeatureValue(multiArray: tokenIDs),
            "token_types": MLFeatureValue(multiArray: tokenTypes),
            "numeric_features": MLFeatureValue(multiArray: numeric),
            "candidate_mask": MLFeatureValue(multiArray: mask),
        ]
    )

    for _ in 0..<warmups {
        _ = try model.prediction(from: provider)
    }
    var timings: [Double] = []
    timings.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try model.prediction(from: provider)
        let end = DispatchTime.now().uptimeNanoseconds
        timings.append(Double(end - start) / 1_000_000.0)
    }
    let sorted = timings.sorted()
    return BenchmarkResult(
        mode: mode,
        loadMilliseconds: Double(loadEnd - loadStart) / 1_000_000.0,
        meanMilliseconds: timings.reduce(0, +) / Double(max(1, timings.count)),
        medianMilliseconds: percentile(sorted, fraction: 0.5),
        p95Milliseconds: percentile(sorted, fraction: 0.95),
        iterations: iterations
    )
}

@main
struct ListwiseCoreMLBenchmark {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: benchmark_listwise_coreml <model.mlmodelc> [iterations]\n", stderr)
            exit(2)
        }
        guard #available(macOS 14.4, *) else {
            fputs("benchmark requires macOS 14.4 or newer\n", stderr)
            exit(2)
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let iterations = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 100
        let modes: [(String, MLComputeUnits)] = [
            ("cpu", .cpuOnly),
            ("cpu_ane", .cpuAndNeuralEngine),
            ("all", .all),
        ]
        do {
            print("available_devices=\(MLComputeDevice.allComputeDevices.map(\.description).joined(separator: ","))")
            for (mode, units) in modes {
                let result = try benchmark(
                    modelURL: modelURL,
                    mode: mode,
                    computeUnits: units,
                    warmups: 20,
                    iterations: iterations
                )
                print(
                    "mode=\(result.mode) load_ms=\(String(format: "%.3f", result.loadMilliseconds)) "
                    + "mean_ms=\(String(format: "%.3f", result.meanMilliseconds)) "
                    + "median_ms=\(String(format: "%.3f", result.medianMilliseconds)) "
                    + "p95_ms=\(String(format: "%.3f", result.p95Milliseconds)) "
                    + "iterations=\(result.iterations)"
                )
            }
        } catch {
            fputs("benchmark_error=\(error)\n", stderr)
            exit(1)
        }
    }
}
