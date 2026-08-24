import Foundation

public enum HarvestGateError: Error, Equatable, CustomStringConvertible, Sendable {
    case repositoryUnresolved
    case harvestRequired

    public var description: String {
        switch self {
        case .repositoryUnresolved:
            return "repository_unresolved"
        case .harvestRequired:
            return "harvest_required"
        }
    }
}

public enum HarvestGate: Sendable {
    public static func check(repository: String?, hasSucceededHarvest: Bool) throws {
        guard RepositoryName.normalize(repository) != nil else {
            throw HarvestGateError.repositoryUnresolved
        }
        if !hasSucceededHarvest {
            throw HarvestGateError.harvestRequired
        }
    }
}
