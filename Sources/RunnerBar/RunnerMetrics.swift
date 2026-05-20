import Foundation

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
struct RunnerMetrics {
    let cpu: Double
    let mem: Double
}

func allWorkerMetrics() -> [RunnerMetrics] {
    log("allWorkerMetrics › ENTER — using pgrep + targeted ps")

    // Step 1: find matching PIDs only — fast, doesn't walk full process table
    let pidsOutput = shell("pgrep -f 'Runner\\.Worker|Runner\\.Listener'", timeout: 3)
    guard !pidsOutput.isEmpty else {
        log("allWorkerMetrics › no Runner.Worker / Runner.Listener processes found — returning []")
        return []
    }

    let pidList = pidsOutput
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
        .joined(separator: ",")

    log("allWorkerMetrics › found pids=\(pidList)")

    // Step 2: ps scoped to only those PIDs
    let output = shell("ps -p \(pidList) -o pid,%cpu,%mem,command", timeout: 5)
    log("allWorkerMetrics › ps returned — outputBytes=\(output.count) isEmpty=\(output.isEmpty)")
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps returned empty — returning []")
        return []
    }

    let lines = output.components(separatedBy: "\n").dropFirst() // drop header
    log("allWorkerMetrics › scanning \(lines.count) line(s)")

    var results: [RunnerMetrics] = []
    for line in lines {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 3,
              let cpu = Double(parts[1]),
              let mem = Double(parts[2]) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("allWorkerMetrics › failed to parse line: \(line)")
            }
            continue
        }
        let tail = parts.dropFirst(3).prefix(3).joined(separator: " ")
        log("allWorkerMetrics › found process cpu=\(cpu) mem=\(mem): \(tail)")
        results.append(RunnerMetrics(cpu: cpu, mem: mem))
    }

    let sorted = results.sorted { $0.cpu > $1.cpu }
    log("allWorkerMetrics › EXIT — returning \(sorted.count) metric(s)")
    return sorted
}
