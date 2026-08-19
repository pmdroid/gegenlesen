import Foundation
import os

enum App {
    static let log = Logger(subsystem: "demo", category: "app")

    static func boot() {
        print("token leaked in logs")
        log.info("boot")
    }
}
