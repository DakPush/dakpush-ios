import UIKit
import XCTest

@testable import DakPush

/// Images for messages, against a fake web (*.img.test).
final class InAppImagesTests: XCTestCase {
    private let images = InAppImages(timeout: 2, protocolClasses: [FakeImages.self])

    override func setUp() {
        super.setUp()
        FakeImages.reset()
    }

    private func load(_ url: String, maxPixels: CGFloat = 200) -> UIImage? {
        let done = expectation(description: "load")
        var out: UIImage?
        images.load(url, maxPixels: maxPixels) { image in
            out = image
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return out
    }

    func testAnImageIsDecodedAtTheSizeItIsDrawn() throws {
        FakeImages.files["/wide.png"] = (FakeImages.png(width: 2000, height: 1000), "image/png")
        let image = try XCTUnwrap(load("https://cdn.img.test/wide.png", maxPixels: 200))
        XCTAssertEqual(image.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(FakeImages.requests.first?.value(forHTTPHeaderField: "User-Agent"), "dakpush-ios/\(Dak.version)")

        // The second time it comes from memory.
        XCTAssertNotNil(load("https://cdn.img.test/wide.png", maxPixels: 200))
        XCTAssertEqual(FakeImages.requests.count, 1)
        // A small image is not made larger.
        FakeImages.files["/small.png"] = (FakeImages.png(width: 40, height: 20), "image/png")
        XCTAssertEqual(load("https://cdn.img.test/small.png", maxPixels: 200)?.size, CGSize(width: 40, height: 20))
    }

    func testWhatCannotBeAnImageIsRefused() {
        FakeImages.files["/page"] = (Data("<html>sign in</html>".utf8), "text/html")
        XCTAssertNil(load("https://cdn.img.test/page"), "a proxy's page")
        XCTAssertNil(load("https://cdn.img.test/missing.png"), "404")
        XCTAssertNil(load("http://cdn.img.test/a.png"), "plain http")
        XCTAssertNil(load("not a url"))
        FakeImages.files["/huge.png"] = (Data(count: 6 * 1024 * 1024), "image/png")
        XCTAssertNil(load("https://cdn.img.test/huge.png"), "over 5 MB")
        FakeImages.files["/broken.png"] = (Data("not a png".utf8), "image/png")
        XCTAssertNil(load("https://cdn.img.test/broken.png"))
    }
}

/// Serves `files` for any host ending in .img.test; others 404.
final class FakeImages: URLProtocol {
    static var files: [String: (Data, String)] = [:]
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        files = [:]
        requests = []
        lock.unlock()
    }

    static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".img.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let file = Self.files[request.url?.path ?? ""]
        Self.lock.unlock()
        let url = request.url!
        guard let (data, type) = file else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
