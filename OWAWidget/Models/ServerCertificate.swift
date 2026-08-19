import Foundation

/// Human-readable facts about a server certificate, shown next to its fingerprint.
///
/// A SHA-256 fingerprint is the thing that actually gets pinned, but it is 64 hex characters the
/// user has nothing to compare against and no way to remember. Who issued the certificate, to
/// what name, and until when are facts a person can actually judge: "issued by our corporate CA
/// for mail.example.com" is checkable, a hash is not.
struct ServerCertificateDetails: Equatable, Sendable {
    /// Common name of the subject, i.e. the name the certificate was issued to.
    var subject: String?
    /// Common name of the issuing authority.
    var issuer: String?
    var notBefore: Date?
    var notAfter: Date?

    var isEmpty: Bool {
        subject == nil && issuer == nil && notBefore == nil && notAfter == nil
    }
}

extension ServerCertificateDetails {
    /// Lines for the trust prompt, in the order a person reads them.
    ///
    /// Whatever the certificate does not carry is skipped rather than printed as an empty label:
    /// a prompt that says "Issued by:" followed by nothing reads like a bug and undermines the
    /// one thing it is there to do — make the user look.
    func summaryLines(
        subjectLabel: String,
        issuerLabel: String,
        validUntilLabel: String,
        dateFormatter: DateFormatter
    ) -> [String] {
        var lines: [String] = []
        if let subject { lines.append("\(subjectLabel) \(subject)") }
        if let issuer { lines.append("\(issuerLabel) \(issuer)") }
        if let notAfter { lines.append("\(validUntilLabel) \(dateFormatter.string(from: notAfter))") }
        return lines
    }
}

/// A server certificate the system refused and the user has not pinned.
struct UntrustedCertificate: Equatable, Sendable {
    var host: String
    var port: Int
    /// Lowercase hex SHA-256 of the leaf certificate's DER representation.
    var fingerprint: String
    var details: ServerCertificateDetails?
}
