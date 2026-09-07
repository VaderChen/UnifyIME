import CoreML
import Foundation

@available(macOS 14.4, *)
private struct DeviceSummary {
    var operationCount = 0
    var estimatedCost = 0.0
    var unsupportedCount = 0
}

@available(macOS 14.4, *)
private func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu:
        return "cpu"
    case .gpu:
        return "gpu"
    case .neuralEngine:
        return "ane"
    @unknown default:
        return "unknown"
    }
}

@available(macOS 14.4, *)
private func collectOperations(
    from block: MLModelStructure.Program.Block,
    into operations: inout [MLModelStructure.Program.Operation]
) {
    for operation in block.operations {
        operations.append(operation)
        for nestedBlock in operation.blocks {
            collectOperations(from: nestedBlock, into: &operations)
        }
    }
}

@available(macOS 14.4, *)
private func inspect(modelURL: URL) async throws {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    if #available(macOS 15.0, *) {
        configuration.optimizationHints.specializationStrategy = .fastPrediction
    }
    configuration.optimizationHints.reshapeFrequency = .infrequent

    let plan = try await MLComputePlan.load(
        contentsOf: modelURL,
        configuration: configuration
    )
    guard case let .program(program) = plan.modelStructure else {
        throw NSError(
            domain: "FastChIMEComputePlan",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "model is not an ML Program"]
        )
    }

    var operations: [MLModelStructure.Program.Operation] = []
    for function in program.functions.values {
        collectOperations(from: function.block, into: &operations)
    }

    var summaries: [String: DeviceSummary] = [:]
    var operatorSummaries: [String: [String: Int]] = [:]
    var heavySummaries: [String: Int] = [:]
    var totalEstimatedCost = 0.0
    var detailedRows: [(Double, String)] = []
    for operation in operations {
        let cost = plan.estimatedCost(of: operation)?.weight ?? 0.0
        totalEstimatedCost += cost
        guard let usage = plan.deviceUsage(for: operation) else {
            var summary = summaries["unassigned", default: DeviceSummary()]
            summary.operationCount += 1
            summary.estimatedCost += cost
            summary.unsupportedCount += 1
            summaries["unassigned"] = summary
            continue
        }
        let preferred = deviceName(usage.preferred)
        var summary = summaries[preferred, default: DeviceSummary()]
        summary.operationCount += 1
        summary.estimatedCost += cost
        summaries[preferred] = summary
        operatorSummaries[operation.operatorName, default: [:]][preferred, default: 0] += 1
        let isHeavy = operation.operatorName.contains("linear")
            || operation.operatorName.contains("matmul")
            || operation.operatorName.contains("conv")
        if isHeavy {
            heavySummaries[preferred, default: 0] += 1
        }
        let supported = usage.supported.map(deviceName).joined(separator: ",")
        let formattedCost = String(format: "%.8f", cost)
        detailedRows.append((cost, "op=\(operation.operatorName) preferred=\(preferred) supported=\(supported) cost=\(formattedCost)"))
    }

    print("compute_units=cpu_and_ane")
    print("operations=\(operations.count)")
    print("estimated_cost_total=\(String(format: "%.8f", totalEstimatedCost))")
    for key in ["ane", "cpu", "gpu", "unknown", "unassigned"] {
        let summary = summaries[key, default: DeviceSummary()]
        let ratio = totalEstimatedCost > 0 ? summary.estimatedCost / totalEstimatedCost : 0.0
        let formattedCost = String(format: "%.8f", summary.estimatedCost)
        let formattedRatio = String(format: "%.6f", ratio)
        print("device=\(key) operations=\(summary.operationCount) cost=\(formattedCost) ratio=\(formattedRatio)")
    }
    let heavyTotal = heavySummaries.values.reduce(0, +)
    print("heavy_operations=\(heavyTotal) ane=\(heavySummaries["ane", default: 0]) cpu=\(heavySummaries["cpu", default: 0]) gpu=\(heavySummaries["gpu", default: 0])")
    print("operator_device_counts:")
    for operatorName in operatorSummaries.keys.sorted() {
        let counts = operatorSummaries[operatorName, default: [:]]
        print("op=\(operatorName) ane=\(counts["ane", default: 0]) cpu=\(counts["cpu", default: 0]) gpu=\(counts["gpu", default: 0])")
    }
    print("top_cost_operations:")
    for (_, row) in detailedRows.sorted(by: { $0.0 > $1.0 }).prefix(30) {
        print(row)
    }
}

@main
struct ComputePlanInspector {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: inspect_coreml_compute_plan <model.mlpackage|model.mlmodelc>\n", stderr)
            exit(2)
        }
        guard #available(macOS 14.4, *) else {
            fputs("MLComputePlan requires macOS 14.4 or newer\n", stderr)
            exit(2)
        }
        do {
            try await inspect(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        } catch {
            fputs("compute_plan_error=\(error)\n", stderr)
            exit(1)
        }
    }
}
