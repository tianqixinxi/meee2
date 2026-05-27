import Foundation

public enum DoctorCommand {
    public static func run(args: [String]) {
        let report = ReadinessDoctor.diagnose()
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print("meee2 doctor")
        print("Status: \(report.ready ? "ready" : "needs setup")")
        print("Required failures: \(report.requiredFailed)")
        print("")

        for check in report.checks {
            let marker: String
            switch check.status {
            case .pass: marker = "✓"
            case .fail: marker = "✗"
            case .warn: marker = "!"
            case .info: marker = "i"
            }
            print("\(marker) [\(check.severity.rawValue)] \(check.title)")
            print("  \(check.detail)")
            if let action = check.recoveryAction {
                print("  action: \(action.label) (\(action.id))")
                if let command = action.command {
                    print("  command: \(command)")
                }
            }
        }
    }
}
