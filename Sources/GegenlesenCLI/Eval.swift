import ArgumentParser
import Foundation
import GegenlesenCore
import GegenlesenDeterministic

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Run the known-wrong fixture suite (pack + deterministic rules)"
    )

    @Option(name: .long, help: "Repo root containing evals/cases and scripts/pack-repo.sh.")
    var repo: String?

    func run() async throws {
        let start: URL
        if let repo {
            start = URL(fileURLWithPath: repo, isDirectory: true)
        } else {
            start = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
        guard let root = RepoRoot.find(startingAt: start) else {
            throw CLIError("could not find evals/cases and scripts/pack-repo.sh from \(start.path)")
        }
        let runner = EvalRunner(repoRoot: root, deterministic: DeterministicEngine())
        let report = try await runner.run()
        print(report.render())
        if report.failed > 0 {
            throw ExitCode(1)
        }
    }
}
