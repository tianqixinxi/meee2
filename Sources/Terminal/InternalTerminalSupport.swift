import Foundation

public enum InternalTerminalLifecycle: String, Codable {
    case starting
    case running
    case exited
    case failed
}

public enum InternalWorkspaceTrustPromptDetector {
    public static func shouldAutoAccept(provider: String, command: String, output: String) -> Bool {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard launchesClaude(provider: normalizedProvider, command: normalizedCommand) else { return false }

        let normalizedOutput = stripTerminalControls(output).lowercased()
        guard normalizedOutput.contains("trust") else { return false }

        return normalizedOutput.contains("do you trust the files")
            || normalizedOutput.contains("quick safety check")
            || normalizedOutput.contains("yes, i trust this folder")
            || normalizedOutput.contains("trust this workspace")
            || normalizedOutput.contains("trust this folder")
            || normalizedOutput.contains("trust this project")
    }

    public static func response(for output: String) -> String {
        let normalizedOutput = stripTerminalControls(output).lowercased()
        if normalizedOutput.contains("[y/n]")
            || normalizedOutput.contains("(y/n)")
            || normalizedOutput.contains("y/n")
            || normalizedOutput.contains("yes/no") {
            return "y\r"
        }
        if normalizedOutput.contains("enter to confirm") {
            return "\r"
        }
        return "1\r"
    }

    public static func shouldProactivelyAutoAccept(provider: String, command: String, cwd: String) -> Bool {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard launchesClaude(provider: normalizedProvider, command: normalizedCommand) else { return false }
        return InternalSessionIdentity.isMeee2ManagedWorkspace(cwd)
    }

    private static func launchesClaude(provider: String, command: String) -> Bool {
        if provider == "claude" { return true }
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return executable == "claude" || executable.hasSuffix("/claude")
    }

    private static func stripTerminalControls(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\u{1B}" {
                while let next = iterator.next() {
                    if next.isLetter || next == "~" {
                        break
                    }
                }
                continue
            }
            if character.unicodeScalars.allSatisfy({ $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
                continue
            }
            result.append(character)
        }
        return result
    }
}
