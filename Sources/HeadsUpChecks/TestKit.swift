import Foundation

/// Thrown by the `expect*` helpers below when an assertion fails. Carries a
/// message that already includes the file and line, so callers of `test`
/// can print it directly without extra formatting.
struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(
    _ condition: Bool,
    _ message: String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if !condition {
        throw CheckFailure(message: "\(message) (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if actual != expected {
        throw CheckFailure(message: "expected \(expected), got \(actual) (\(file):\(line))")
    }
}

func expectNil<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if value != nil {
        throw CheckFailure(message: "expected nil, got \(String(describing: value)) (\(file):\(line))")
    }
}

func expectNotNil<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if value == nil {
        throw CheckFailure(message: "expected a non-nil value (\(file):\(line))")
    }
}

/// Running total across every `test` call in the process, printed as the
/// final summary line in main.swift.
enum TestRun {
    static var passed = 0
    static var failed = 0
}

func suite(_ name: String) {
    print("== \(name) ==")
}

func test(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        TestRun.passed += 1
        print("  ok \(name)")
    } catch {
        TestRun.failed += 1
        print("  FAIL \(name): \(error)")
    }
}
