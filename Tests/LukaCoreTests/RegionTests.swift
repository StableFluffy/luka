import Testing
@testable import LukaCore

@Test func regionEndpoints() {
    #expect(SonioxRegion.us.websocketURL.absoluteString == "wss://stt-rt.soniox.com/transcribe-websocket")
    #expect(SonioxRegion.eu.host == "stt-rt.eu.soniox.com")
    #expect(SonioxRegion.jp.host == "stt-rt.jp.soniox.com")
    #expect(SonioxRegion.in.host == "stt-rt.in.soniox.com")
    #expect(SonioxRegion.us.apiHost == "api.soniox.com")
    #expect(SonioxRegion.eu.apiHost == "api.eu.soniox.com")
}
