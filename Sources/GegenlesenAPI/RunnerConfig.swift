import Foundation

/// Docker binds are evaluated on the **host** daemon. The image keeps runner
/// config at `docker/opencode-runner` inside the container; that path does not
/// exist on the Mac/Linux host. Copy it under `dataDir` (already same-path
/// mounted) so `docker run -v` can see it.
func materializeRunnerConfig(
    workingDirectory: String,
    dataDir: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) throws -> URL {
    if let override = environment["GEGENLESEN_RUNNER_CONFIG"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let packaged = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        .appendingPathComponent("docker/opencode-runner", isDirectory: true)
    let dest = URL(fileURLWithPath: dataDir, isDirectory: true)
        .appendingPathComponent("opencode-runner", isDirectory: true)
    guard fileManager.fileExists(atPath: packaged.path) else {
        return packaged
    }
    if packaged.standardizedFileURL.path == dest.standardizedFileURL.path {
        try overlayCustomAgents(dataDir: dataDir, dest: dest, fileManager: fileManager)
        return dest
    }
    if fileManager.fileExists(atPath: dest.path) {
        try fileManager.removeItem(at: dest)
    }
    try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.copyItem(at: packaged, to: dest)
    try overlayCustomAgents(dataDir: dataDir, dest: dest, fileManager: fileManager)
    return dest
}
