import Foundation

/// The same failure details can be copied in full or opened in the repository's
/// bug-report form. Opening the URL leaves submission to the user.
public struct VMOmarchyPreparationFailureReport {
    public let error: String
    public let environment: String
    public let logs: [String]
    public let manifestURL: URL

    public init(
        error: String,
        environment: String,
        logs: [String],
        manifestURL: URL,
        homeDirectory: String = NSHomeDirectory()
    ) {
        func abbreviate(_ value: String) -> String {
            guard !homeDirectory.isEmpty, homeDirectory != "/" else { return value }
            return value.replacingOccurrences(of: homeDirectory, with: "~")
        }
        self.error = abbreviate(error)
        self.environment = environment
        self.logs = logs.map(abbreviate)
        self.manifestURL = manifestURL
    }

    public var text: String {
        """
        ## Omarchy preparation failed

        \(Self.indent(error))

        ## Environment

        \(environment)
        Guest: Omarchy
        Factory manifest: \(manifestURL.absoluteString)

        ## Preparation details

        \(Self.indent(logs.joined(separator: "\n")))
        """
    }

    public var issueURL: URL {
        // Bound the encoded URL rather than the character count: non-ASCII
        // errors can expand substantially when encoded for a query string.
        var errorLimit = error.count
        let details = """
        Factory manifest: \(manifestURL.absoluteString)

        Preparation details:

        \(Self.indent(logs.joined(separator: "\n")))
        """
        var contextLimit = details.count
        while true {
            var components = URLComponents(string: "https://github.com/riftvm/riftvm/issues/new")!
            let shortened = errorLimit < error.count || contextLimit < details.count
            let context = String(details.prefix(contextLimit))
                + (shortened ? "\n\nSome details were shortened. Use Copy Error in RiftVM to copy the full report." : "")
            components.queryItems = [
                URLQueryItem(name: "template", value: "bug_report.yml"),
                URLQueryItem(name: "title", value: "[Bug]: Omarchy preparation failed"),
                URLQueryItem(name: "problem", value: "Preparing Omarchy failed with this error:\n\n\(Self.indent(String(error.prefix(errorLimit))))"),
                URLQueryItem(name: "versions", value: "\(String(environment.unicodeScalars.prefix(300))) / Omarchy"),
                URLQueryItem(name: "context", value: context),
            ]
            // GitHub decodes query parameters as form data, where a literal +
            // means a space. Preserve plus signs inside errors and log output.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            if url.absoluteString.utf8.count <= 7_500 { return url }
            if contextLimit > 0 {
                contextLimit /= 2
            } else {
                errorLimit /= 2
            }
        }
    }

    private static func indent(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "    \($0)" }.joined(separator: "\n")
    }
}
