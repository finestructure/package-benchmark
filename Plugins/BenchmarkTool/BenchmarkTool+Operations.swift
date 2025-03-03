//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

// run/list benchmarks by talking to controlled process
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#else
    #error("Unsupported Platform")
#endif

import Benchmark
import Foundation
import SystemPackage
import TextTable

extension BenchmarkTool {
    mutating func queryBenchmarks(_ benchmarkPath: String) throws {
        try write(.list)
        outerloop: while true {
            let benchmarkReply = try read()

            switch benchmarkReply {
            case let .list(benchmark):
                benchmark.executablePath = benchmarkPath
                benchmark.target = FilePath(benchmarkPath).lastComponent!.description
                if metrics.isEmpty == false {
                    benchmark.configuration.metrics = metrics
                }
                benchmarks.append(benchmark)
            case .end:
                break outerloop
            case let .error(description):
                failBenchmark(description)
                break outerloop
            default:
                print("Unexpected reply \(benchmarkReply)")
            }
        }
    }

    mutating func runBenchmark(target: String, benchmark: Benchmark) throws -> BenchmarkResults {
        var benchmarkResults: BenchmarkResults = [:]
        try write(.run(benchmark: benchmark))

        outerloop: while true {
            let benchmarkReply = try read()

            switch benchmarkReply {
            case let .result(benchmark: benchmark, results: results):
                let filteredResults = results.filter { benchmark.configuration.metrics.contains($0.metric) }
                benchmarkResults[BenchmarkIdentifier(target: target, name: benchmark.name)] = filteredResults
            case .end:
                break outerloop
            case let .error(description):
                failBenchmark(description, exitCode: .benchmarkJobFailed, "\(target)/\(benchmark.name)")

                benchmarkResults[BenchmarkIdentifier(target: target, name: benchmark.name)] = []
                break outerloop
            default:
                print("Unexpected reply \(benchmarkReply)")
            }
        }

        return benchmarkResults
    }

    func cleanupStringForShellSafety(_ string: String) -> String {
        var cleanedString = string.replacingOccurrences(of: "/", with: "_")
        cleanedString = cleanedString.replacingOccurrences(of: " ", with: "_")
        return cleanedString
    }

    struct NameAndTarget: Hashable {
        let name: String
        let target: String
    }

    mutating func postProcessBenchmarkResults() throws {
        // Turn on buffering again for output
        setvbuf(stdout, nil, _IOFBF, Int(BUFSIZ))

        switch command {
        case .`init`:
            return
        case .baseline:
            guard let baselineOperation else {
                fatalError("Baseline command without specifying a baseline operation, internal error in Benchmark")
            }

            switch baselineOperation {
            case .delete:
                targets.forEach { target in
                    baseline.forEach {
                        removeBaselinesNamed(target: target, baselineName: $0)
                    }
                }
                return
            case .list:
                printAllBaselines()
            case .compare:
                guard benchmarkBaselines.count == 2 else {
                    print("Can only compare exactly 2 benchmark baselines, got: \(benchmarkBaselines.count) baselines.")
                    return
                }

                prettyPrintDelta(currentBaseline: benchmarkBaselines[0], baseline: benchmarkBaselines[1])
            case .update:
                guard benchmarkBaselines.count == 1 else {
                    print("Can only update a single benchmark baseline, got: \(benchmarkBaselines.count) baselines.")
                    return
                }

                let baseline = benchmarkBaselines[0]
                if let baselineName = self.baseline.first {
                    try baseline.targets.forEach { target in
                        let results = baseline.results.filter { $0.key.target == target }
                        let subset = BenchmarkBaseline(baselineName: baselineName,
                                                       machine: baseline.machine,
                                                       results: results)
                        try write(baseline: subset,
                                  baselineName: baselineName,
                                  target: target)
                    }

                    if quiet == false {
                        print("")
                        print("Updated baseline '\(baselineName)'")
                    }
                } else {
                    failBenchmark("Could not get first baselinename.", exitCode: .baselineNotFound)
                }

            case .check:
                if checkAbsolute {
                    guard benchmarkBaselines.count == 1,
                            let currentBaseline = benchmarkBaselines.first,
                            let baselineName = baseline.first else {
                        print("Can only do absolute threshold violation checks for a single benchmark baseline, got: \(benchmarkBaselines.count) baselines.")
                        return
                    }

                    if benchmarks.isEmpty { // if we read from baseline and didn't run them, we put in some fake entries for the compare
                        currentBaseline.results.keys.forEach { baselineKey in
                            if let benchmark: Benchmark = .init(baselineKey.name, closure:{_ in}) {
                                benchmark.target = baselineKey.target
                                benchmarks.append(benchmark)
                            }
                        }
                    }

                    benchmarks = benchmarks.filter {
                        do {
                            return try shouldIncludeBenchmark($0.name)
                        } catch {
                            return false
                        }
                    }

                    if let benchmarkPath = checkAbsolutePath { // load statically defined thresholds for .p90
                        var thresholdsFound = false
                        benchmarks.forEach { benchmark in
                            let thresholds = BenchmarkTool.makeBenchmarkThresholds(path: benchmarkPath,
                                                                                   moduleName: benchmark.target,
                                                                                   benchmarkName: benchmark.name)
                            var transformed: [BenchmarkMetric: BenchmarkThresholds] = [:]
                            if let thresholds {
                                thresholdsFound = true
                                thresholds.forEach { key, value in
                                    if let metric = BenchmarkMetric(argument: key) {
                                        let absoluteThreshold: BenchmarkThresholds.AbsoluteThresholds = [.p90: value]
                                        transformed[metric] = BenchmarkThresholds(absolute: absoluteThreshold)
                                    }
                                }
                                if transformed.isEmpty == false {
                                    benchmark.configuration.thresholds = transformed
                                }
                            }
                        }
                        if !thresholdsFound {
                            if benchmarks.count == 0 {
                                failBenchmark("No benchmarks matching filter selection, failing threshold check.",
                                              exitCode: .thresholdRegression)
                            }
                            failBenchmark("Could not find any matching absolute thresholds at path [\(benchmarkPath)], failing threshold check.",
                                          exitCode: .thresholdRegression)
                        }
                    }
                    print("")

                    let deviationResults = currentBaseline.failsAbsoluteThresholdChecks(benchmarks: benchmarks)

                    if deviationResults.regressions.isEmpty {
                        if deviationResults.improvements.isEmpty {
                            print("Baseline '\(baselineName)' is EQUAL to the defined absolute baseline thresholds. (--check-absolute)")
                        } else {
                            prettyPrintAbsoluteDeviation(baselineName: baselineName,
                                                         deviationResults: deviationResults.improvements)

                            failBenchmark("New baseline '\(baselineName)' is BETTER than the defined absolute baseline thresholds. (--check-absolute)",
                                          exitCode: .thresholdImprovement)
                        }
                    } else {
                        prettyPrintAbsoluteDeviation(baselineName: baselineName,
                                                     deviationResults: deviationResults.regressions)
                        failBenchmark("New baseline '\(baselineName)' is WORSE than the defined absolute baseline thresholds. (--check-absolute)",
                                      exitCode: .thresholdRegression)
                    }
                } else {
                    guard benchmarkBaselines.count == 2 else {
                        print("Can only do threshold violation checks for exactly 2 benchmark baselines, got: \(benchmarkBaselines.count) baselines.")
                        return
                    }

                    let currentBaseline = benchmarkBaselines[0]
                    let checkBaseline = benchmarkBaselines[1]
                    let baselineName = baseline[0]
                    let checkBaselineName = baseline[1]
                    let deviationResults = checkBaseline.deviationsComparedToBaseline(currentBaseline,
                                                                                      benchmarks: benchmarks)

                    print("")
                    if deviationResults.regressions.isEmpty {
                        if deviationResults.improvements.isEmpty {
                            print("New baseline '\(checkBaselineName)' is WITHIN the '\(baselineName)' baseline thresholds.")
                        } else {
                            prettyPrintDeviation(baselineName: baselineName,
                                                 comparingBaselineName: checkBaselineName,
                                                 deviationResults: deviationResults.improvements)
                            failBenchmark("New baseline '\(checkBaselineName)' is BETTER than the '\(baselineName)' baseline thresholds.",
                                          exitCode: .thresholdImprovement)
                        }
                    } else {
                        prettyPrintDeviation(baselineName: baselineName,
                                             comparingBaselineName: checkBaselineName,
                                             deviationResults: deviationResults.regressions)
                        failBenchmark("New baseline '\(checkBaselineName)' is WORSE than the '\(baselineName)' baseline thresholds.",
                                      exitCode: .thresholdRegression)
                    }
                }
            case .read:
                if benchmarkBaselines.isEmpty {
                    print("No baseline found.")
                } else {
                    try benchmarkBaselines.forEach { baseline in
                        try exportResults(baseline: baseline)
                    }
                }
            }
        case .run:
            guard let baseline = benchmarkBaselines.first else {
                fatalError("Internal error, no baseline data after benchmark run.")
            }

            try exportResults(baseline: baseline)
        case .query:
            break
        case .list:
            break
        }
    }

    func listBenchmarks() throws {
        print("")
        benchmarkExecutablePaths.forEach { benchmarkExecutablePath in
            print("Target '\(FilePath(benchmarkExecutablePath).lastComponent!)' available benchmarks:")
            benchmarks.forEach { benchmark in
                if benchmark.executablePath == benchmarkExecutablePath {
                    print("\(benchmark.name)")
                }
            }
            print("")
        }
    }
}
