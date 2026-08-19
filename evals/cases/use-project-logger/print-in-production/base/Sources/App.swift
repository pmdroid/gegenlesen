import Foundation
import os

enum App {
    static let log = Logger(subsystem: "demo", category: "app")

    static func boot() {
        log.info("boot")
    }
}
