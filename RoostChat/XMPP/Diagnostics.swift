import Foundation

/// What the account's connection is doing, for the account screen.
struct ConnectionDiagnostics {
    var attempts = 0
    var lastAttempt: Date?
    var lastStateChange: Date?
    var connectedSince: Date?
    var nextRetry: Date?
    var lastError: String?
    var lastErrorAt: Date?
    var serverRoute: String?
    var tlsActive = false
    var tlsSummary: String?
    var tlsSubject: String?
    var tlsFingerprint: String?
    var boundJID: String?
    var resumed = false
    var smEnabled = false
    var lastPing: String?
    var pushStatus: String?

    var rows: [DiagnosticRow] {
        var result: [DiagnosticRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { result.append(DiagnosticRow(label: label, value: value)) }
        }
        add("Last error", lastError)
        add("Error time", lastErrorAt.map(Self.format))
        add("Server", serverRoute)
        add("TLS", tlsSummary)
        add("Certificate", tlsSubject)
        add("SHA-256", tlsFingerprint)
        add("Connected as", connectedSince == nil ? nil : boundJID)
        add("Connected since", connectedSince.map(Self.format))
        add("Encrypted stream", connectedSince == nil ? nil : (tlsActive ? "Yes" : "No"))
        add("Stream resumed", connectedSince == nil ? nil : (resumed ? "Yes" : "No"))
        add("Resumable", smEnabled ? "Yes" : nil)
        add("Next retry", nextRetry.map(Self.format))
        add("Attempts", attempts == 0 ? nil : String(attempts))
        add("Last attempt", lastAttempt.map(Self.format))
        add("Last state change", lastStateChange.map(Self.format))
        add("Ping", lastPing)
        add("Push", pushStatus)
        return result
    }

    var report: String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

struct DiagnosticRow: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// What the server told us about itself.
struct ServerCapabilities {
    var identities: [String] = []
    var serverFeatures: [String] = []
    var accountFeatures: [String] = []
    var streamFeatures: [String] = []
    var saslMechanisms: [String] = []

    var isEmpty: Bool {
        identities.isEmpty && serverFeatures.isEmpty && accountFeatures.isEmpty && streamFeatures.isEmpty
    }
}
