import CoreML
import Foundation

enum CoreMLScoreReader {
    static func scalar(
        from output: MLFeatureProvider,
        names: [String] = ["score", "target"]
    ) -> Double? {
        for name in names {
            guard let feature = output.featureValue(for: name) else { continue }
            let value: Double?
            if feature.type == .multiArray,
               let array = feature.multiArrayValue,
               array.count > 0 {
                value = array[0].doubleValue
            } else if feature.type == .double {
                value = feature.doubleValue
            } else if feature.type == .int64 {
                value = Double(feature.int64Value)
            } else {
                value = nil
            }
            if let value, value.isFinite {
                return value
            }
        }
        return nil
    }

    static func outputDescription(model: MLModel, names: [String] = ["score", "target"]) -> String {
        for name in names {
            guard let description = model.modelDescription.outputDescriptionsByName[name] else { continue }
            if let constraint = description.multiArrayConstraint {
                let shape = constraint.shape.map(\.intValue).map(String.init).joined(separator: "x")
                return "\(name):multiArray[\(shape)]"
            }
            return "\(name):type=\(description.type.rawValue)"
        }
        return "missing"
    }
}
