import XCTest
@testable import meee2Kit

final class DynamicPluginLoaderTests: XCTestCase {
    func testBuiltinManifestsDeclareTheCurrentABI() throws {
        for name in ["cursor", "openclaw", "codex"] {
            let metadata = try XCTUnwrap(
                DynamicPluginLoader.builtinManifestMetadata(directoryName: name),
                "missing canonical manifest for \(name)"
            )
            XCTAssertEqual(metadata.abi_version, CURRENT_PLUGIN_KIT_ABI_VERSION, name)
            XCTAssertFalse(metadata.dylib.isEmpty, name)
        }
    }

    func testABICompatibilityRequiresAnExactMatch() {
        XCTAssertNil(DynamicPluginLoader.abiCompatibilityError(
            declaredABI: CURRENT_PLUGIN_KIT_ABI_VERSION
        ))
        XCTAssertNotNil(DynamicPluginLoader.abiCompatibilityError(declaredABI: nil))
        XCTAssertNotNil(DynamicPluginLoader.abiCompatibilityError(
            declaredABI: CURRENT_PLUGIN_KIT_ABI_VERSION - 1
        ))
        XCTAssertNotNil(DynamicPluginLoader.abiCompatibilityError(
            declaredABI: CURRENT_PLUGIN_KIT_ABI_VERSION + 1
        ))
    }
}
