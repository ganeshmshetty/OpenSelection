// main.swift
// openselection-diagnose
//
// Standalone diagnostic CLI for OpenSelection.
import ApplicationServices
import Foundation
import OpenSelection

@main
struct DiagnoseCLI {
    static func main() async {
        let args = CommandLine.arguments

        if args.contains("-h") || args.contains("--help") {
            printUsage()
            return
        }

        if !AXIsProcessTrusted() {
            FileHandle.standardError.write(Data("""
            ⚠️  Warning: Terminal process does not have Accessibility permissions.
               AXIsProcessTrusted() is false. Accessibility inspection will be limited or unavailable.
               To enable: System Settings > Privacy & Security > Accessibility -> grant access to Terminal.

            """.utf8))
        }

        var target: InspectionTarget = .frontmost
        var delay: TimeInterval = 0
        var isJSON = false
        var allowIntrusive = false
        var forcePrompt = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--frontmost":
                target = .frontmost
            case "--pid":
                if i + 1 < args.count, let p = Int32(args[i + 1]) {
                    target = .pid(p)
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("Error: --pid requires an integer PID\n".utf8))
                    exit(1)
                }
            case "--bundle", "--bundle-id":
                if i + 1 < args.count {
                    target = .bundleID(args[i + 1])
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("Error: --bundle requires a bundle identifier\n".utf8))
                    exit(1)
                }
            case "--delay":
                if i + 1 < args.count, let d = Double(args[i + 1]) {
                    delay = d
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("Error: --delay requires seconds\n".utf8))
                    exit(1)
                }
            case "--json":
                isJSON = true
            case "--text":
                isJSON = false
            case "--live-run":
                allowIntrusive = true
            case "--force", "-f":
                forcePrompt = true
            default:
                FileHandle.standardError.write(Data("Unknown argument: \(arg)\nUse --help for usage.\n".utf8))
                exit(1)
            }
            i += 1
        }

        if allowIntrusive && !forcePrompt {
            if isatty(fileno(stdin)) != 0 {
                FileHandle.standardError.write(Data("⚠️  --live-run will synthesize keyboard/menu events to capture real selection.\nProceed? [y/N]: ".utf8))
                guard let line = readLine(), line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" else {
                    FileHandle.standardError.write(Data("Aborted.\n".utf8))
                    exit(0)
                }
            }
        }

        if delay > 0 {
            target = .focusedAfter(delay: delay)
        }

        let options = InspectionOptions(
            depth: 10,
            nodeBudget: 100,
            deadlineSeconds: 5.0,
            allowIntrusiveProbes: allowIntrusive
        )

        let diagnostics = await OpenSelectionInspector.diagnose(target: target, options: options)

        if isJSON {
            let data = diagnostics.renderJSON(pretty: true)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(diagnostics.renderText())
        }
    }

    private static func printUsage() {
        print("""
        openselection-diagnose: Accessibility & selection diagnostics inspector

        USAGE:
          openselection-diagnose [options]

        OPTIONS:
          --frontmost            Inspect the currently active frontmost application (default)
          --pid <pid>            Inspect the process with the given PID
          --bundle <id>          Inspect running application with bundle identifier
          --delay <sec>          Wait <sec> seconds before snapshotting (useful to switch apps)
          --json                 Output diagnostic report in formatted JSON
          --text                 Output diagnostic report in formatted human text (default)
          --live-run             Run active retrieval cascade including synthetic copy (intrusive)
          --force, -f            Skip confirmation prompt for --live-run
          --help, -h             Show this help information

        EXAMPLES:
          openselection-diagnose --frontmost --delay 3 --json > report.json
          openselection-diagnose --pid 4821 --text
          openselection-diagnose --live-run --force
        """)
    }
}
