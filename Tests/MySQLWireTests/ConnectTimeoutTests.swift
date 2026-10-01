import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import MySQLWire

/// A server that accepts the TCP connection and never sends its greeting must not hang the caller.
@Suite struct ConnectTimeoutTests {
    /// Accepts connections and reads nothing, writes nothing.
    final class SilentHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
    }

    @Test func silentServerFailsWithinTheConnectTimeout() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(SilentHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)

        let configuration = MySQLWireConfiguration(host: "127.0.0.1", port: port, username: "root", password: "x",
                                                   tlsMode: .disabled, connectTimeoutSeconds: 1)
        let started = ContinuousClock.now
        await #expect(throws: MySQLWireError.self) {
            _ = try await MySQLWireConnection.connect(configuration: configuration)
        }
        #expect(ContinuousClock.now - started < .seconds(5))

        try await listener.close()
        try await group.shutdownGracefully()
    }

    @Test func refusedPortFailsAtOnce() async throws {
        // Bind and close to get a port nothing listens on.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        try await listener.close()
        try await group.shutdownGracefully()

        let configuration = MySQLWireConfiguration(host: "127.0.0.1", port: port, username: "root", tlsMode: .disabled,
                                                   connectTimeoutSeconds: 10)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await MySQLWireConnection.connect(configuration: configuration) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
