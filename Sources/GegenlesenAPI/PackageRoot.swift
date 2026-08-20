import Foundation

/// Directory that holds `frontend/dist`, `rules`, `schemas`, and `docker/opencode-runner`.
///
/// Release tarballs keep those next to the binaries. `GEGENLESEN_ROOT` wins when set.
func gegenlesenPackageRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    cwd: String = FileManager.default.currentDirectoryPath,
    executablePath: String = CommandLine.arguments[0]
) -> String? {
    if let override = environment["GEGENLESEN_ROOT"], !override.isEmpty {
        return trailingSlash(override)
    }
    var candidates: [String] = []
    if let exeDir = resolvedExecutableDirectory(
        executablePath: executablePath,
        environment: environment,
        fileManager: fileManager
    ) {
        candidates.append(exeDir.path)
    }
    candidates.append(cwd)
    for path in candidates where looksLikePackageRoot(path, fileManager: fileManager) {
        return trailingSlash(path)
    }
    return nil
}

func looksLikePackageRoot(_ path: String, fileManager: FileManager) -> Bool {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    return fileManager.fileExists(atPath: root.appendingPathComponent("frontend/dist/index.html").path)
        || fileManager.fileExists(atPath: root.appendingPathComponent("rules", isDirectory: true).path)
}

func resolvedExecutableDirectory(
    executablePath: String,
    environment: [String: String],
    fileManager: FileManager
) -> URL? {
    var path = executablePath
    if !path.contains("/") {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent(path)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                path = candidate.path
                break
            }
        }
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard url.path != "/" else { return nil }
    return url.deletingLastPathComponent()
}

private func trailingSlash(_ path: String) -> String {
    path.hasSuffix("/") ? path : path + "/"
}
