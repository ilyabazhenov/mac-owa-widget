import os.log

extension Logger {
    static let app = Logger(subsystem: "com.owawidget", category: "App")
    static let sync = Logger(subsystem: "com.owawidget", category: "Sync")
    static let ews = Logger(subsystem: "com.owawidget", category: "EWS")
    static let ui = Logger(subsystem: "com.owawidget", category: "UI")
}
