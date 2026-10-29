// DeviceReportParser.swift
// AmachHealth
//
// Report parsing, end to end encrypted (VENICE-E2EE.md). The website's own
// parser (src/utils/reportParsers, bundled by its
// scripts/build-device-parser.mjs and shipped in the app as
// ReportParserBundle.source) runs here in JavaScriptCore, so sections,
// prompts, merging and the hallucination guard are the server's code, not a
// port. Only its model calls change: each one is encrypted on the phone to
// an attested Venice enclave key and sent through the ciphertext relay
// (/api/ai/e2ee), so Amach's servers never see report text.
//
// Off by default (`PrivateReportParsing.isEnabled`); the app keeps
// /api/health/parse-report when it's off. With it on there is no fallback to
// the server: a failure is an error, nothing is sent in plaintext. Report
// types the encrypted path can't serve in time yet (`serverOnlyTiers`) are
// sent to the server from the start.

import Foundation
import JavaScriptCore
import VeniceE2EE

enum PrivateReportParsing {
    static let defaultsKey = "LumaE2EEParse"

    /// Off unless the `LumaE2EEParse` default is set (launch argument
    /// `-LumaE2EEParse YES`).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Model tiers the encrypted path can't serve yet; reports that need one
    /// stay on /api/health/parse-report, chosen up front from the report's
    /// type (never as a retry after an encrypted failure).
    ///
    /// parseLong (e2ee-glm-5-3-p, gut-microbiome reports): measured
    /// 2026-10-28, an encrypted call runs alone at 30-131 s, but a species
    /// section writing hundreds of rows ran past 10 minutes, far over the
    /// relay's 300 s limit on Vercel; the same calls take under 2 minutes in
    /// total on the server path. Remove it here once that changes.
    static let serverOnlyTiers: Set<String> = ["parseLong"]
}

/// One model call from the parser: prompt-only JSON, the relay picks models.
struct ReportParseCall: Decodable, Equatable {
    enum Tier: String, Decodable { case parseText, parseLong }
    struct Message: Decodable, Equatable {
        let role: String
        let content: String
    }

    let tier: Tier
    let messages: [Message]
    let max_tokens: Int
    let temperature: Double
}

/// A model's answer to one parse call.
struct ReportParseReply: Equatable {
    let content: String
    /// The enclave model that served it (shown on the review screen).
    let model: String?
}

/// Where the parser's model calls go. Tests inject a fake.
protocol ReportParseTransport: Sendable {
    /// Throws APIError.enclaveBusy / .aiCreditExhausted.
    func complete(_ call: ReportParseCall) async throws -> ReportParseReply
}

// MARK: - Encrypted transport

/// At most `limit` holders at a time; the rest wait in order.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

final class E2EEReportParseTransport: ReportParseTransport, @unchecked Sendable {
    /// Encrypted parse calls in flight at once, per tier. An encrypted
    /// request goes to the one enclave whose key it was sealed to, so a
    /// report's sections queue there instead of spreading over Venice's pool.
    /// Measured 2026-10-28 through the relay:
    /// - parseLong (e2ee-glm-5-3-p, gut reports): 30-131 s per call alone,
    ///   but 370 s with three in flight and up to 512 s with all 14 sections
    ///   at once (six passed the relay's 300 s limit). The enclave serves
    ///   about one call at a time, so more in flight only stretches each.
    /// - parseText (e2ee-gpt-oss-120b-p, DEXA and lab panels): six sections at
    ///   once finished in 25-30 s.
    static func maxConcurrentCalls(_ tier: ReportParseCall.Tier) -> Int {
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["AMACH_E2EE_PARSE_CONCURRENCY"].flatMap(Int.init), n > 0 {
            return n
        }
        #endif
        switch tier {
        case .parseLong: return 1
        case .parseText: return 3
        }
    }

    private let client: VeniceE2EEClient
    private let limiters: [ReportParseCall.Tier: AsyncLimiter] = [
        .parseLong: AsyncLimiter(limit: E2EEReportParseTransport.maxConcurrentCalls(.parseLong)),
        .parseText: AsyncLimiter(limit: E2EEReportParseTransport.maxConcurrentCalls(.parseText)),
    ]

    /// Its own client, so parsing doesn't touch chat's. A report's sections
    /// share it: each model is attested once for all of them (its debug
    /// stats then describe whichever call finished last).
    init(client: VeniceE2EEClient = VeniceE2EEClient(relayURL: LumaPrivateChat.relayURL,
                                                       authorizer: LumaRelayAuthorizer())) {
        self.client = client
    }

    func complete(_ call: ReportParseCall) async throws -> ReportParseReply {
        let wire = try call.messages.map { m -> VeniceE2EEMessage in
            guard let role = VeniceE2EEMessage.Role(rawValue: m.role) else {
                throw APIError.requestFailed("Unexpected message role from the report parser.")
            }
            return VeniceE2EEMessage(role: role, content: m.content)
        }
        // The wallet key never leaves the phone, encrypted or not.
        try OutboundSecretGuard.check(JSONEncoder().encode(wire))
        let limiter = limiters[call.tier]!
        await limiter.acquire()
        do {
            let reply = try await send(call, wire)
            await limiter.release()
            return reply
        } catch {
            await limiter.release()
            throw error
        }
    }

    private func send(_ call: ReportParseCall, _ wire: [VeniceE2EEMessage]) async throws -> ReportParseReply {
        #if DEBUG
        let started = Date()
        #endif
        do {
            var reply = ""
            var servedBy: String?
            // Streamed: a long report takes minutes, and a quiet connection
            // that long is more likely to be cut than one that keeps talking.
            for try await event in try await client.send(tier: call.tier.rawValue, messages: wire, stream: true,
                                                          maxTokens: call.max_tokens,
                                                          temperature: call.temperature) {
                switch event {
                case .delta(let text): reply += text
                case let .served(model, provider):
                    servedBy = model
                    #if DEBUG
                    print("🔒 [Parse E2EE] \(call.tier.rawValue) served by \(model) (\(provider ?? "?"))")
                    #endif
                case .done: break
                }
            }
            #if DEBUG
            let stats = await client.lastStats
            // Parallel calls share the client, so these are its latest stats.
            print("🔒 [Parse E2EE] \(call.tier.rawValue) done in \(Int(Date().timeIntervalSince(started)))s " +
                  "skipped=\(stats.skipped.keys.sorted()) " +
                  "encrypted=\(stats.encryptedChunks) plaintext=\(stats.plaintextChunks)")
            #endif
            return ReportParseReply(content: reply, model: servedBy)
        } catch {
            #if DEBUG
            print("🔒 [Parse E2EE] \(call.tier.rawValue) failed after \(Int(Date().timeIntervalSince(started)))s: \(error)")
            #endif
            throw LumaPrivateChat.mapError(error)
        }
    }
}

// MARK: - JavaScriptCore host

/// Runs the bundled parser. One JSContext, used only on `queue`.
final class DeviceReportParser: @unchecked Sendable {
    static let shared = DeviceReportParser(transport: E2EEReportParseTransport())

    enum HostError: Error, Equatable {
        case bundleTampered
        case script(String)
        case noResult
    }

    private let transport: ReportParseTransport
    private let source: String
    private let expectedSHA256: String
    private let queue = DispatchQueue(label: "com.amach.report-parser.js")
    private var context: JSContext?

    init(transport: ReportParseTransport,
         source: String = ReportParserBundle.source,
         sha256: String = ReportParserBundle.sha256) {
        self.transport = transport
        self.source = source
        self.expectedSHA256 = sha256
    }

    /// The model tiers parsing `text` would use (no model is called).
    func tiers(text: String, reportType: String?) async throws -> Set<String> {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
            queue.async {
                do {
                    let ctx = try self.loadedContext()
                    guard let parser = ctx.objectForKeyedSubscript("AmachReportParser"),
                          let json = parser.invokeMethod("tiers", withArguments: [text, reportType ?? NSNull()])?.toString(),
                          let tiers = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else {
                        throw HostError.noResult
                    }
                    if let exception = ctx.exception {
                        ctx.exception = nil
                        throw HostError.script(exception.toString() ?? "exception")
                    }
                    continuation.resume(returning: Set(tiers))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Parses report text. Returns the parse-report route's JSON body.
    func parse(text: String, reportType: String?, sourceName: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                do {
                    let ctx = try self.loadedContext()
                    guard let parser = ctx.objectForKeyedSubscript("AmachReportParser"),
                          let promise = parser.invokeMethod("parse", withArguments: [
                              text, reportType ?? NSNull(), sourceName ?? NSNull(),
                          ]) else { throw HostError.noResult }
                    var finished = false
                    let onDone: @convention(block) (JSValue) -> Void = { value in
                        guard !finished else { return }
                        finished = true
                        if let json = value.toString(), let data = json.data(using: .utf8) {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: HostError.noResult)
                        }
                    }
                    let onFail: @convention(block) (JSValue) -> Void = { value in
                        guard !finished else { return }
                        finished = true
                        continuation.resume(throwing: HostError.script(value.toString() ?? "unknown"))
                    }
                    promise.invokeMethod("then", withArguments: [
                        JSValue(object: onDone, in: ctx)!, JSValue(object: onFail, in: ctx)!,
                    ])
                    if let exception = ctx.exception {
                        ctx.exception = nil
                        throw HostError.script(exception.toString() ?? "exception")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Called on `queue`.
    private func loadedContext() throws -> JSContext {
        if let context { return context }
        // Compiled into the app, so this only catches a build that bundled a
        // file other than the one synced (scripts/sync-report-parser.py).
        guard Self.sha256Hex(source) == expectedSHA256 else { throw HostError.bundleTampered }
        let ctx = JSContext()!
        ctx.name = "Amach report parser"
        installHost(in: ctx)
        ctx.evaluateScript(source, withSourceURL: URL(string: "amach://report-parser.js"))
        if let exception = ctx.exception {
            ctx.exception = nil
            throw HostError.script(exception.toString() ?? "exception")
        }
        context = ctx
        return ctx
    }

    private func installHost(in ctx: JSContext) {
        let queue = self.queue
        let transport = self.transport

        // console: the parser logs tags and counts, not contents. Debug only.
        let log: @convention(block) () -> Void = {
            #if DEBUG
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            print("🧩 [Parser] " + parts.joined(separator: " "))
            #endif
        }
        let console = JSValue(newObjectIn: ctx)!
        for name in ["log", "info", "warn", "error", "debug"] {
            console.setObject(log, forKeyedSubscript: name as NSString)
        }
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        let setTimeout: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms)))) {
                fn.call(withArguments: [])
            }
        }
        ctx.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)

        // __amachNative.venice(requestJSON, resolve(content, model), reject(errorJSON))
        let venice: @convention(block) (String, JSValue, JSValue) -> Void = { json, resolve, reject in
            Task {
                let settle: (JSValue, [Any]) -> Void = { fn, args in
                    queue.async { fn.call(withArguments: args) }
                }
                do {
                    let call = try JSONDecoder().decode(ReportParseCall.self, from: Data(json.utf8))
                    let reply = try await transport.complete(call)
                    settle(resolve, [reply.content, reply.model ?? NSNull()])
                } catch {
                    settle(reject, [Self.errorJSON(error)])
                }
            }
        }
        let native = JSValue(newObjectIn: ctx)!
        native.setObject(venice, forKeyedSubscript: "venice" as NSString)
        ctx.setObject(native, forKeyedSubscript: "__amachNative" as NSString)
    }

    /// The bridge's error shape (entry.ts NativeError). No report contents.
    static func errorJSON(_ error: Error) -> String {
        var out: [String: Any] = [:]
        switch error {
        case APIError.enclaveBusy:
            out["code"] = APIError.enclaveBusyCode
        case APIError.aiCreditExhausted(let resetsAt):
            out["code"] = APIError.aiCreditExhaustedCode
            if let resetsAt { out["resetsAt"] = ISO8601DateFormatter.withFractionalSeconds.string(from: resetsAt) }
        case APIError.httpError(let status):
            out["status"] = status
            out["message"] = "The private AI returned \(status)."
        case APIError.secretInRequest:
            out["code"] = "secret_in_request"
            out["message"] = "Refused to send a request that contained the wallet key."
        default:
            out["message"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func sha256Hex(_ text: String) -> String {
        LabVaultMapping.sha256Hex(Data(text.utf8))
    }
}
