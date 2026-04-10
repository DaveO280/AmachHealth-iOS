// AmachAPIClient+AIReportParsing.swift
// AmachHealth
//
// Calls the website's /api/health/parse-report endpoint which runs
// Venice AI + regex merge to produce high-quality parsed health data.
// Used as the primary parsing path; local regex is the offline fallback.

import Foundation

extension AmachAPIClient {

    // MARK: - Request / Response types

    private struct ParseReportRequest: Encodable {
        let text: String
        let reportType: String?
        let sourceName: String?
    }

    private struct ParseReportResponse: Decodable {
        let success: Bool
        let reports: [ParsedReportSummary]?
        let error: String?
    }

    private struct ParsedReportSummary: Decodable {
        let report: ReportPayload
        let extractedAt: String?

        struct ReportPayload: Decodable {
            let type: String  // "dexa" or "bloodwork"

            // Decode the full JSON so we can re-decode as the specific type
            private let _data: Data

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(AnyCodableValue.self)
                self._data = try JSONEncoder().encode(raw)
                // Extract type from the raw dict
                if let dict = try? JSONSerialization.jsonObject(with: _data) as? [String: Any],
                   let t = dict["type"] as? String {
                    self.type = t
                } else {
                    self.type = "unknown"
                }
            }

            func decode<T: Decodable>(as: T.Type) throws -> T {
                try JSONDecoder().decode(T.self, from: _data)
            }
        }
    }

    /// Helper for round-tripping arbitrary JSON through Codable
    private struct AnyCodableValue: Codable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: AnyCodableValue].self) {
                value = dict.mapValues(\.value)
            } else if let arr = try? container.decode([AnyCodableValue].self) {
                value = arr.map(\.value)
            } else if let str = try? container.decode(String.self) {
                value = str
            } else if let num = try? container.decode(Double.self) {
                value = num
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if container.decodeNil() {
                value = NSNull()
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case let dict as [String: Any]:
                try container.encode(dict.mapValues { AnyCodableValue(value: $0) })
            case let arr as [Any]:
                try container.encode(arr.map { AnyCodableValue(value: $0) })
            case let str as String:
                try container.encode(str)
            case let num as Double:
                try container.encode(num)
            case let num as Int:
                try container.encode(num)
            case let bool as Bool:
                try container.encode(bool)
            case is NSNull:
                try container.encodeNil()
            default:
                try container.encodeNil()
            }
        }

        init(value: Any) { self.value = value }
    }

    // MARK: - Public

    /// Parse PDF text using the website's AI+regex merge pipeline.
    /// Returns nil if the endpoint returns no reports.
    func parseReportWithAI(
        text: String,
        reportType: String? = nil,
        sourceName: String? = nil
    ) async throws -> ParsedHealthReport? {
        let request = ParseReportRequest(
            text: text,
            reportType: reportType,
            sourceName: sourceName
        )

        let response: ParseReportResponse = try await post(
            path: "/api/health/parse-report",
            body: request
        )

        guard response.success, let reports = response.reports, let first = reports.first else {
            if let error = response.error {
                throw APIError.requestFailed(error)
            }
            return nil
        }

        switch first.report.type {
        case "dexa":
            let dexa = try first.report.decode(as: DexaReportData.self)
            return .dexa(dexa)
        case "bloodwork":
            let bw = try first.report.decode(as: BloodworkReportData.self)
            return .bloodwork(bw)
        default:
            return nil
        }
    }
}
