import XCTest
import Postbox
import TelegramApi
@testable import TelegramCore

final class TelesrvLoginTests: XCTestCase {
    // MARK: - Login switches (help.getAppConfig)

    func testMissingKeysAreTheStockLogin() {
        XCTAssertEqual(TelesrvLoginConfiguration.with(appConfigurationData: nil), .default)
        XCTAssertEqual(TelesrvLoginConfiguration.with(appConfigurationData: .dictionary([:])), .default)
        XCTAssertEqual(TelesrvLoginConfiguration.with(appConfigurationData: .dictionary(["telesrv_features": .array([])])), .default)
    }

    func testPasswordLoginIsReadFromTheFeatureList() {
        let configuration = TelesrvLoginConfiguration.with(appConfigurationData: .dictionary([
            "telesrv_features": .array([.string("something_else"), .string("password_login")])
        ]))
        XCTAssertTrue(configuration.passwordLogin)
        XCTAssertFalse(configuration.codeLoginDisabled)
        XCTAssertFalse(configuration.signUpDisabled)
    }

    func testCodeLoginCanOnlyBeOffWhilePasswordLoginIsOn() {
        let withoutPasswordLogin = TelesrvLoginConfiguration.with(appConfigurationData: .dictionary([
            "telesrv_code_login_disabled": .bool(true)
        ]))
        XCTAssertFalse(withoutPasswordLogin.codeLoginDisabled)

        let withPasswordLogin = TelesrvLoginConfiguration.with(appConfigurationData: .dictionary([
            "telesrv_features": .array([.string("password_login")]),
            "telesrv_code_login_disabled": .bool(true)
        ]))
        XCTAssertTrue(withPasswordLogin.codeLoginDisabled)
    }

    func testSwitchesAreReadOnlyAsJSONBooleans() {
        let configuration = TelesrvLoginConfiguration.with(appConfigurationData: .dictionary([
            "telesrv_features": .array([.string("password_login")]),
            "telesrv_code_login_disabled": .string("true"),
            "telesrv_sign_up_disabled": .number(1.0)
        ]))
        XCTAssertFalse(configuration.codeLoginDisabled)
        XCTAssertFalse(configuration.signUpDisabled)

        let closed = TelesrvLoginConfiguration.with(appConfigurationData: .dictionary(["telesrv_sign_up_disabled": .bool(true)]))
        XCTAssertTrue(closed.signUpDisabled)
    }

    // MARK: - Authorization states

    private func roundTrip(_ contents: UnauthorizedAccountStateContents) -> UnauthorizedAccountStateContents {
        let encoder = PostboxEncoder()
        contents.encode(encoder)
        return UnauthorizedAccountStateContents(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
    }

    func testLoginPasswordStatesSurvivePostboxCoding() {
        let entry = UnauthorizedAccountStateContents.loginPasswordEntry(number: "15550001111", syncContacts: false)
        XCTAssertEqual(self.roundTrip(entry), entry)

        let signUp = UnauthorizedAccountStateContents.loginPasswordSignUp(number: "15550001111", syncContacts: true)
        XCTAssertEqual(self.roundTrip(signUp), signUp)
        XCTAssertNotEqual(entry, UnauthorizedAccountStateContents.loginPasswordSignUp(number: "15550001111", syncContacts: false))
    }

    func testLoginPasswordStatesUseTheirOwnDiscriminators() {
        // 9 and 10 are the login password states; 4 was never assigned and must stay free.
        let encoder = PostboxEncoder()
        UnauthorizedAccountStateContents.loginPasswordEntry(number: "1", syncContacts: true).encode(encoder)
        XCTAssertEqual(PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())).decodeInt32ForKey("v", orElse: -1), 9)

        let signUpEncoder = PostboxEncoder()
        UnauthorizedAccountStateContents.loginPasswordSignUp(number: "1", syncContacts: true).encode(signUpEncoder)
        XCTAssertEqual(PostboxDecoder(buffer: MemoryBuffer(data: signUpEncoder.makeData())).decodeInt32ForKey("v", orElse: -1), 10)
    }

    // MARK: - telesrv.tl

    private func constructorId(_ data: Data) -> UInt32 {
        return data.prefix(4).enumerated().reduce(0) { result, item in
            return result | (UInt32(item.element) << (8 * UInt32(item.offset)))
        }
    }

    func testTelesrvMethodsUseTheSchemaWireIds() {
        XCTAssertEqual(self.constructorId(Api.functions.telesrv.getLoginPassword(flags: 0, phoneNumber: "1").1.makeData()), 0xe35bc783)
        XCTAssertEqual(self.constructorId(Api.functions.telesrv.signInWithPassword(flags: 0, phoneNumber: "1", password: .inputCheckPasswordEmpty).1.makeData()), 0xb57ee87d)
        let settings = Api.account.PasswordInputSettings.passwordInputSettings(.init(flags: 1 << 0, newAlgo: .passwordKdfAlgoUnknown, newPasswordHash: Buffer(data: Data()), hint: "", email: nil, newSecureSettings: nil))
        XCTAssertEqual(self.constructorId(Api.functions.telesrv.signUpWithPassword(flags: 0, phoneNumber: "1", firstName: "A", lastName: "", newSettings: settings).1.makeData()), 0xe57cf5b6)
        XCTAssertEqual(self.constructorId(Api.functions.telesrv.getMyLoginPassword(flags: 0).1.makeData()), 0x70c0eadb)
        XCTAssertEqual(self.constructorId(Api.functions.telesrv.updateLoginPassword(flags: 0, current: .inputCheckPasswordEmpty, newSettings: settings).1.makeData()), 0x917c32ca)
    }

    // MARK: - Links

    func testAppSchemeIsRewrittenToTheTelegramForm() {
        XCTAssertEqual(telesrvInternalUrl("dm://resolve?domain=durov"), "tg://resolve?domain=durov")
        XCTAssertEqual(telesrvInternalUrl("DM://login?token=abc"), "tg://login?token=abc")
        XCTAssertEqual(telesrvInternalUrl("tg://resolve?domain=durov"), "tg://resolve?domain=durov")
        XCTAssertEqual(telesrvInternalUrl("https://darkmoon.cc/durov"), "https://darkmoon.cc/durov")
        XCTAssertEqual(telesrvInternalUrl("dm:"), "dm:")
        XCTAssertEqual(telesrvInternalUrl(URL(string: "dm://proxy?server=a&port=1")!).absoluteString, "tg://proxy?server=a&port=1")
    }

    func testAppSchemeLinksAreRecognized() {
        XCTAssertTrue(isTelesrvAppSchemeUrl("dm://resolve?domain=durov"))
        XCTAssertTrue(isTelesrvAppSchemeUrl("tg://resolve?domain=durov"))
        XCTAssertFalse(isTelesrvAppSchemeUrl("https://darkmoon.cc/durov"))
    }

    func testWebProxyLinksUseTheServerHost() {
        let secret = Data((0 ..< 16).map(UInt8.init))
        let settings = ProxyServerSettings(host: "proxy.example.com", port: 443, connection: .web(secret: secret, path: ""))
        guard let link = webProxySettingsLink(settings) else {
            XCTFail("no link")
            return
        }
        XCTAssertTrue(link.hasPrefix("https://\(telesrvLinkHost)/webproxy?"), link)
        XCTAssertEqual(parseWebProxySettingsLink(link), settings)
        XCTAssertEqual(parseWebProxySettingsLink(link.replacingOccurrences(of: "https://\(telesrvLinkHost)/webproxy", with: "dm://webproxy")), settings)
    }
}
