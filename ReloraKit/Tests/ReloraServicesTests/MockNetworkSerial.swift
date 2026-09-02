import Testing

/// Parent suite for every test that talks through the module-wide
/// `MockURLProtocol` statics. Swift Testing runs suites in parallel, so
/// without this the tests see each other's captured requests and stubs.
/// `.serialized` recurses into sub-suites; new MockURLProtocol tests
/// must live in an extension of this enum.
@Suite(.serialized)
enum MockNetworkSerialTests {}
