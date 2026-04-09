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
                            "android", "gynoid", "hologic", "ge lunar", "norland",
                            "body composition - segmental analysis", "body composition/bmd report",
                            "lunar prodigy", "fittrace", "tissue (%fat)", "total body tissue quantitation"]
        let dexaHits = dexaKeywords.filter { lower.contains($0) }.count
        return dexaHits >= 2
    }

    private static func isLunarProdigyFormat(_ text: String) -> Bool {
        let lower = text.lowercased()
        let lunarKeywords = ["lunar prodigy", "fittrace", "body composition - segmental analysis",
                             "body composition/bmd report", "total body tissue quantitation",
                             "tissue (%fat)"]
        return lunarKeywords.contains { lower.contains($0) }
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
        if isLunarProdigyFormat(text) {
            return parseLunarProdigyDexaText(text)
        }
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

        // Date — use scan-specific labels to avoid matching "Date of Birth"
        let genericScanDateLabels = [
            #"(?:Scan\s+Date|Exam\s+Date|Study\s+Date|Date\s+of\s+(?:Exam|Scan|Study))[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#,
            #"Performed[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#,
        ]
        for p in genericScanDateLabels {
            if let d = firstRegexMatch(in: text, pattern: p) { scanDate = normalizeDate(d); break }
        }
        if scanDate == nil,
           let regex = try? NSRegularExpression(pattern: #"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4})"#,
                                                options: .caseInsensitive) {
            let ms = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in ms {
                if let ds = substring(text, range: m.range(at: 1)) {
                    let norm = normalizeDate(ds)
                    if (Int(norm.prefix(4)) ?? 0) >= 2000 { scanDate = norm; break }
                }
            }
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

    // MARK: - GE Healthcare Lunar Prodigy / FitTrace DEXA parser

    /// Parse a GE Healthcare Lunar Prodigy or FitTrace DEXA PDF.
    ///
    /// Handles two common column orders:
    ///   A) Total(lbs) | Fat(lbs) | Lean(lbs) | Area | BMC   (older Prodigy)
    ///   B) %Fat | Fat(lbs) | Lean(lbs) | Total(lbs) | Area | BMC  (FitTrace / newer)
    ///
    /// Column order is detected automatically: if v1 < 100 AND treating v1 as total
    /// would yield fat% > 100, we reinterpret v1 as %Fat.
    ///
    /// Row context: "Arms" / "Legs" heading lines make Left/Right rows context-dependent.
    /// Full region labels ("Left Arm", "R. Leg") are also recognised directly.
    /// Unit conversion: all masses lbs → kg (× 0.453592).
    private static func parseLunarProdigyDexaText(_ text: String) -> DexaReportData {
        let lines = text.components(separatedBy: .newlines)
        let lower = text.lowercased()
        let lbsToKg: (Double) -> Double = { $0 * 0.453592 }

        var scanDate: String?
        var totalMassLbs: Double?
        var totalFatLbs:  Double?
        var totalFatPct:  Double?   // directly provided %Fat for total row
        var totalLeanLbs: Double?
        var visceralFatAreaCm2: Double?
        var boneDensityBMD: Double?
        var boneTScore: Double?
        var boneZScore: Double?
        var currentGroup: String?  // "arms" | "legs"
        // totalLbs is optional because in column-order-B we don't capture the 4th column
        var regionRows: [(name: String, totalLbs: Double?, fatLbs: Double, leanLbs: Double, fatPct: Double?)] = []

        // ── Scan date ──────────────────────────────────────────────────────────
        // Prefer explicit scan-specific labels so we never pick up Date of Birth.
        let scanDateLabels = [
            #"(?:Scan\s+Date|Exam\s+Date|Study\s+Date|Date\s+of\s+(?:Exam|Scan|Study))[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#,
            #"Performed[:\s]+(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#,
        ]
        for p in scanDateLabels {
            if let d = firstRegexMatch(in: text, pattern: p) { scanDate = normalizeDate(d); break }
        }
        // Fallback: walk all MM/DD/YYYY dates, take the first with year ≥ 2000
        // (birth dates like 01/01/1981 are excluded).
        if scanDate == nil,
           let regex = try? NSRegularExpression(pattern: #"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4})"#,
                                                options: .caseInsensitive) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches {
                if let ds = substring(text, range: m.range(at: 1)) {
                    let norm = normalizeDate(ds)
                    if (Int(norm.prefix(4)) ?? 0) >= 2000 { scanDate = norm; break }
                }
            }
        }

        // ── Visceral fat area ──────────────────────────────────────────────────
        let vfPatterns = [
            #"visceral\s+fat\s+area[:\s]+(\d+\.?\d*)\s*cm"#,
            #"visceral\s+(?:adipose\s+)?tissue[:\s]+(\d+\.?\d*)\s*cm"#,
            #"\bvat[:\s]+(\d+\.?\d*)\s*cm"#,
        ]
        for p in vfPatterns {
            if let v = firstRegexDouble(in: lower, pattern: p) { visceralFatAreaCm2 = v; break }
        }

        // ── BMD row ────────────────────────────────────────────────────────────
        // Matches "Total Body  1.22  0.4  0.6" or "Total  1.22  0.4  0.6"
        // We scan ALL matches and take the first whose BMD value is in the realistic
        // g/cm² range (0.5–3.5) — this prevents false matches against the segmental
        // table's "Total  185.4  31.6  148.7" weight row.
        let bmdRowRegex = try? NSRegularExpression(
            pattern: #"(?:total\s+body|whole\s+body|total)\s+(\d+\.\d+)\s+([-+]?\d+\.?\d*)\s+([-+]?\d+\.?\d*)"#,
            options: .caseInsensitive
        )
        if let regex = bmdRowRegex {
            let allBmdMatches = regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower))
            for match in allBmdMatches {
                guard let bmdStr = substring(lower, range: match.range(at: 1)),
                      let bmdVal = Double(bmdStr),
                      bmdVal >= 0.5 && bmdVal <= 3.5 else { continue }
                boneDensityBMD = bmdVal
                boneTScore     = substring(lower, range: match.range(at: 2)).flatMap(Double.init)
                boneZScore     = substring(lower, range: match.range(at: 3)).flatMap(Double.init)
                break
            }
        }
        // Individual fallbacks for BMD, T-score, Z-score
        if boneDensityBMD == nil {
            let bmdFallbacks = [
                #"bmd[:\s]+(\d+\.\d{2,})"#,
                #"bone\s+mineral\s+density[:\s]+(\d+\.\d+)"#,
                #"(\d+\.\d{3,})\s*g\/cm"#,
            ]
            for p in bmdFallbacks {
                if let v = firstRegexDouble(in: lower, pattern: p) { boneDensityBMD = v; break }
            }
        }
        if boneTScore == nil, let v = firstRegexDouble(in: lower, pattern: #"t[-\s]score[:\s]+([-+]?\d+\.?\d*)"#) { boneTScore = v }
        if boneZScore == nil, let v = firstRegexDouble(in: lower, pattern: #"z[-\s]score[:\s]+([-+]?\d+\.?\d*)"#) { boneZScore = v }

        // ── Segmental table rows ───────────────────────────────────────────────
        // Pattern A: bare token  "Left  9.6  1.5  7.9  ..."
        let simpleRowRegex = try? NSRegularExpression(
            pattern: #"^\s*(left|right|trunk|pelvis|spine|head|arms|legs|total)\s+(\d+\.?\d*)\s+(\d+\.?\d*)\s+(\d+\.?\d*)"#,
            options: .caseInsensitive
        )
        // Pattern B: full region name  "Left Arm  9.6  1.5  7.9  ..."
        let extRowRegex = try? NSRegularExpression(
            pattern: #"^\s*((?:left|right|l|r)\.?\s+(?:arm|leg)|trunk|pelvis|spine|head|total\s+body)\s+(\d+\.?\d*)\s+(\d+\.?\d*)\s+(\d+\.?\d*)"#,
            options: .caseInsensitive
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lowerLine = trimmed.lowercased()

            // Group header lines — no digits, matches known arm/leg label variants
            if lowerLine.first(where: { $0.isNumber }) == nil {
                if lowerLine == "arms" || lowerLine == "arm" { currentGroup = "arms"; continue }
                if lowerLine == "legs" || lowerLine == "leg" { currentGroup = "legs"; continue }
                if lowerLine.hasPrefix("upper") && lowerLine.contains("extrem") { currentGroup = "arms"; continue }
                if lowerLine.hasPrefix("lower") && lowerLine.contains("extrem") { currentGroup = "legs"; continue }
            }

            // Try extended pattern first, then simple
            var match: NSTextCheckingResult?
            if let re = extRowRegex, let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                match = m
            } else if let re = simpleRowRegex, let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                match = m
            }

            guard let m = match,
                  let tokenRaw = substring(trimmed, range: m.range(at: 1))?.lowercased(),
                  let s1 = substring(trimmed, range: m.range(at: 2)),
                  let s2 = substring(trimmed, range: m.range(at: 3)),
                  let s3 = substring(trimmed, range: m.range(at: 4)),
                  let v1 = Double(s1), let v2 = Double(s2), let v3 = Double(s3) else { continue }

            let token = lunarNormalizeToken(tokenRaw)

            // Column-order detection:
            // If treating v1 as total mass would yield fat% > 100 (impossible),
            // the PDF must be using column-order-B: %Fat | Fat | Lean | Total.
            let useAsFatPct = v1 < 100.0 && v2 > 0 && (v2 / v1 * 100.0) > 100.0

            let rowFatPct:   Double? = useAsFatPct ? v1 : nil
            let rowFatLbs:   Double  = v2          // fat mass is always 2nd column
            let rowLeanLbs:  Double  = v3
            let rowTotalLbs: Double? = useAsFatPct ? nil : v1

            switch token {
            case "total", "total body":
                // Guard against the BMD section's "Total Body  1.22  0.4  0.6" row being
                // misinterpreted as the segmental weight row.  Segmental total masses are
                // always > 10 lbs; BMD values are always < 3.5 g/cm².
                guard useAsFatPct || v1 > 10.0 else { break }
                if useAsFatPct {
                    totalFatPct  = v1
                    totalFatLbs  = v2
                    totalLeanLbs = v3
                } else {
                    totalMassLbs = v1
                    totalFatLbs  = v2
                    totalLeanLbs = v3
                }
            case "left":
                let name = currentGroup == "legs" ? "left leg" : "left arm"
                regionRows.append((name: name, totalLbs: rowTotalLbs, fatLbs: rowFatLbs, leanLbs: rowLeanLbs, fatPct: rowFatPct))
            case "right":
                let name = currentGroup == "legs" ? "right leg" : "right arm"
                regionRows.append((name: name, totalLbs: rowTotalLbs, fatLbs: rowFatLbs, leanLbs: rowLeanLbs, fatPct: rowFatPct))
            case "left arm", "right arm", "left leg", "right leg":
                regionRows.append((name: token, totalLbs: rowTotalLbs, fatLbs: rowFatLbs, leanLbs: rowLeanLbs, fatPct: rowFatPct))
            case "arms", "legs":
                break  // sub-total rows — skip
            default:
                regionRows.append((name: token, totalLbs: rowTotalLbs, fatLbs: rowFatLbs, leanLbs: rowLeanLbs, fatPct: rowFatPct))
            }
        }

        // ── Derived totals ─────────────────────────────────────────────────────
        let totalBodyFatPercent: Double? = {
            if let pct = totalFatPct { return pct }
            guard let fat = totalFatLbs, let total = totalMassLbs, total > 0 else { return nil }
            let computed = fat / total * 100.0
            return computed <= 100.0 ? computed : nil
        }()
        let totalLeanMassKg = totalLeanLbs.map(lbsToKg)

        let regions = regionRows.map { row -> DexaRegionMetrics in
            let fatPct: Double?
            if let direct = row.fatPct {
                fatPct = direct
            } else if let total = row.totalLbs, total > 0 {
                let c = row.fatLbs / total * 100.0
                fatPct = c <= 100.0 ? c : nil
            } else {
                fatPct = nil
            }
            return DexaRegionMetrics(
                region: row.name,
                bodyFatPercent: fatPct,
                leanMassKg: lbsToKg(row.leanLbs),
                fatMassKg: lbsToKg(row.fatLbs),
                boneDensityGPerCm2: nil,
                tScore: nil,
                zScore: nil
            )
        }

        let hasBoneTotal = boneDensityBMD != nil || boneTScore != nil || boneZScore != nil
        let filled = [totalBodyFatPercent, totalLeanMassKg, visceralFatAreaCm2].compactMap { $0 }.count
        let confidence = min(1.0, Double(filled + regions.count) / 8.0)

        return DexaReportData(
            type: "dexa",
            source: "GE Lunar",
            scanDate: scanDate,
            totalBodyFatPercent: totalBodyFatPercent,
            totalLeanMassKg: totalLeanMassKg,
            visceralFatRating: nil,
            visceralFatAreaCm2: visceralFatAreaCm2,
            visceralFatVolumeCm3: nil,
            boneDensityTotal: hasBoneTotal ? DexaBoneDensityTotal(bmd: boneDensityBMD, tScore: boneTScore, zScore: boneZScore) : nil,
            androidGynoidRatio: nil,
            regions: regions,
            notes: [],
            rawText: text,
            confidence: confidence
        )
    }

    /// Normalise a raw region token from a GE Lunar row to a canonical name.
    private static func lunarNormalizeToken(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        switch t {
        case "l arm", "l. arm", "l.arm": return "left arm"
        case "r arm", "r. arm", "r.arm": return "right arm"
        case "l leg", "l. leg", "l.leg": return "left leg"
        case "r leg", "r. leg", "r.leg": return "right leg"
        default:
            if t.hasPrefix("total") { return t.hasPrefix("total body") ? "total body" : "total" }
            return t
        }
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
