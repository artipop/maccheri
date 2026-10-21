import MaccheriProtocol
import XCTVapor
@testable import ControlPlane

final class AuthHostTests: ControlPlaneTestCase {
    func testInviteIsOneTime() async throws {
        let admin = try await signUp("Admin")
        let invite = try await post("v1/invites", Empty(), as: Invite.self, token: admin.token)
        XCTAssertTrue(invite.code.hasPrefix("mci_"))
        XCTAssertEqual(invite.expiresAt, clock.now.addingTimeInterval(7 * 86_400))

        let member = try await post("v1/auth/redeem", RedeemInviteRequest(code: invite.code, name: "Member"), as: UserToken.self)
        XCTAssertTrue(member.token.hasPrefix("mcu_"))
        let me = try await meInfo(member.token)
        XCTAssertEqual(me, UserInfo(id: member.userID, name: "Member", isAdmin: false))

        let again = try await status(.POST, "v1/auth/redeem", RedeemInviteRequest(code: invite.code, name: "Again"), token: nil)
        XCTAssertEqual(again, .notFound)
    }

    func testExpiredInviteIsRejected() async throws {
        let invite = try await AuthController.createInvite(isAdmin: false, createdBy: nil, on: app.db, maccheri: app.maccheri)
        clock.advance(seconds: 7 * 86_400 + 1)
        let status = try await status(.POST, "v1/auth/redeem", RedeemInviteRequest(code: invite.code, name: "Late"), token: nil)
        XCTAssertEqual(status, .notFound)
    }

    func testOnlyAdminsInvite() async throws {
        let member = try await signUp("Member", admin: false)
        try await assertEqual(try await status(.POST, "v1/invites", token: member.token), .forbidden)
    }

    func testTokensAreRequiredAndStoredHashed() async throws {
        try await assertEqual(try await status(.GET, "v1/me", token: nil), .unauthorized)
        try await assertEqual(try await status(.GET, "v1/me", token: "mcu_nope"), .unauthorized)
        let user = try await signUp("Admin")
        let stored = try await UserTokenModel.query(on: app.db).all().map(\.tokenHash)
        XCTAssertEqual(stored, [Tokens.hash(user.token)])
    }

    func testAdminInviteFromEnvironment() async throws {
        try await restart { $0.adminInvite = "mci_first-admin" }

        let admin = try await post("v1/auth/redeem", RedeemInviteRequest(code: "mci_first-admin", name: "Owner"), as: UserToken.self)
        try await assertEqual(try await meInfo(admin.token).isAdmin, true)

        // Once there is an admin, a restart with the same env creates nothing new.
        try await AuthController.ensureAdminInvite("mci_first-admin", on: app.db, maccheri: app.maccheri, logger: app.logger)
        try await assertEqual(try await InviteModel.query(on: app.db).count(), 1)
    }

    func testSharedTokenActsAsTeamAdmin() async throws {
        try await restart { $0.sharedToken = "team-secret" }

        let team = UserToken(userID: AuthController.teamUserID, token: "team-secret")
        try await assertEqual(try await meInfo(team.token), UserInfo(id: AuthController.teamUserID, name: "team", isAdmin: true))
        let host = try await enrollHost("mini", owner: team)
        let session = try await createSession(team)
        try await assertEqual(try await work(host)?.simulator?.sessionID, session.id)
        try await assertEqual(try await status(.GET, "v1/me", token: "team-secre"), .unauthorized)
        try await assertEqual(try await status(.POST, "agent/v1/heartbeat", Heartbeat(agentVersion: "x", capacity: Self.capacity()), token: "team-secret"), .unauthorized,
                       "agent calls need the host's own token")
    }

    func testHostsEnrollHeartbeatAndGoOffline() async throws {
        let owner = try await signUp("Owner")
        let host = try await enrollHost("Mac mini", owner: owner, capacity: Self.capacity(warmVMs: 1))
        XCTAssertTrue(host.agentToken.hasPrefix("mca_"))

        var hosts = try await listHosts(owner)
        XCTAssertEqual(hosts, [HostInfo(id: host.hostID, name: "Mac mini", ownerName: "Owner", hardware: Self.hardware, online: true, capacity: Self.capacity(warmVMs: 1))])

        clock.advance(seconds: TimeInterval(HostAPI.offlineAfterSeconds + 1))
        hosts = try await listHosts(owner)
        XCTAssertEqual(hosts.first?.online, false)

        _ = try await heartbeat(host)
        hosts = try await listHosts(owner)
        XCTAssertEqual(hosts.first?.online, true)
        XCTAssertEqual(hosts.first?.capacity?.warmVMs, 0)
    }

    func testAgentCallsNeedHostToken() async throws {
        let owner = try await signUp("Owner")
        try await assertEqual(try await status(.POST, "agent/v1/heartbeat", Heartbeat(agentVersion: "x", capacity: Self.capacity()), token: owner.token), .unauthorized)
        try await assertEqual(try await status(.POST, "agent/v1/work", LeaseRequest(labels: [], freeSlots: 1), token: legacyAgentToken), .unauthorized, "env tokens only work on the legacy lease")
    }

    func testOfflineHostGetsNoWork() async throws {
        let owner = try await signUp("Owner")
        let host = try await enrollHost("mini", owner: owner)
        clock.advance(seconds: 60)
        let session = try await createSession(owner)
        // Polling marks it online again, but a full slot count is still required.
        try await assertNil(try await work(host, freeSlots: 0))
        try await assertEqual(try await work(host)?.simulator?.sessionID, session.id)
    }

    private func meInfo(_ token: String) async throws -> UserInfo {
        var info: UserInfo!
        try await app.test(.GET, "v1/me", headers: ["Authorization": "Bearer \(token)"]) { res async throws in
            XCTAssertEqual(res.status, .ok)
            info = try res.content.decode(UserInfo.self)
        }
        return info
    }

    private func listHosts(_ user: UserToken) async throws -> [HostInfo] {
        var hosts: [HostInfo] = []
        try await app.test(.GET, "v1/hosts", headers: ["Authorization": "Bearer \(user.token)"]) { res async throws in
            XCTAssertEqual(res.status, .ok)
            hosts = try res.content.decode([HostInfo].self)
        }
        return hosts
    }
}
