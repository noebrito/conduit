import XCTest

/// Shared reviewer-facing artifact plumbing for the `*EvidenceTests` suites.
///
/// Every evidence test proves its contract with assertions and then writes the
/// thing a human reviews (a webhook JSON body, a screen capture) into
/// `CONDUIT_EVIDENCE_DIR`. That directory contract and the pretty-printing
/// options live here once so the two halves cannot drift apart.
extension XCTestCase {

    /// Stable, human-diffable JSON: sorted keys so an artifact is byte-comparable
    /// across runs, pretty-printed so a reviewer can read it.
    func prettyPrint(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Write a reviewer-facing artifact into `CONDUIT_EVIDENCE_DIR` when set.
    /// A missing variable is not a failure — the assertions in the test are the test.
    func writeArtifact(_ data: Data, named name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["CONDUIT_EVIDENCE_DIR"], !dir.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("[\(String(describing: type(of: self)))] wrote \(url.path)")
    }
}
