import Foundation

/// One row of the manifest. Written as CSV and JSONL so runs are resumable and
/// auditable. `hash` is the SHA-256 of the original file bytes.
public struct ManifestEntry: Sendable, Codable, Equatable {
    public var relativePath: String
    public var fileName: String
    public var hash: String
    public var width: Int
    public var height: Int
    public var verdict: Verdict
    public var stage: String
    public var topScore: Float
    public var personScore: Float
    public var faceScore: Float
    public var sourcePath: String
    public var destinationPath: String?
    public var duplicateOf: String?
    public var error: String?
    public var timestamp: Date
    public var durationMS: Double

    public init(
        relativePath: String,
        fileName: String,
        hash: String,
        width: Int,
        height: Int,
        verdict: Verdict,
        stage: String,
        topScore: Float,
        personScore: Float = 0,
        faceScore: Float = 0,
        sourcePath: String = "",
        destinationPath: String? = nil,
        duplicateOf: String? = nil,
        error: String? = nil,
        timestamp: Date = Date(),
        durationMS: Double = 0
    ) {
        self.relativePath = relativePath
        self.fileName = fileName
        self.hash = hash
        self.width = width
        self.height = height
        self.verdict = verdict
        self.stage = stage
        self.topScore = topScore
        self.personScore = personScore
        self.faceScore = faceScore
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.duplicateOf = duplicateOf
        self.error = error
        self.timestamp = timestamp
        self.durationMS = durationMS
    }

    public static let csvHeader = [
        "relative_path", "file_name", "hash", "width", "height",
        "verdict", "stage", "top_score", "person_score", "face_score",
        "source_path", "destination_path", "duplicate_of", "error",
        "timestamp", "duration_ms",
    ].joined(separator: ",")

    public func csvRow() -> String {
        func esc(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        let fields: [String] = [
            esc(relativePath), esc(fileName), hash, "\(width)", "\(height)",
            verdict.rawValue, stage, String(format: "%.5f", topScore),
            String(format: "%.5f", personScore), String(format: "%.5f", faceScore),
            esc(sourcePath), esc(destinationPath ?? ""), esc(duplicateOf ?? ""),
            esc(error ?? ""), ISO8601DateFormatter().string(from: timestamp),
            String(format: "%.2f", durationMS),
        ]
        return fields.joined(separator: ",")
    }
}
