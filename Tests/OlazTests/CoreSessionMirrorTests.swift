import Foundation
import OlazCore
import Testing
@testable import Olaz

@Suite struct CoreSessionMirrorTests {
    @Test @MainActor func applyAccountProfileRoundTripsThroughCoreEngineMirror() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        defer { engine.stopCoreEngine() }

        #expect(engine.phase == .starting)
        #expect(engine.profile == nil)

        await engine.applyAccountProfile(ZaloLoginAccount(
            userId: "u42",
            displayName: "",
            avatar: "",
            phone: "",
            send2MeId: ""
        ))

        #expect(engine.profile?.userId == "u42")
        #expect(engine.profile?.displayName == "Người dùng Zalo")
        #expect(engine.profile?.avatar == nil)
        #expect(engine.profile?.phone == nil)
        #expect(engine.selfConversationId == "u42")
        #expect(engine.clientVersion == "694 (Native)")

        await engine.applyAccountProfile(ZaloLoginAccount(
            userId: "u42",
            displayName: "Minh Anh",
            avatar: "https://cdn.example.test/avt.jpg",
            phone: "+84901234567",
            send2MeId: "s2m-42"
        ))

        #expect(engine.profile?.displayName == "Minh Anh")
        #expect(engine.profile?.avatar == URL(string: "https://cdn.example.test/avt.jpg"))
        #expect(engine.profile?.phone == "+84901234567")
        #expect(engine.selfConversationId == "s2m-42")
    }

    @Test func renderFailReasonMatchesRustCoreMapError() {
        #expect(
            ZaloEngine.renderFailReason(.text(message: "Đăng nhập đã bị từ chối trên điện thoại."))
                == "Đăng nhập đã bị từ chối trên điện thoại."
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .network(kind: .other)))
                == RustCore.mapError(CoreError.Network(kind: .other, message: "")).localizedDescription
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .session(
                code: -1,
                message: "Không tạo được mã QR",
                url: "/api/login/reqqr"
            ))) == "Zalo error -1: Không tạo được mã QR (/api/login/reqqr)"
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .http(status: 502)))
                == "Lỗi máy chủ HTTP 502."
        )
    }

    @Test @MainActor func nextChangesDeliveryLatencyMeasurement() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        defer { engine.stopCoreEngine() }

        // Warm up CoreEngine creation and the first next_changes() poll.
        await engine.applyAccountProfile(ZaloLoginAccount(userId: "warmup", displayName: "Warmup"))
        #expect(engine.profile?.userId == "warmup")

        let iterations = 100
        let clock = ContinuousClock()
        var samplesUs: [Double] = []
        samplesUs.reserveCapacity(iterations)

        for i in 0..<iterations {
            let start = clock.now
            await engine.applyAccountProfile(ZaloLoginAccount(
                userId: "bench-\(i)",
                displayName: "User \(i)"
            ))
            let elapsed = start.duration(to: clock.now)
            let secs = Double(elapsed.components.seconds)
            let attos = Double(elapsed.components.attoseconds) / 1e18
            samplesUs.append((secs + attos) * 1_000_000.0)
        }

        #expect(engine.profile?.userId == "bench-\(iterations - 1)")
        let sorted = samplesUs.sorted()
        let minUs = sorted.first ?? 0
        let p50Us = sorted[sorted.count / 2]
        let p95Us = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxUs = sorted.last ?? 0
        print(String(
            format: "PERF next_changes delivery (n=%d): min=%.1f us p50=%.1f us p95=%.1f us max=%.1f us",
            iterations, minUs, p50Us, p95Us, maxUs
        ))
        // Generous sanity cap so debug builds never flake while catching real stalls.
        #expect(p50Us < 50_000.0)
    }
}
