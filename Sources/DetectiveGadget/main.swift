import Foundation

struct AppConfig: Codable {
    var schemaVersion: Int = 1
    var repository = RepositoryConfig()
    var tools = ToolConfig()
    var investigation = InvestigationConfig()
    var verification = VerificationConfig()
    var jira = JiraConfig()
}

struct RepositoryConfig: Codable {
    var path: String = ""
    var defaultBaseBranch: String = "development"
}

struct ToolConfig: Codable {
    var preferredGitHubCLI: String = "gh"
    var allowedInvestigationCLIs: [String] = ["claude", "gpt", "cursor"]
}

struct InvestigationConfig: Codable {
    var swiftOnly: Bool = true
    var requireApprovalBeforeChanges: Bool = true
    var requireApprovalBeforePullRequest: Bool = true
    var maxInvestigationRounds: Int = 3
    var allowUncommittedChanges: Bool = false
}

struct VerificationConfig: Codable {
    var runTests: Bool = true
    var runBuild: Bool = true
}

struct JiraConfig: Codable {
    var fetchCommand: String = ""
}

struct JiraContext: Codable {
    var key: String
    var url: String
    var jql: String
    var rawData: String?
}

struct InvestigationContext: Codable {
    var createdAt: String
    var issue: JiraContext
    var repositoryPath: String
    var baseBranch: String
    var investigationBranch: String
    var selectedCLI: String
    var reproduction: String
    var expectedBehavior: String
    var actualBehavior: String
    var logs: String
}

enum DGError: LocalizedError {
    case invalidInput(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .commandFailed(let message): message
        }
    }
}

enum FileStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".DetectiveGadget", isDirectory: true)
    static let requirements = root.appendingPathComponent("requirement.json")
    static let investigations = root.appendingPathComponent("investigations", isDirectory: true)

    static func loadConfig() throws -> AppConfig {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: requirements.path) else {
            let config = AppConfig()
            try save(config, to: requirements)
            return config
        }
        let data = try Data(contentsOf: requirements)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum ProcessRunner {
    static func executableExists(_ name: String) -> Bool {
        let result = try? run("/usr/bin/which", arguments: [name])
        return result?.status == 0
    }

    static func run(_ executable: String, arguments: [String], environment: [String: String] = [:], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        inputPipe.fileHandleForWriting.closeFile()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum Prompt {
    static func ask(_ message: String, defaultValue: String? = nil) -> String {
        if let defaultValue, !defaultValue.isEmpty {
            print("\(message) [\(defaultValue)]", terminator: " ")
        } else {
            print(message, terminator: " ")
        }
        FileHandle.standardOutput.synchronizeFile()
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? (defaultValue ?? "") : answer
    }

    static func confirm(_ message: String, defaultValue: Bool = false) -> Bool {
        let suffix = defaultValue ? "Y/n" : "y/N"
        let answer = ask("\(message) [\(suffix)]").lowercased()
        if answer.isEmpty { return defaultValue }
        return answer == "y" || answer == "yes"
    }
}

enum JiraSupport {
    static func key(from url: String) -> String? {
        let pattern = #"(?:/browse/)?([A-Z][A-Z0-9]+-[0-9]+)(?:[^A-Z0-9-]|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        guard let match = expression.firstMatch(in: url, range: range), match.numberOfRanges > 1,
              let resultRange = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[resultRange])
    }

    static func jql(for key: String) -> String { "key = \"\(key)\"" }

    static func fetch(url: String, key: String, commandTemplate: String) throws -> JiraContext {
        let jql = jql(for: key)
        var rawData: String?
        if !commandTemplate.isEmpty {
            let command = commandTemplate.replacingOccurrences(of: "{jql}", with: jql)
                .replacingOccurrences(of: "{url}", with: url)
                .replacingOccurrences(of: "{key}", with: key)
            let parts = command.split(separator: " ").map(String.init)
            guard let executable = parts.first else { throw DGError.invalidInput("Jira fetch command is empty.") }
            let result = try ProcessRunner.run(executable, arguments: Array(parts.dropFirst()), environment: ["DETECTIVE_GADGET_JQL": jql])
            guard result.status == 0 else { throw DGError.commandFailed("Jira command failed:\n\(result.output)") }
            rawData = result.output
        }
        return JiraContext(key: key, url: url, jql: jql, rawData: rawData)
    }
}

enum BranchName {
    static func make(ticket: String, issueDescription: String, solution: String?) -> String {
        let issue = compact(issueDescription, fallback: "investigate")
        let fix = compact(solution ?? "", fallback: "investigate")
        return "bugfix/\(ticket)-\(issue)-\(fix)"
    }

    private static func compact(_ value: String, fallback: String) -> String {
        let words = value.split { !$0.isLetter && !$0.isNumber }.prefix(3)
        let result = words.enumerated().map { index, word in
            let lower = word.lowercased()
            return index == 0 ? lower : lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined()
        return result.isEmpty ? fallback : result
    }
}

@main
struct DetectiveGadget {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("DetectiveGadget error: \(error.localizedDescription)\n".utf8))
        }
    }

    static func run() throws {
        print("DetectiveGadget — evidence-first Swift investigation")
        var config = try FileStore.loadConfig()

        let repository = Prompt.ask("Repository path", defaultValue: config.repository.path.isEmpty ? FileManager.default.currentDirectoryPath : config.repository.path)
        guard FileManager.default.fileExists(atPath: repository) else { throw DGError.invalidInput("Repository does not exist: \(repository)") }
        config.repository.path = repository

        let jiraURL = Prompt.ask("Jira issue URL")
        guard let key = JiraSupport.key(from: jiraURL) else { throw DGError.invalidInput("Could not extract a Jira ticket key from the URL.") }
        let jira = try JiraSupport.fetch(url: jiraURL, key: key, commandTemplate: config.jira.fetchCommand)
        print("JQL: \(jira.jql)")
        if jira.rawData == nil {
            print("No Jira fetch command configured. The JQL and issue metadata will be saved; add a Jira CLI command later to retrieve raw issue data.")
        }

        let baseBranch = Prompt.ask("Base branch", defaultValue: config.repository.defaultBaseBranch)
        let installed = config.tools.allowedInvestigationCLIs.filter(ProcessRunner.executableExists)
        let selectedCLI: String
        if installed.isEmpty {
            selectedCLI = Prompt.ask("No configured investigation CLI was detected. Enter the CLI command to use")
        } else if installed.count == 1 {
            selectedCLI = installed[0]
            print("Detected investigation CLI: \(selectedCLI)")
        } else {
            print("Detected investigation CLIs: \(installed.joined(separator: ", "))")
            selectedCLI = Prompt.ask("Investigation CLI", defaultValue: installed[0])
        }

        let reproduction = Prompt.ask("Reproduction steps or trigger")
        let expected = Prompt.ask("Expected behavior")
        let actual = Prompt.ask("Actual behavior")
        let logs = Prompt.ask("Logs or stack trace (optional)")
        let branch = BranchName.make(ticket: key, issueDescription: jira.rawData ?? "investigate", solution: nil)
        let context = InvestigationContext(createdAt: ISO8601DateFormatter().string(from: Date()), issue: jira, repositoryPath: repository, baseBranch: baseBranch, investigationBranch: branch, selectedCLI: selectedCLI, reproduction: reproduction, expectedBehavior: expected, actualBehavior: actual, logs: logs)
        let destination = FileStore.investigations.appendingPathComponent(key).appendingPathComponent("context.json")
        try FileStore.save(context, to: destination)
        let promptURL = destination.deletingLastPathComponent().appendingPathComponent("investigation-prompt.md")
        try investigationPrompt(for: context).write(to: promptURL, atomically: true, encoding: .utf8)

        print("Saved investigation context: \(destination.path)")
        print("Saved investigation brief: \(promptURL.path)")
        print("Suggested branch: \(branch)")
        print("\nEvidence status: \(reproduction.isEmpty ? "candidate hypothesis only" : "reproduction supplied; causal verification still required")")
        print("No code or branch changes were made. Approval is required before any modification or PR.")
    }

    static func investigationPrompt(for context: InvestigationContext) -> String {
        """
        # DetectiveGadget investigation: \(context.issue.key)

        Investigate this Swift issue with evidence-first discipline. Do not claim a confirmed root cause from textual similarity.

        ## Jira
        - URL: \(context.issue.url)
        - JQL: `\(context.issue.jql)`
        - Ticket data: \(context.issue.rawData ?? "Not fetched; ask the developer to provide the Jira output.")

        ## Repository
        - Path: `\(context.repositoryPath)`
        - Base branch: `\(context.baseBranch)`
        - Suggested investigation branch: `\(context.investigationBranch)`

        ## Reported behavior
        - Reproduction: \(context.reproduction.isEmpty ? "Not provided" : context.reproduction)
        - Expected: \(context.expectedBehavior.isEmpty ? "Not provided" : context.expectedBehavior)
        - Actual: \(context.actualBehavior.isEmpty ? "Not provided" : context.actualBehavior)
        - Logs: \(context.logs.isEmpty ? "Not provided" : context.logs)

        ## Required evidence
        1. A deterministic reproduction or explain why it cannot currently be reproduced.
        2. A causal control/data-flow trace through the suspected Swift code.
        3. A targeted change that makes the reproduction pass without regressions.

        If execution is unavailable, report a candidate hypothesis only, identify the missing evidence, and propose targeted logging. Do not modify code until the developer explicitly approves the proposed change.
        """
    }
}
