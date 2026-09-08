import XCTest
@testable import LunaTV

final class EpisodePaginationTests: XCTestCase {
    func testFiftyPerGroupDoesNotLoseEpisodes() {
        for count in [0, 1, 49, 50, 51, 100, 101, 1000, 1234] {
            let ranges = EpisodePagination.ranges(count: count)
            XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<count))
            XCTAssertTrue(ranges.allSatisfy { $0.count <= 50 })
        }
    }
    func testCurrentEpisodeAndShorterSourceClamp() {
        XCTAssertEqual(EpisodePagination.group(for: 49, count: 101), 0)
        XCTAssertEqual(EpisodePagination.group(for: 50, count: 101), 1)
        XCTAssertEqual(EpisodePagination.group(for: 100, count: 101), 2)
        XCTAssertEqual(EpisodePagination.group(for: 999, count: 12), 0)
        XCTAssertEqual(EpisodePagination.group(for: -1, count: 0), 0)
    }
}
