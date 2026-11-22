import Foundation

struct ZaloCloudServerSnapshot: Sendable, Equatable {
    var planKind: CloudState.PlanKind
    var planName: String
    var quota: Int64
    var usage: Int64
    var family: Int64
    var cloudMedia: Int64
    var messageBackup: Int64
    var myCloud: Int64
    var expireAt: Date?
    var autoRenew: Bool?
    var months: Int
    var backupMedia: Bool
    var backupMyCloud: Bool
    var backupMessages: Bool
    var enableOffload: Bool
    var fileLimit: Int64
}

extension ZaloSessionClient {
    static func parseCloudUsageSnapshot(
        usagePayload: [String: Any],
        settingsPayload: [String: Any]?,
        infoPayload: [String: Any]?,
        familyUsagePayload: Any?,
        myUid: String
    ) -> ZaloCloudServerSnapshot? {
        guard !usagePayload.isEmpty,
              usagePayload["plan"] != nil
                || usagePayload["quota"] != nil
                || usagePayload["usage"] != nil
                || usagePayload["service_usage"] != nil else {
            return nil
        }

        let planInt = JSONLossless.int64(usagePayload["plan"]).map(Int.init) ?? -1
        let planKind: CloudState.PlanKind = switch planInt {
        case 0: .paid
        case 100: .grace
        case 69: .afterGrace
        default: .free
        }

        let serviceUsage = usagePayload["service_usage"] as? [String: Any] ?? [:]
        let suCloudMedia = max(0, JSONLossless.int64(serviceUsage["cloud_media"]) ?? 0)
        let suBackup = max(0, JSONLossless.int64(serviceUsage["message_backup"]) ?? 0)
        let suMyCloud = max(0, JSONLossless.int64(serviceUsage["my_cloud"]) ?? 0)
        let rawQuota = max(0, JSONLossless.int64(usagePayload["quota"]) ?? 0)
        let rawUsage = max(0, JSONLossless.int64(usagePayload["usage"]) ?? 0)

        let cloudMedia: Int64
        let messageBackup: Int64
        let myCloud: Int64
        let usage: Int64
        let family: Int64
        let quota: Int64
        let planName: String

        let isPaidPlan = (planKind == .paid || planKind == .grace)
        if !isPaidPlan {
            cloudMedia = 0
            messageBackup = 0
            family = 0
            if suMyCloud > 0 {
                myCloud = suMyCloud
            } else if serviceUsage["my_cloud"] != nil || suCloudMedia > 0 || suBackup > 0 {
                myCloud = 0
            } else {
                myCloud = rawUsage
            }
            usage = myCloud
            quota = rawQuota > 0 ? rawQuota : 1_073_741_824
            planName = "Cloud của tôi"
        } else {
            cloudMedia = suCloudMedia
            messageBackup = suBackup
            myCloud = suMyCloud
            usage = rawUsage > 0 ? rawUsage : (cloudMedia + messageBackup + myCloud)
            quota = rawQuota

            if let directFamily = JSONLossless.int64(usagePayload["family"]), directFamily > 0 {
                family = directFamily
            } else {
                family = sumOtherFamilyUsage(from: familyUsagePayload, myUid: myUid)
            }
            planName = resolvePlanName(from: infoPayload, planKind: planKind)
        }

        let backupMedia: Bool
        let backupMyCloud: Bool
        let backupMessages: Bool
        if let optIn = JSONLossless.int64(settingsPayload?["opt_in"]) {
            backupMedia = (optIn & 1) != 0
            backupMyCloud = (optIn & 2) != 0
            backupMessages = (optIn & 4) != 0
        } else {
            backupMedia = isPaidPlan
            backupMyCloud = true
            backupMessages = true
        }

        let enableOffload = (JSONLossless.int64(settingsPayload?["enable_offload"]) ?? 0) == 1
        let rawLimit = JSONLossless.int64(settingsPayload?["cloud_media_file_size_limit"]) ?? 0
        let fileLimit = rawLimit > 0 ? rawLimit : (isPaidPlan ? 1_073_741_824 : 100 * 1_048_576)

        let sub = infoPayload?["subscription_info"] as? [String: Any]
        let expireAt: Date? = {
            guard let rawExp = JSONLossless.int64(sub?["expire_time"]), rawExp > 0 else { return nil }
            let sec = rawExp > 10_000_000_000 ? Double(rawExp) / 1000.0 : Double(rawExp)
            return Date(timeIntervalSince1970: sec)
        }()

        let autoRenew: Bool? = {
            guard let sub else { return nil }
            let prod = JSONLossless.string(sub["auto_renew_product_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sub["cancelled_renew"] == nil && prod.isEmpty {
                return nil
            }
            let cancelled = JSONLossless.bool(sub["cancelled_renew"]) ?? false
            return !cancelled && !prod.isEmpty
        }()

        let months = Int(JSONLossless.int64(sub?["duration_months"]) ?? 0)

        return ZaloCloudServerSnapshot(
            planKind: planKind,
            planName: planName,
            quota: quota,
            usage: usage,
            family: family,
            cloudMedia: cloudMedia,
            messageBackup: messageBackup,
            myCloud: myCloud,
            expireAt: expireAt,
            autoRenew: autoRenew,
            months: months,
            backupMedia: backupMedia,
            backupMyCloud: backupMyCloud,
            backupMessages: backupMessages,
            enableOffload: enableOffload,
            fileLimit: fileLimit
        )
    }

    private static func sumOtherFamilyUsage(from payload: Any?, myUid: String) -> Int64 {
        let rows: [[String: Any]]
        if let arr = payload as? [[String: Any]] {
            rows = arr
        } else if let dict = payload as? [String: Any] {
            if let members = dict["members"] as? [[String: Any]] {
                rows = members
            } else if let data = dict["data"] as? [[String: Any]] {
                rows = data
            } else {
                rows = []
            }
        } else {
            rows = []
        }

        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        var total: Int64 = 0
        for row in rows {
            let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["uid"] ?? row["userId"]))
            if !cleanMe.isEmpty && !uid.isEmpty && uid == cleanMe {
                continue
            }
            let used = max(0, JSONLossless.int64(row["usage"] ?? row["total"]) ?? 0)
            total += used
        }
        return total
    }

    private static func resolvePlanName(from infoPayload: [String: Any]?, planKind: CloudState.PlanKind) -> String {
        if planKind == .grace {
            return "zCloud"
        }
        guard let info = infoPayload else { return "zCloud" }
        let pkg = info["package_info"] as? [String: Any]
        let sub = info["subscription_info"] as? [String: Any]
        let candidates: [Any?] = [
            info["package_name"],
            info["plan_name"],
            pkg?["name"],
            sub?["package_name"],
            sub?["name"],
            info["name"],
        ]
        for candidate in candidates {
            if let dict = candidate as? [String: Any] {
                let vi = JSONLossless.string(dict["vi"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !vi.isEmpty { return vi }
                let en = JSONLossless.string(dict["en"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !en.isEmpty { return en }
            }
            let s = JSONLossless.string(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return "zCloud"
    }

    func fetchCloudViewerKey(forceRefresh: Bool = false) async throws -> (viewerKey: String, enk: String) {
        if !forceRefresh,
           let cachedKey = cloudViewerKey, !cachedKey.isEmpty,
           let cachedEnk = cloudEnk, !cachedEnk.isEmpty {
            return (cachedKey, cachedEnk)
        }

        let resp = try await get(service: "auth", path: "/api/getCloudViewerKey")
        let d = (resp["data"] as? [String: Any]) ?? resp
        let vk = JSONLossless.string(d["viewer_key"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let ek = JSONLossless.string(d["enk"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vk.isEmpty, !ek.isEmpty else {
            throw ZaloSessionError(code: -205, message: "Thiếu khóa truy cập zCloud.", url: "/api/getCloudViewerKey")
        }
        cloudViewerKey = vk
        cloudEnk = ek
        return (vk, ek)
    }

    func zCloudGet(path: String, queryParams: [String: String] = [:], retryOnExpiredKey: Bool = true) async throws -> Any? {
        let (viewerKey, enk) = try await fetchCloudViewerKey(forceRefresh: false)
        var suffix = "\(path)?\(commonParams())"
        for (k, v) in queryParams.sorted(by: { $0.key < $1.key }) {
            suffix += "&\(k)=\(Self.urlEncode(v))"
        }

        let hosts = domains.candidates(for: "zcloud")
        var lastError: Error = ZaloTransportError.invalidURL("zcloud")

        for host in hosts {
            let fullURLString = "\(host)\(suffix)"
            guard let url = URL(string: fullURLString) else { continue }
            do {
                let (status, data, _) = try await rawRequest(
                    method: "GET",
                    url: url,
                    body: nil,
                    contentType: nil,
                    extraHeaders: ["cloud-viewer-key": viewerKey]
                )
                if status == 404 {
                    lastError = ZaloTransportError.httpError(404, "")
                    continue
                }
                guard (200..<300).contains(status) else {
                    throw ZaloTransportError.httpError(status, String(decoding: data.prefix(200), as: UTF8.self))
                }
                guard let parsed = JSONLossless.parseObject(data) else {
                    throw ZaloTransportError.invalidJSON
                }
                if let code = JSONLossless.int64(parsed["error_code"]).map(Int.init), code != 0 {
                    if code == -1 || code == -205 {
                        if retryOnExpiredKey {
                            cloudViewerKey = nil
                            cloudEnk = nil
                            return try await zCloudGet(path: path, queryParams: queryParams, retryOnExpiredKey: false)
                        }
                    }
                    if code == -904 {
                        domains.rememberWinner(for: "zcloud", host: host)
                        return nil
                    }
                    let msg = JSONLossless.string(parsed["error_message"])
                    throw ZaloSessionError(code: code, message: msg, url: url.path)
                }

                domains.rememberWinner(for: "zcloud", host: host)
                let rawData = parsed["data"]
                if let cipherStr = rawData as? String {
                    let trimmed = cipherStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return nil }
                    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                        return trimmed.data(using: .utf8).flatMap(JSONLossless.parseAny)
                    }
                    let plain = try ZaloCrypto.decodeCloudAES(base64Key: enk, base64Cipher: trimmed)
                    let trimmedPlain = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedPlain.isEmpty { return nil }
                    return trimmedPlain.data(using: .utf8).flatMap(JSONLossless.parseAny)
                }
                if rawData is NSNull || rawData == nil {
                    return nil
                }
                return rawData
            } catch let err as ZaloSessionError {
                throw err
            } catch {
                if Self.shouldFailover(error) {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    func fetchCloudServerSnapshot() async -> ZaloCloudServerSnapshot? {
        guard let me = account, !me.userId.isEmpty else { return nil }
        guard let myCloudRaw = try? await zCloudGet(path: "/cloudmedia/info/pc/v1/usage-mycloud"),
              var usageDict = myCloudRaw as? [String: Any] else {
            return nil
        }

        let initialPlan = JSONLossless.int64(usageDict["plan"]).map(Int.init) ?? -1
        if [0, 100, 69].contains(initialPlan),
           let v2Raw = try? await zCloudGet(path: "/cloudmedia/info/pc/v2/usage"),
           var v2Dict = v2Raw as? [String: Any] {
            if initialPlan == 69, (JSONLossless.int64(v2Dict["quota"]) ?? 0) <= 0,
               let myQuota = usageDict["quota"] {
                v2Dict["quota"] = myQuota
            }
            usageDict = v2Dict
        }

        let effectivePlan = JSONLossless.int64(usageDict["plan"]).map(Int.init) ?? initialPlan
        let settingsDict = (try? await zCloudGet(path: "/cloudmedia/info/pc/v1/cloud-settings")) as? [String: Any]

        var infoDict: [String: Any]? = nil
        var familyPayload: Any? = nil
        if effectivePlan == 0 || effectivePlan == 100 {
            infoDict = (try? await zCloudGet(path: "/zalocloud/cloudinfopcweb/v1/info")) as? [String: Any]
            familyPayload = try? await zCloudGet(path: "/cloudmedia/info/pc/v1/family-usage")
        }

        return Self.parseCloudUsageSnapshot(
            usagePayload: usageDict,
            settingsPayload: settingsDict,
            infoPayload: infoDict,
            familyUsagePayload: familyPayload,
            myUid: me.userId
        )
    }
}
