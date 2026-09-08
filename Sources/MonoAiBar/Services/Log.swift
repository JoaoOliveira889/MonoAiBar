import OSLog

enum Log {
    static let credentials = Logger(subsystem: subsystem, category: "credentials")
    static let quota = Logger(subsystem: subsystem, category: "quota")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let system = Logger(subsystem: subsystem, category: "system")

    private static let subsystem = "com.joaooliveira889.monoaibar"
}
