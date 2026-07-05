import Foundation
import SwiftProtobuf

/// Sends a zero-batch test envelope to a webhook endpoint and returns the result.
///
/// Used by onboarding and settings to verify connectivity before saving config.
/// Uses a foreground `URLSession` (not background) so the result is available immediately.
struct WebhookTester {
    struct Result {
        let statusCode: Int
        let latencyMs: Int
        let error: String?

        var isSuccess: Bool {
            error == nil && (200...299).contains(statusCode)
        }

        var summary: String {
            if let error { return error }
            return "HTTP \(statusCode) — \(latencyMs) ms"
        }
    }

    /// POST a test envelope to `url` with `Bearer token` and return the result.
    static func test(url urlString: String, token: String) async -> Result {
        guard let url = URL(string: urlString) else {
            return Result(statusCode: 0, latencyMs: 0, error: "Invalid URL")
        }

        var envelope = Conduit_V1_Envelope()
        envelope.schemaVersion = "v1"
        envelope.batchID = "test-\(UUID().uuidString)"
        envelope.deviceID = KeychainStore.shared.deviceID
        envelope.sentAtUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        // batches intentionally empty — this is a connectivity probe

        guard let body = try? envelope.jsonUTF8Data() else {
            return Result(statusCode: 0, latencyMs: 0, error: "Failed to encode test payload")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        request.setValue("Conduit/\(version) (iOS test)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return Result(statusCode: 0, latencyMs: latency, error: "No HTTP response received")
            }
            if (200...299).contains(http.statusCode) {
                return Result(statusCode: http.statusCode, latencyMs: latency, error: nil)
            }
            return Result(statusCode: http.statusCode, latencyMs: latency, error: "Server returned \(http.statusCode)")
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return Result(statusCode: 0, latencyMs: latency, error: error.localizedDescription)
        }
    }
}
