import XCTest
@testable import WhisperPolish

final class NoteImagesTests: XCTestCase {
    func testReadsTheTextInAnImage() async throws {
        let image = Self.render(["Are we still on for Friday?", "Running ten minutes late"])
        let text = try await NoteImages.recognizeText(in: image)
        XCTAssertEqual(text, "Are we still on for Friday?\nRunning ten minutes late")
    }

    func testAnImageWithoutTextReadsEmpty() async throws {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let text = try await NoteImages.recognizeText(in: blank)
        XCTAssertEqual(text, "")
    }

    func testSavesTheImageAsAJPEG() throws {
        let name = try NoteImages.save(Self.render(["hi"]))
        let url = NoteImages.directory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertNotNil(UIImage(contentsOfFile: url.path()))
    }

    private static func render(_ lines: [String]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 60 + 50 * lines.count), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 60 + 50 * lines.count))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 30, y: 30 + 50 * index),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black]
                )
            }
        }
    }
}
