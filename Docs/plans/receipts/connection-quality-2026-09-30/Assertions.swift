import Foundation

class XCTestCase {}
var failures = 0
var assertions = 0
func check(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
    assertions += 1
    if !passed { failures += 1; print("FAIL \(file):\(line) \(message)") }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let lhs = a(), rhs = b()
    check(lhs == rhs, "\(lhs) != \(rhs) \(message)", file: file, line: line)
}
func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(value() == nil, message, file: file, line: line)
}
func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(value() != nil, message, file: file, line: line)
}
func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(value(), message, file: file, line: line)
}
func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(!value(), message, file: file, line: line)
}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let lhs = a(), rhs = b()
    check(lhs < rhs, "\(lhs) is not less than \(rhs) \(message)", file: file, line: line)
}
