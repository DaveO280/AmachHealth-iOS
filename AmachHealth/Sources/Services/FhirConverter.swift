// FhirConverter.swift
// AmachHealth
//
// Swift port of:
//   /src/utils/fhir/bloodworkToFhir.ts
//   /src/utils/fhir/dexaToFhir.ts
//
// Converts BloodworkReportData / DexaReportData → FhirDiagnosticReport (for Storj upload)
// and back (for retrieval). Must produce identical JSON structure to the web so the
// dashboard can read reports uploaded from iOS.

import Foundation
import CryptoKit

// MARK: - Bloodwork → FHIR

enum FhirConverter {

    // MARK: Bloodwork encode

    static func convertBloodworkToFhir(_ report: BloodworkReportData) -> FhirDiagnosticReport {
        var observations: [FhirObservation] = []
        var observationRefs: [FhirReference] = []
        var counter = 1

        func nextId() -> String { let id = "obs-\(counter)"; counter += 1; return id }

        let effectiveDate = report.reportDate
            ?? report.metrics.compactMap(\.collectedAt).first

        for metric in report.metrics {
            let obsId = nextId()
            let codeDisplay = metric.name.isEmpty ? "Lab result" : metric.name
            let code = slugify(codeDisplay)

            var refRange: [FhirReferenceRange]? = nil
            if let rr = metric.referenceRange, !rr.isEmpty {
                refRange = [FhirReferenceRange(text: rr)]
            }

            let obs = FhirObservation(
                resourceType: "Observation",
                id: obsId,
                status: "final",
                category: [[
                    FhirCoding(
                        system: "http://terminology.hl7.org/CodeSystem/observation-category",
                        code: "laboratory",
                        display: "Laboratory"
                    )
                ]].map { FhirCodeableConcept(coding: $0) },
                code: FhirCodeableConcept(coding: [
                    FhirCoding(
                        system: "http://amach.health/fhir/lab-test",
                        code: code,
                        display: codeDisplay
                    )
                ]),
                subject: nil,
                effectiveDateTime: metric.collectedAt ?? effectiveDate,
                valueQuantity: numericQuantity(value: metric.value, unit: metric.unit),
                valueString: metric.value == nil ? metric.valueText : nil,
                component: nil,
                interpretation: flagToInterpretation(metric.flag),
                referenceRange: refRange
            )

            observations.append(obs)
            observationRefs.append(FhirReference(reference: "#\(obsId)"))
        }

        let reportId = "bloodwork-\(report.reportDate ?? String(Int(Date().timeIntervalSince1970)))"

        return FhirDiagnosticReport(
            resourceType: "DiagnosticReport",
            id: reportId,
            status: "final",
            category: [FhirCodeableConcept(coding: [
                FhirCoding(
                    system: "http://terminology.hl7.org/CodeSystem/v2-0074",
                    code: "LAB",
                    display: "Laboratory"
                )
            ])],
            code: FhirCodeableConcept(coding: [
                FhirCoding(
                    system: "http://loinc.org",
                    code: "11502-2",
                    display: "Laboratory report"
                )
            ]),
            subject: nil,
            effectiveDateTime: effectiveDate,
            issued: iso8601Now(),
            performer: nil,
            result: observationRefs,
            conclusion: report.laboratory.map { "Bloodwork report from \($0)." } ?? "Bloodwork report.",
            contained: observations
        )
    }

    // MARK: FHIR → Bloodwork decode

    static func convertFhirToBloodwork(_ fhir: FhirDiagnosticReport, rawText: String = "", source: String? = nil) -> BloodworkReportData? {
        guard fhir.resourceType == "DiagnosticReport" else { return nil }

        var metrics: [BloodworkMetric] = []

        for obs in fhir.contained ?? [] {
            guard obs.resourceType == "Observation" else { continue }

            let name = obs.code.coding.first?.display ?? obs.code.coding.first?.code ?? "Unknown"
            let value = obs.valueQuantity?.value
            let unit = obs.valueQuantity?.unit
            let valueText = obs.valueString ?? value.map { String($0) }

            let interpCode = obs.interpretation?.first?.coding.first?.code
            let flag: BloodworkFlag?
            switch interpCode {
            case "N": flag = "normal"
            case "L": flag = "low"
            case "H": flag = "high"
            case "LL": flag = "critical-low"
            case "HH": flag = "critical-high"
            default: flag = nil
            }

            metrics.append(BloodworkMetric(
                name: name,
                value: value,
                valueText: valueText,
                unit: unit,
                referenceRange: obs.referenceRange?.first?.text,
                panel: nil,
                collectedAt: obs.effectiveDateTime,
                flag: flag,
                interpretationNotes: nil
            ))
        }

        let panels: [String: [BloodworkMetric]] = metrics.reduce(into: [:]) { result, m in
            let key = m.panel ?? "general"
            result[key, default: []].append(m)
        }

        return BloodworkReportData(
            type: "bloodwork",
            source: source,
            reportDate: fhir.effectiveDateTime,
            laboratory: nil,
            panels: panels,
            metrics: metrics,
            notes: [],
            rawText: rawText,
            confidence: 0.8
        )
    }

    // MARK: DEXA → FHIR

    static func convertDexaToFhir(_ report: DexaReportData) -> FhirDiagnosticReport {
        var observations: [FhirObservation] = []
        var observationRefs: [FhirReference] = []
        var counter = 1

        func nextId() -> String { let id = "obs-\(counter)"; counter += 1; return id }

        // 1. Total body fat %
        if let fat = report.totalBodyFatPercent {
            let obsId = nextId()
            observations.append(FhirObservation(
                resourceType: "Observation",
                id: obsId,
                status: "final",
                category: [FhirCodeableConcept(coding: [
                    FhirCoding(system: "http://terminology.hl7.org/CodeSystem/observation-category", code: "vital-signs", display: "Vital Signs")
                ])],
                code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "41982-7", display: "Body fat percentage")]),
                subject: nil,
                effectiveDateTime: report.scanDate,
                valueQuantity: FhirQuantity(value: fat, unit: "%", system: "http://unitsofmeasure.org", code: "%"),
                valueString: nil, component: nil, interpretation: nil, referenceRange: nil
            ))
            observationRefs.append(FhirReference(reference: "#\(obsId)"))
        }

        // 2. Total lean mass
        if let lean = report.totalLeanMassKg {
            let obsId = nextId()
            observations.append(FhirObservation(
                resourceType: "Observation", id: obsId, status: "final", category: nil,
                code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "73708-0", display: "Lean body mass")]),
                subject: nil, effectiveDateTime: report.scanDate,
                valueQuantity: FhirQuantity(value: lean, unit: "kg", system: "http://unitsofmeasure.org", code: "kg"),
                valueString: nil, component: nil, interpretation: nil, referenceRange: nil
            ))
            observationRefs.append(FhirReference(reference: "#\(obsId)"))
        }

        // 3. Total bone density
        if let bdt = report.boneDensityTotal, bdt.bmd != nil || bdt.tScore != nil || bdt.zScore != nil {
            let obsId = nextId()
            var components: [FhirObservationComponent] = []
            if let bmd = bdt.bmd {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24701-4", display: "Bone density")]),
                    valueQuantity: FhirQuantity(value: bmd, unit: "g/cm²", system: "http://unitsofmeasure.org", code: "g/cm2")
                ))
            }
            if let ts = bdt.tScore {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24702-2", display: "T-score")]),
                    valueQuantity: FhirQuantity(value: ts, unit: "SD", system: nil, code: nil)
                ))
            }
            if let zs = bdt.zScore {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24703-0", display: "Z-score")]),
                    valueQuantity: FhirQuantity(value: zs, unit: "SD", system: nil, code: nil)
                ))
            }
            observations.append(FhirObservation(
                resourceType: "Observation", id: obsId, status: "final",
                category: [FhirCodeableConcept(coding: [FhirCoding(system: "http://terminology.hl7.org/CodeSystem/observation-category", code: "imaging", display: "Imaging")])],
                code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24701-4", display: "Bone mineral density DEXA")]),
                subject: nil, effectiveDateTime: report.scanDate,
                valueQuantity: nil, valueString: nil, component: components, interpretation: nil, referenceRange: nil
            ))
            observationRefs.append(FhirReference(reference: "#\(obsId)"))
        }

        // 4. Regional BMD
        for region in report.regions {
            if region.boneDensityGPerCm2 != nil || region.tScore != nil || region.zScore != nil {
                let obsId = nextId()
                var components: [FhirObservationComponent] = []
                if let bmd = region.boneDensityGPerCm2 {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24701-4", display: "Bone density")]),
                        valueQuantity: FhirQuantity(value: bmd, unit: "g/cm²", system: "http://unitsofmeasure.org", code: "g/cm2")
                    ))
                }
                if let ts = region.tScore {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24702-2", display: "T-score")]),
                        valueQuantity: FhirQuantity(value: ts, unit: "SD", system: nil, code: nil)
                    ))
                }
                if let zs = region.zScore {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24703-0", display: "Z-score")]),
                        valueQuantity: FhirQuantity(value: zs, unit: "SD", system: nil, code: nil)
                    ))
                }
                observations.append(FhirObservation(
                    resourceType: "Observation", id: obsId, status: "final", category: nil,
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "24701-4", display: "Bone mineral density DEXA - \(region.region)")]),
                    subject: nil, effectiveDateTime: report.scanDate,
                    valueQuantity: nil, valueString: region.region, component: components, interpretation: nil, referenceRange: nil
                ))
                observationRefs.append(FhirReference(reference: "#\(obsId)"))
            }

            // 5. Regional body composition
            if region.bodyFatPercent != nil || region.leanMassKg != nil || region.fatMassKg != nil {
                let obsId = nextId()
                var components: [FhirObservationComponent] = []
                if let fat = region.bodyFatPercent {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "41982-7", display: "Body fat percentage")]),
                        valueQuantity: FhirQuantity(value: fat, unit: "%", system: "http://unitsofmeasure.org", code: "%")
                    ))
                }
                if let lean = region.leanMassKg {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "73708-0", display: "Lean body mass")]),
                        valueQuantity: FhirQuantity(value: lean, unit: "kg", system: "http://unitsofmeasure.org", code: "kg")
                    ))
                }
                if let fatMass = region.fatMassKg {
                    components.append(FhirObservationComponent(
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "41981-9", display: "Body fat mass")]),
                        valueQuantity: FhirQuantity(value: fatMass, unit: "kg", system: "http://unitsofmeasure.org", code: "kg")
                    ))
                }
                if !components.isEmpty {
                    observations.append(FhirObservation(
                        resourceType: "Observation", id: obsId, status: "final", category: nil,
                        code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "41982-7", display: "Body composition - \(region.region)")]),
                        subject: nil, effectiveDateTime: report.scanDate,
                        valueQuantity: nil, valueString: region.region, component: components, interpretation: nil, referenceRange: nil
                    ))
                    observationRefs.append(FhirReference(reference: "#\(obsId)"))
                }
            }
        }

        // 6. Visceral fat
        if report.visceralFatVolumeCm3 != nil || report.visceralFatAreaCm2 != nil || report.visceralFatRating != nil {
            let obsId = nextId()
            var components: [FhirObservationComponent] = []
            if let vol = report.visceralFatVolumeCm3 {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "82810-3", display: "Visceral fat volume")]),
                    valueQuantity: FhirQuantity(value: vol, unit: "cm³", system: "http://unitsofmeasure.org", code: "cm3")
                ))
            }
            if let area = report.visceralFatAreaCm2 {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "82811-1", display: "Visceral fat area")]),
                    valueQuantity: FhirQuantity(value: area, unit: "cm²", system: "http://unitsofmeasure.org", code: "cm2")
                ))
            }
            if let rating = report.visceralFatRating {
                components.append(FhirObservationComponent(
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "82812-9", display: "Visceral fat rating")]),
                    valueQuantity: FhirQuantity(value: rating, unit: "lbs", system: "http://unitsofmeasure.org", code: "[lb_av]")
                ))
            }
            if !components.isEmpty {
                observations.append(FhirObservation(
                    resourceType: "Observation", id: obsId, status: "final", category: nil,
                    code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "82810-3", display: "Visceral adipose tissue")]),
                    subject: nil, effectiveDateTime: report.scanDate,
                    valueQuantity: nil, valueString: nil, component: components, interpretation: nil, referenceRange: nil
                ))
                observationRefs.append(FhirReference(reference: "#\(obsId)"))
            }
        }

        // 7. Android/Gynoid ratio
        if let agr = report.androidGynoidRatio {
            let obsId = nextId()
            observations.append(FhirObservation(
                resourceType: "Observation", id: obsId, status: "final", category: nil,
                code: FhirCodeableConcept(coding: [FhirCoding(system: "http://loinc.org", code: "82813-7", display: "Android/Gynoid ratio")]),
                subject: nil, effectiveDateTime: report.scanDate,
                valueQuantity: FhirQuantity(value: agr, unit: "ratio", system: nil, code: nil),
                valueString: nil, component: nil, interpretation: nil, referenceRange: nil
            ))
            observationRefs.append(FhirReference(reference: "#\(obsId)"))
        }

        let pct = Int((report.confidence * 100).rounded())
        let sourceClause = report.source.map { " from \($0)" } ?? ""
        return FhirDiagnosticReport(
            resourceType: "DiagnosticReport",
            id: nil,
            status: "final",
            category: [FhirCodeableConcept(coding: [
                FhirCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0074", code: "RAD", display: "Radiology")
            ])],
            code: FhirCodeableConcept(coding: [
                FhirCoding(system: "http://loinc.org", code: "38269-7", display: "DXA Bone density")
            ]),
            subject: nil,
            effectiveDateTime: report.scanDate,
            issued: iso8601Now(),
            performer: nil,
            result: observationRefs,
            conclusion: "DEXA scan report\(sourceClause). Confidence: \(pct)%",
            contained: observations
        )
    }

    // MARK: FHIR → DEXA decode

    static func convertFhirToDexa(_ fhir: FhirDiagnosticReport, rawText: String = "", source: String? = nil) -> DexaReportData? {
        guard fhir.resourceType == "DiagnosticReport" else { return nil }

        var totalBodyFatPercent: Double?
        var totalLeanMassKg: Double?
        var visceralFatVolumeCm3: Double?
        var visceralFatAreaCm2: Double?
        var visceralFatRating: Double?
        var androidGynoidRatio: Double?
        var bmd: Double?; var tScore: Double?; var zScore: Double?
        var regionMap: [String: DexaRegionMetrics] = [:]

        for obs in fhir.contained ?? [] {
            guard obs.resourceType == "Observation" else { continue }
            let code = obs.code.coding.first?.code
            let value = obs.valueQuantity?.value
            let components = obs.component ?? []

            if code == "41982-7" && components.isEmpty, let v = value { totalBodyFatPercent = v }
            if code == "73708-0" && components.isEmpty, let v = value { totalLeanMassKg = v }

            if code == "24701-4" && !components.isEmpty && obs.valueString == nil {
                for c in components {
                    let cc = c.code.coding.first?.code
                    let cv = c.valueQuantity?.value
                    if cc == "24701-4" { bmd = cv }
                    else if cc == "24702-2" { tScore = cv }
                    else if cc == "24703-0" { zScore = cv }
                }
            }

            if let regionName = obs.valueString {
                var r = regionMap[regionName] ?? DexaRegionMetrics(region: regionName, bodyFatPercent: nil, leanMassKg: nil, fatMassKg: nil, boneDensityGPerCm2: nil, tScore: nil, zScore: nil)
                if code == "24701-4" && !components.isEmpty {
                    var b2 = r.boneDensityGPerCm2; var t2 = r.tScore; var z2 = r.zScore
                    for c in components {
                        let cc = c.code.coding.first?.code; let cv = c.valueQuantity?.value
                        if cc == "24701-4" { b2 = cv }
                        else if cc == "24702-2" { t2 = cv }
                        else if cc == "24703-0" { z2 = cv }
                    }
                    r = DexaRegionMetrics(region: regionName, bodyFatPercent: r.bodyFatPercent, leanMassKg: r.leanMassKg, fatMassKg: r.fatMassKg, boneDensityGPerCm2: b2, tScore: t2, zScore: z2)
                }
                if code == "41982-7" && !components.isEmpty {
                    var fat2 = r.bodyFatPercent; var lean2 = r.leanMassKg; var fatm2 = r.fatMassKg
                    for c in components {
                        let cc = c.code.coding.first?.code; let cv = c.valueQuantity?.value
                        if cc == "41982-7" { fat2 = cv }
                        else if cc == "73708-0" { lean2 = cv }
                        else if cc == "41981-9" { fatm2 = cv }
                    }
                    r = DexaRegionMetrics(region: regionName, bodyFatPercent: fat2, leanMassKg: lean2, fatMassKg: fatm2, boneDensityGPerCm2: r.boneDensityGPerCm2, tScore: r.tScore, zScore: r.zScore)
                }
                regionMap[regionName] = r
            }

            if code == "82810-3" && !components.isEmpty {
                for c in components {
                    let cc = c.code.coding.first?.code; let cv = c.valueQuantity?.value
                    if cc == "82810-3" { visceralFatVolumeCm3 = cv }
                    else if cc == "82811-1" { visceralFatAreaCm2 = cv }
                    else if cc == "82812-9" { visceralFatRating = cv }
                }
            }

            if code == "82813-7", let v = value { androidGynoidRatio = v }
        }

        let regions = regionMap.values.sorted { $0.region < $1.region }
        let hasBoneTotal = bmd != nil || tScore != nil || zScore != nil
        return DexaReportData(
            type: "dexa",
            source: source,
            scanDate: fhir.effectiveDateTime,
            totalBodyFatPercent: totalBodyFatPercent,
            totalLeanMassKg: totalLeanMassKg,
            visceralFatRating: visceralFatRating,
            visceralFatAreaCm2: visceralFatAreaCm2,
            visceralFatVolumeCm3: visceralFatVolumeCm3,
            boneDensityTotal: hasBoneTotal ? DexaBoneDensityTotal(bmd: bmd, tScore: tScore, zScore: zScore) : nil,
            androidGynoidRatio: androidGynoidRatio,
            regions: regions,
            notes: fhir.conclusion.map { [$0] } ?? [],
            rawText: rawText,
            confidence: regions.isEmpty ? 0.1 : min(1.0, Double(regions.count) / 6.0)
        )
    }

    // MARK: - Fingerprinting (for dedup — mirrors StorjReportService.ts)

    static func fingerprintBloodwork(_ report: BloodworkReportData) -> String {
        struct NormalizedMetric: Encodable {
            var name: String; var value: Double?; var valueText: String?
            var unit: String?; var referenceRange: String?; var flag: String?; var panel: String?
        }
        let normalizedMetrics = report.metrics.map {
            NormalizedMetric(name: $0.name, value: $0.value, valueText: $0.valueText,
                             unit: $0.unit, referenceRange: $0.referenceRange, flag: $0.flag, panel: $0.panel)
        }.sorted { a, b in
            let ak = "\(a.panel ?? "")|\(a.name)|\(a.unit ?? "")|\(a.value.map { "\($0)" } ?? "")|\(a.referenceRange ?? "")|\(a.flag ?? "")"
            let bk = "\(b.panel ?? "")|\(b.name)|\(b.unit ?? "")|\(b.value.map { "\($0)" } ?? "")|\(b.referenceRange ?? "")|\(b.flag ?? "")"
            return ak < bk
        }
        struct NormalizedReport: Encodable {
            var type: String; var reportDate: String; var laboratory: String; var source: String; var metrics: [NormalizedMetric]
        }
        let normalized = NormalizedReport(
            type: "bloodwork",
            reportDate: report.reportDate ?? "",
            laboratory: report.laboratory ?? "",
            source: report.source ?? "",
            metrics: normalizedMetrics
        )
        return sha256JSON(normalized)
    }

    static func fingerprintDexa(_ report: DexaReportData) -> String {
        struct NormalizedRegion: Encodable {
            var region: String; var bodyFatPercent: Double?; var leanMassKg: Double?
            var fatMassKg: Double?; var boneDensityGPerCm2: Double?; var tScore: Double?; var zScore: Double?
        }
        struct NormalizedBoneTotal: Encodable {
            var bmd: Double?; var tScore: Double?; var zScore: Double?
        }
        struct NormalizedReport: Encodable {
            var type: String; var scanDate: String; var source: String
            var totalBodyFatPercent: Double?; var totalLeanMassKg: Double?
            var visceralFatRating: Double?; var visceralFatAreaCm2: Double?; var visceralFatVolumeCm3: Double?
            var boneDensityTotal: NormalizedBoneTotal?; var androidGynoidRatio: Double?
            var regions: [NormalizedRegion]
        }
        let regions = report.regions
            .map { NormalizedRegion(region: $0.region, bodyFatPercent: $0.bodyFatPercent, leanMassKg: $0.leanMassKg,
                                   fatMassKg: $0.fatMassKg, boneDensityGPerCm2: $0.boneDensityGPerCm2, tScore: $0.tScore, zScore: $0.zScore) }
            .sorted { $0.region < $1.region }
        let bdt = report.boneDensityTotal.map { NormalizedBoneTotal(bmd: $0.bmd, tScore: $0.tScore, zScore: $0.zScore) }
        let normalized = NormalizedReport(
            type: "dexa", scanDate: report.scanDate ?? "", source: report.source ?? "",
            totalBodyFatPercent: report.totalBodyFatPercent, totalLeanMassKg: report.totalLeanMassKg,
            visceralFatRating: report.visceralFatRating, visceralFatAreaCm2: report.visceralFatAreaCm2,
            visceralFatVolumeCm3: report.visceralFatVolumeCm3, boneDensityTotal: bdt,
            androidGynoidRatio: report.androidGynoidRatio, regions: regions
        )
        return sha256JSON(normalized)
    }

    // MARK: - Helpers

    private static func slugify(_ input: String) -> String {
        let slug = input
            .lowercased()
            .components(separatedBy: .init(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").inverted)
            .joined(separator: "-")
            .components(separatedBy: "--").joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(slug.prefix(64))
        return truncated.isEmpty ? "unknown" : truncated
    }

    private static func numericQuantity(value: Double?, unit: String?) -> FhirQuantity? {
        guard let v = value, v.isFinite else { return nil }
        return FhirQuantity(
            value: v,
            unit: unit ?? "",
            system: unit != nil ? "http://unitsofmeasure.org" : nil,
            code: unit
        )
    }

    private static func flagToInterpretation(_ flag: BloodworkFlag?) -> [FhirInterpretationEntry]? {
        guard let flag else { return nil }
        let system = "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation"
        let (code, display): (String, String)
        switch flag {
        case "normal":       (code, display) = ("N",  "Normal")
        case "low":          (code, display) = ("L",  "Low")
        case "high":         (code, display) = ("H",  "High")
        case "critical-low": (code, display) = ("LL", "Critically low")
        case "critical-high":(code, display) = ("HH", "Critically high")
        default: return nil
        }
        return [FhirInterpretationEntry(coding: [FhirCoding(system: system, code: code, display: display)])]
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func sha256JSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
