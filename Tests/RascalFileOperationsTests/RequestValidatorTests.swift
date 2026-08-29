import Foundation
import XCTest
@testable import RascalFileOperations

final class RequestValidatorTests: XCTestCase {
    func testEveryKindAcceptsItsNormativeStructuralShape() throws {
        let cases: [OperationRequest] = [
            request(.copy, sources: ["/source/a", "/source/b"], destination: "/target", mode: .container),
            request(.move, sources: ["/source/a"], destination: "/target/a", mode: .exact),
            request(.rename, sources: ["/source/a"], destination: "/source/b", mode: .exact),
            request(.replace, sources: ["/source/a"], destination: "/target/a", mode: .exact),
            request(.merge, sources: ["/source/a", "/source/b"], destination: "/target", mode: .exactDirectory),
            request(.trash, sources: ["/source/a"], destination: nil, mode: nil),
            OperationRequest(kind: .create, sources: [fileURL("/target/a")], destination: nil,
                             destinationMode: nil, createDescriptor: .directory)
        ]
        for value in cases {
            XCTAssertNoThrow(try RequestValidator.validate(value), "kind \(value.kind)")
        }
    }

    func testKindCardinalityDestinationModeAndCreateDescriptorAreValidated() {
        let invalid: [OperationRequest] = [
            request(.copy, sources: [], destination: "/target", mode: .container),
            request(.copy, sources: ["/source/a"], destination: nil, mode: .container),
            request(.copy, sources: ["/source/a", "/source/b"], destination: "/target/a", mode: .exact),
            request(.move, sources: ["/source/a"], destination: "/target", mode: .exactDirectory),
            request(.rename, sources: ["/source/a", "/source/b"], destination: "/source/c", mode: .exact),
            request(.rename, sources: ["/source/a"], destination: "/other/b", mode: .exact),
            request(.replace, sources: ["/source/a"], destination: "/target/a", mode: .container),
            request(.merge, sources: ["/source/a"], destination: "/target", mode: .container),
            request(.trash, sources: ["/source/a"], destination: "/target", mode: .exact),
            OperationRequest(kind: .create, sources: [fileURL("/target/a")], destination: nil,
                             destinationMode: nil, createDescriptor: nil),
            OperationRequest(kind: .copy, sources: [fileURL("/source/a")],
                             destination: fileURL("/target"), destinationMode: .container,
                             createDescriptor: .directory)
        ]
        for value in invalid {
            assertValidationFailure(value)
        }
    }

    func testSchemaVersionIsRejectedBeforeAdmission() throws {
        let original = request(.copy, sources: ["/source/a"], destination: "/target", mode: .container)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 99
        let decoded = try JSONDecoder().decode(
            OperationRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        assertValidationFailure(decoded, diagnostic: "schema")
    }

    func testAbsoluteFileURLsAndNormalizedDuplicateDirectoryEntries() {
        let remote = OperationRequest(kind: .copy, sources: [URL(string: "https://example.com/a")!],
                                      destination: fileURL("/target"), destinationMode: .container)
        assertValidationFailure(remote, diagnostic: "file URL")

        let duplicate = OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/a/../b"), fileURL("/source/b")],
            destination: fileURL("/target"), destinationMode: .container
        )
        assertValidationFailure(duplicate, diagnostic: "duplicate")
    }

    func testOverlapIsLexicalNoFollowAndHardLinkPathsRemainDistinct() throws {
        assertValidationFailure(
            request(.copy, sources: ["/source/tree"], destination: "/source/tree/child", mode: .exact),
            diagnostic: "overlap"
        )
        assertValidationFailure(
            request(.move, sources: ["/source/tree/child"], destination: "/source/tree", mode: .exact),
            diagnostic: "overlap"
        )

        // Structural validation deliberately does not resolve a symlink target.
        XCTAssertNoThrow(try RequestValidator.validate(request(
            .copy, sources: ["/links/source-link"], destination: "/real/source/child", mode: .exact
        )))
        // Different directory entries are kept even when a later adapter reports
        // that their device/inode identity forms a hard-link topology.
        XCTAssertNoThrow(try RequestValidator.validate(request(
            .copy, sources: ["/source/hard-a", "/other/hard-b"], destination: "/target", mode: .container
        )))
    }

    func testCallerCannotForgePortableMetadataPolicy() {
        let approval = PortableApproval(decisionID: UUID(), approvedLosses: [.acl])
        let value = OperationRequest(
            kind: .copy, sources: [fileURL("/source/a")], destination: fileURL("/target"),
            destinationMode: .container, metadataPolicy: .portable(approval)
        )
        assertValidationFailure(value, diagnostic: "portable")
    }

    func testProjectedDestinationsRespectExactAndContainerModes() {
        let container = request(.copy, sources: ["/a/report", "/b/photo"],
                                destination: "/target", mode: .container)
        XCTAssertEqual(RequestValidator.projectedDestinations(container).compactMap { $0?.path },
                       ["/target/report", "/target/photo"])
        let exact = request(.copy, sources: ["/a/report"], destination: "/target/copy", mode: .exact)
        XCTAssertEqual(RequestValidator.projectedDestinations(exact).compactMap { $0 }.first?.path,
                       "/target/copy")
    }

    private func assertValidationFailure(_ request: OperationRequest, diagnostic: String? = nil,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RequestValidator.validate(request), file: file, line: line) { error in
            guard let failure = error as? FileOperationFailure else {
                return XCTFail("wrong error type: \(error)", file: file, line: line)
            }
            XCTAssertEqual(failure.code, .validation, file: file, line: line)
            if let diagnostic {
                XCTAssertTrue(failure.diagnostic.contains(diagnostic),
                              "\(failure.diagnostic) does not contain \(diagnostic)", file: file, line: line)
            }
        }
    }

    private func request(_ kind: OperationKind, sources: [String], destination: String?,
                         mode: DestinationMode?) -> OperationRequest {
        OperationRequest(kind: kind, sources: sources.map(fileURL),
                         destination: destination.map(fileURL), destinationMode: mode)
    }

    private func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }
}
