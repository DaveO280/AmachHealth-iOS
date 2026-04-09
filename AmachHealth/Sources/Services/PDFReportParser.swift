// PDFReportParser.swift
// AmachHealth
//
// Extracts text from a PDF using PDFKit, then normalizes the text into
// BloodworkReportData or DexaReportData (matching the website's report types).
//
// Detection heuristic: DEXA keyword set wins if present; otherwise bloodwork.
// Parsing uses regex + common lab report patterns (Quest, LabCorp, Hologic, GE Lunar).

import Foundation
import PDFKit

// MARK: - Parser

enum PDFReportParser {

    // MARK: - Public API

    /// Extract text from a PDF data blob using PDFKit.
    /// Returns the full concatenated text from all pages.
    static func extractText(from pdfData: Data) -> String {
        guard let document = PDFDocument(data: pdfData) else { return "" }
        var pages: [String] = []
        for i in 0 ..< document.pageCount {
            guard let page = document.page(at: i) else { continue }
            pages.append(page.string ?? "")
        }
        return pages.joined(separator: "\n")
    }

    /// Parse PDF data into a structured health report.
    /// Returns nil if the text does not contain recognizable health data.
    static func parse(pdfData: Data, filename: String = "") -> ParsedHealthReport? {
        let text = extractText(from: pdfData)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parseText(text, filename: filename)
    }

    /// Parse pre-extracted text (useful for testing without a real PDF).
    static func parseText(_ text: String, filename: String = "") -> ParsedHealthReport? {
        if isDexaReport(text: text, filename: filename) {
            let report = parseDexaText(text)
            return report.regions.isEmpty && report.totalBodyFatPercent == nil ? nil : .dexa(report)
        }
        let bloodwork = parseBloodworkText(text)
        return bloodwork.metrics.isEmpty ? nil : .bloodwork(bloodwork)
    }

    // MARK: - Report type detection

    private static func isDexaReport(text: String, filename: String) -> Bool {
        let lower = (text + " " + filename).lowercased()
        let dexaKeywords = ["dexa", "dxa", "dual energy", "bone density", "body composition scan",
                            "lean mass", "fat mass", "visceral fat", "t-score", "z-score",
                            "android", "gynoid", "hologic", "ge lunar", "norland"]
        let dexaHits = dexaKeywords.filter { lower.contains($0) }.count
        return dexaHits >= 2
    }

    // MARK: - Bloodwork parsing

    static func parseBloodworkText(_ text: String) -> BloodworkReportData {
        let lines = text.components(separatedBy: .newlines)
        var metrics: [BloodworkMetric] = []
        var laboratory: String?
        var reportDate: String?
        var currentPanel: String?

        // Date pattern: various formats (ISO YYYY-MM-DD checked first)
        let datePatterns = [
            #"(?:Date of Service|Collection Date|Report Date|Date)[:\s]+(\d{4}[\-\/]\d{1,2}[\-\/]\d{1,2})"#,
            #"(?:Date of Service|Collection Date|Report Date|Date)[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#,
            #"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4})"#,
        ]

        // Lab name patterns
        let labPatterns = [
            #"(Quest Diagnostics|LabCorp|BioReference|ARUP|Mayo Clinic|Sonora Quest|Labcorp)"#,
            #"(Laboratory|Lab|Diagnostics)[:\s]*([A-Z][A-Za-z\s]+)"#,
        ]

        // Panel header pattern (e.g., "COMPREHENSIVE METABOLIC PANEL")
        let panelPattern = try? NSRegularExpression(
            pattern: #"^([A-Z][A-Z\s\-\/]{4,}(?:PANEL|PROFILE|CBC|BMP|CMP|THYROID|LIPID|METABOLIC|CHEMISTRY|BLOOD|COMPLETE|BASIC|URINALYSIS))\s*$"#,
            options: []
        )

        // Metric line patterns — ordered most-specific first:
        // Pattern A: "Marker Name   94    65-99    mg/dL    Normal"
        // Pattern B: "Marker Name    94    mg/dL    [65-99]"
        // Pattern C: "Marker Name  94 mg/dL  REF: 65-99  H/L flag"
        // Pattern D: Simple "Marker Name: 94 mg/dL"
        let metricPatterns: [(pattern: NSRegularExpression, nameGroup: Int, valueGroup: Int, unitGroup: Int, refGroup: Int, flagGroup: Int)] = [
            // A: name  value  ref_range  unit  flag (Quest style)
            (try! NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+\.?\d*)\s{2,}([\d\.\-<>\s]+?)\s{2,}([\w\/\%µ]+)\s*(H|L|HH|LL|High|Low|Normal|Critical)?\s*$"#), 1, 2, 4, 3, 5),
            // B: name  value  unit  [ref_range]
            (try! NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+\.?\d*)\s+([\w\/\%µmgdLuUI]+)\s+[\[\(]([\d\.\-<>]+)[\]\)]\s*(H|L|HH|LL|High|Low|Normal|Critical)?\s*$"#), 1, 2, 3, 4, 5),
            // C: name  value  unit (no ref range)
            (try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z\s\,\(\)\-\/]{2,40}?)\s{2,}(\d+\.?\d*)\s+([\w\/\%µmgdLuUI]+(?:\/[\w]+)?)\s*$"#), 1, 2, 3, 0, 0),
            // D: "Name: value unit [ref]"
            (try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z\s\(\)\-\/]{2,40}?):\s+(\d+\.?\d*)\s*([\w\/\%µmgdLuUI]*)\s*(?:[\[\(]([\d\.\-<>]+)[\]\)])?\s*(H|L|High|Low)?\s*$"#), 1, 2, 3, 4, 5),
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Check for lab name
            if laboratory == nil {
                for pattern in labPatterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                        laboratory = substring(trimmed, range: match.range(at: 1))?.trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }

            // Check for report date
            if reportDate == nil {
                for pattern in datePatterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                       let dateStr = substring(trimmed, range: match.range(at: 1)) {
                        reportDate = normalizeDate(dateStr)
                        break
                    }
                }
            }

            // Check for panel header
            if let panelMatch = panelPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let panelName = substring(trimmed, range: panelMatch.range(at: 1)) {
                currentPanel = panelName.capitalized
                continue
            }

            // Try metric patterns
            for (regex, nameGroup, valueGroup, unitGroup, refGroup, flagGroup) in metricPatterns {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                guard let match = regex.firstMatch(in: trimmed, range: range) else { continue }

                guard let nameRaw = substring(trimmed, range: match.range(at: nameGroup)),
                      let valueStr = substring(trimmed, range: match.range(at: valueGroup)),
                      let value = Double(valueStr) else { continue }

                let name = cleanMarkerName(nameRaw)
                guard !name.isEmpty, name.count >= 2 else { continue }

                let unit = unitGroup > 0 ? substring(trimmed, range: match.range(at: unitGroup)) : nil
                let ref = refGroup > 0 ? substring(trimmed, range: match.range(at: refGroup))?.trimmingCharacters(in: .whitespaces) : nil
                let flagRaw = flagGroup > 0 ? substring(trimmed, range: match.range(at: flagGroup)) : nil
                let flag = normalizeFlag(flagRaw)

                metrics.append(BloodworkMetric(
                    name: name,
                    value: value,
                    valueText: String(value),
                    unit: unit,
                    referenceRange: ref,
                    panel: currentPanel,
                    collectedAt: reportDate,
                    flag: flag,
                    interpretationNotes: nil
                ))
                break
            }
        }

        // Deduplicate by name (keep first occurrence)
        var seen = Set<String>()
        let deduped = metrics.filter { seen.insert($0.name.lowercased()).inserted }

        let panels: [String: [BloodworkMetric]] = deduped.reduce(into: [:]) { result, m in
            let key = m.panel ?? "general"
            result[key, default: []].append(m)
        }

        let confidence = min(1.0, Double(deduped.count) / 20.0)
        return BloodworkReportData(
            type: "bloodwork",
            source: "ios-pdf-import",
            reportDate: reportDate,
            laboratory: laboratory,
            panels: panels,
            metrics: deduped,
            notes: [],
            rawText: text,
            confidence: confidence
        )
    }

    // MARK: - DEXA parsing

    static func parseDexaText(_ text: String) -> DexaReportData {
        let lines = text.components(separatedBy: .newlines)
        var scanDate: String?
        var source: String?
        var totalBodyFatPercent: Double?
        var totalLeanMassKg: Double?
        var visceralFatRating: Double?
        var visceralFatAreaCm2: Double?
        var visceralFatVolumeCm3: Double?
        var androidGynoidRatio: Double?
        var boneDensityBMD: Double?
        var boneTScore: Double?
        var boneZScore: Double?
        var regionData: [String: [String: Double]] = [:]

        // Detect machine brand
        let lower = text.lowercased()
        if lower.contains("hologic") { source = "Hologic" }
        else if lower.contains("ge lunar") || lower.contains("ge healthcare") { source = "GE Lunar" }
        else if lower.contains("norland") { source = "Norland" }

        // Date
        if let dateMatch = firstRegexMatch(in: text,
            pattern: #"(?:Scan Date|Date|Performed)[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#) {
            scanDate = normalizeDate(dateMatch)
        }

        // Region order: Total Body, Trunk, Arms, Legs, Pelvis, Spine, Head, Left/Right Arm, Left/Right Leg
        let regionAliases: [String: String] = [
            "total body": "total", "whole body": "total", "total": "total",
            "trunk": "trunk", "torso": "trunk",
            "left arm": "left arm", "l arm": "left arm",
            "right arm": "right arm", "r arm": "right arm",
            "left leg": "left leg", "l leg": "left leg",
            "right leg": "right leg", "r leg": "right leg",
            "pelvis": "pelvis",
            "spine": "spine", "lumbar spine": "spine", "l1-l4": "spine",
            "head": "head",
            "android": "android", "gynoid": "gynoid",
            "arms": "arms", "legs": "legs",
        ]

        // Key metrics: "Body Fat % 22.4" or "Body Fat Percent 22.4" or "Fat (%): 22.4"
        let fatPctPatterns = [
            #"(?:total\s+)?body\s+fat\s*(?:percent|%|percentage)?[:\s]+(\d+\.?\d*)\s*%?"#,
            #"fat\s*\(%\)[:\s]+(\d+\.?\d*)"#,
            #"%\s+fat[:\s]+(\d+\.?\d*)"#,
        ]
        for p in fatPctPatterns {
            if let v = firstRegexDouble(in: lower, pattern: p) { totalBodyFatPercent = v; break }
        }

        let leanPatterns = [
            #"(?:total\s+)?lean\s+(?:mass|tissue)[:\s]+(\d+\.?\d*)\s*(?:kg|lbs?)?"#,
            #"lean\s+mass\s*\(kg\)[:\s]+(\d+\.?\d*)"#,
        ]
        for p in leanPatterns {
            if let v = firstRegexDouble(in: lower, pattern: p) {
                totalLeanMassKg = v > 200 ? v / 1000.0 : v  // handle grams
                break
            }
        }

        // Visceral fat
        if let v = firstRegexDouble(in: lower, pattern: #"visceral\s+fat\s+(?:rating|score|mass)[:\s]+(\d+\.?\d*)"#) { visceralFatRating = v }
        if let v = firstRegexDouble(in: lower, pattern: #"visceral\s+fat\s+(?:area|region)[:\s]+(\d+\.?\d*)\s*cm"#) { visceralFatAreaCm2 = v }
        if let v = firstRegexDouble(in: lower, pattern: #"visceral\s+fat\s+(?:volume)[:\s]+(\d+\.?\d*)\s*cm"#) { visceralFatVolumeCm3 = v }

        // Android/Gynoid ratio
        if let v = firstRegexDouble(in: lower, pattern: #"android[\/\s]+gynoid\s+(?:ratio)?[:\s]+(\d+\.?\d*)"#) { androidGynoidRatio = v }
        if let v = firstRegexDouble(in: lower, pattern: #"a\/g\s+ratio[:\s]+(\d+\.?\d*)"#) { androidGynoidRatio = androidGynoidRatio ?? v }

        // Bone density (total)
        if let v = firstRegexDouble(in: lower, pattern: #"(?:total\s+)?bmd[:\s]+(\d+\.?\d*)"#) { boneDensityBMD = v }
        if let v = firstRegexDouble(in: lower, pattern: #"bone\s+(?:mineral\s+)?density[:\s]+(\d+\.?\d*)"#) { boneDensityBMD = boneDensityBMD ?? v }
        if let v = firstRegexDouble(in: lower, pattern: #"t[-\s]score[:\s]+([-+]?\d+\.?\d*)"#) { boneTScore = v }
        if let v = firstRegexDouble(in: lower, pattern: #"z[-\s]score[:\s]+([-+]?\d+\.?\d*)"#) { boneZScore = v }

        // Regional parsing: scan lines for region headers followed by values
        var currentRegion: String?
        let regionHeaderPattern = try? NSRegularExpression(
            pattern: #"^\s*((?:left|right|l|r)\s+(?:arm|leg)|trunk|pelvis|spine|head|android|gynoid|total\s*body?|arms|legs)\s*(?:\(.*\))?\s*$"#,
            options: .caseInsensitive
        )
        let regionValuePattern = try? NSRegularExpression(
            pattern: #"(\d+\.?\d*)\s*(kg|g|%|lbs?|gm)?\s+(\d+\.?\d*)\s*(kg|g|%|lbs?)?\s+(\d+\.?\d*)\s*(kg|g|%|lbs?)?"#,
            options: .caseInsensitive
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.isEmpty { continue }

            // Check for region header
            if let regex = regionHeaderPattern,
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let regionRaw = substring(trimmed, range: match.range(at: 1)) {
                let normalized = regionAliases[regionRaw.trimmingCharacters(in: .whitespaces)] ?? regionRaw
                currentRegion = normalized
                continue
            }

            // Try to parse row with fat/lean/bone values for current region
            guard let region = currentRegion,
                  let regex = regionValuePattern,
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
                continue
            }

            var vals: [Double] = []
            for i in stride(from: 1, through: 5, by: 2) {
                if let s = substring(trimmed, range: match.range(at: i)), let v = Double(s) {
                    vals.append(v)
                }
            }

            if vals.count >= 2 {
                // Try to assign fat %, lean mass, fat mass by column position
                if region == "android" || region == "gynoid" {
                    if androidGynoidRatio == nil, vals.count >= 1 {
                        // Store for ratio computation later
                        regionData[region, default: [:]]["%fat"] = vals[0]
                    }
                } else {
                    if vals[0] < 100 { regionData[region, default: [:]]["%fat"] = vals[0] }
                    if vals.count > 1 { regionData[region, default: [:]]["%lean"] = vals[1] }
                    if vals.count > 2 { regionData[region, default: [:]]["%fatmass"] = vals[2] }
                }
            }
        }

        // Build regions array
        var regions: [DexaRegionMetrics] = regionData.compactMap { regionName, values in
            guard regionName != "android" && regionName != "gynoid" else { return nil }
            let fat = values["%fat"]
            let lean = values["%lean"].map { v -> Double in v > 200 ? v / 1000 : v }
            let fatMass = values["%fatmass"].map { v -> Double in v > 200 ? v / 1000 : v }
            return DexaRegionMetrics(
                region: regionName,
                bodyFatPercent: fat,
                leanMassKg: lean,
                fatMassKg: fatMass,
                boneDensityGPerCm2: nil,
                tScore: nil,
                zScore: nil
            )
        }.sorted { $0.region < $1.region }

        let hasBoneTotal = boneDensityBMD != nil || boneTScore != nil || boneZScore != nil
        let filled = [totalBodyFatPercent, totalLeanMassKg].compactMap { $0 }.count
        let confidence = min(1.0, Double(filled + regions.count) / 8.0)

        return DexaReportData(
            type: "dexa",
            source: source ?? "ios-pdf-import",
            scanDate: scanDate,
            totalBodyFatPercent: totalBodyFatPercent,
            totalLeanMassKg: totalLeanMassKg,
            visceralFatRating: visceralFatRating,
            visceralFatAreaCm2: visceralFatAreaCm2,
            visceralFatVolumeCm3: visceralFatVolumeCm3,
            boneDensityTotal: hasBoneTotal ? DexaBoneDensityTotal(bmd: boneDensityBMD, tScore: boneTScore, zScore: boneZScore) : nil,
            androidGynoidRatio: androidGynoidRatio,
            regions: regions,
            notes: [],
            rawText: text,
            confidence: confidence
        )
    }

    // MARK: - Helpers

    private static func substring(_ string: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: string) else { return nil }
        let s = String(string[swiftRange]).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    private static func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        return substring(text, range: match.range(at: 1))
    }

    private static func firstRegexDouble(in text: String, pattern: String) -> Double? {
        firstRegexMatch(in: text, pattern: pattern).flatMap { Double($0) }
    }

    private static func cleanMarkerName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .init(charactersIn: "*†‡§")).first?
            .trimmingCharacters(in: .whitespaces) ?? raw
    }

    private static func normalizeDate(_ raw: String) -> String {
        // Try to convert MM/DD/YYYY or MM-DD-YYYY to YYYY-MM-DD
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "/-"))
        if parts.count == 3 {
            let (a, b, c) = (parts[0], parts[1], parts[2])
            if c.count == 4 { return "\(c)-\(a.padded)-\(b.padded)" }  // MM/DD/YYYY
            if a.count == 4 { return "\(a)-\(b.padded)-\(c.padded)" }  // YYYY-MM-DD
        }
        return raw
    }

    private static func normalizeFlag(_ raw: String?) -> BloodworkFlag? {
        switch raw?.lowercased() {
        case "h", "high": return "high"
        case "l", "low":  return "low"
        case "hh", "critical high", "critical-high": return "critical-high"
        case "ll", "critical low", "critical-low":   return "critical-low"
        case "n", "normal": return "normal"
        default: return nil
        }
    }
}

private extension String {
    var padded: String { count == 1 ? "0\(self)" : self }
}
