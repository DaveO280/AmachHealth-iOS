// MockPDFReports.swift
// AmachHealthTests
//
// Mock report data for PDF upload tests.
// Uses the same values that were seeded to Storj for the test wallet:
//   0x5C52974c3217fE4B62D5035E336089DEE1718fd6
//
// Provides:
//  - mockBloodworkReport()        → BloodworkReportData (full marker set)
//  - mockDexaReport()             → DexaReportData (full scan)
//  - mockBloodworkPDFText()       → String simulating PDFKit extraction
//  - mockDexaPDFText()            → String simulating PDFKit extraction
//  - mockBloodworkPDF()           → Data (programmatically generated PDF via PDFKit)
//  - mockDexaPDF()                → Data

import Foundation
import PDFKit
@testable import AmachHealth

// MARK: - Report data

enum MockPDFReports {

    static func mockBloodworkReport() -> BloodworkReportData {
        let metrics: [BloodworkMetric] = [
            .init(name: "Glucose", value: 94, valueText: "94", unit: "mg/dL", referenceRange: "65-99", panel: "Comprehensive Metabolic Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "HbA1c", value: 5.2, valueText: "5.2", unit: "%", referenceRange: "< 5.7", panel: "Diabetes Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Total Cholesterol", value: 182, valueText: "182", unit: "mg/dL", referenceRange: "< 200", panel: "Lipid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "LDL Cholesterol", value: 98, valueText: "98", unit: "mg/dL", referenceRange: "< 100", panel: "Lipid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "HDL Cholesterol", value: 62, valueText: "62", unit: "mg/dL", referenceRange: "> 40", panel: "Lipid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Triglycerides", value: 88, valueText: "88", unit: "mg/dL", referenceRange: "< 150", panel: "Lipid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "TSH", value: 1.82, valueText: "1.82", unit: "mIU/L", referenceRange: "0.45-4.5", panel: "Thyroid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Vitamin D, 25-OH", value: 42, valueText: "42", unit: "ng/mL", referenceRange: "30-100", panel: "Vitamins", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Ferritin", value: 85, valueText: "85", unit: "ng/mL", referenceRange: "15-150", panel: "Iron Studies", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Sodium", value: 141, valueText: "141", unit: "mmol/L", referenceRange: "136-145", panel: "Comprehensive Metabolic Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Potassium", value: 4.1, valueText: "4.1", unit: "mmol/L", referenceRange: "3.5-5.1", panel: "Comprehensive Metabolic Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Creatinine", value: 0.92, valueText: "0.92", unit: "mg/dL", referenceRange: "0.7-1.3", panel: "Comprehensive Metabolic Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "eGFR", value: 98, valueText: "98", unit: "mL/min/1.73m2", referenceRange: "> 60", panel: "Comprehensive Metabolic Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "AST", value: 22, valueText: "22", unit: "U/L", referenceRange: "10-40", panel: "Liver Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "ALT", value: 18, valueText: "18", unit: "U/L", referenceRange: "7-56", panel: "Liver Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "hs-CRP", value: 0.4, valueText: "0.4", unit: "mg/L", referenceRange: "< 1.0", panel: "Inflammation", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Testosterone, Total", value: 620, valueText: "620", unit: "ng/dL", referenceRange: "264-916", panel: "Hormone Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Cortisol (AM)", value: 14.2, valueText: "14.2", unit: "mcg/dL", referenceRange: "6.2-19.4", panel: "Hormone Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Insulin, Fasting", value: 4.8, valueText: "4.8", unit: "uIU/mL", referenceRange: "2.6-24.9", panel: "Diabetes Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
            .init(name: "Apolipoprotein B", value: 72, valueText: "72", unit: "mg/dL", referenceRange: "< 90", panel: "Lipid Panel", collectedAt: "2025-11-14", flag: "normal", interpretationNotes: nil),
        ]

        let panels: [String: [BloodworkMetric]] = metrics.reduce(into: [:]) { result, m in
            let key = m.panel ?? "general"
            result[key, default: []].append(m)
        }

        return BloodworkReportData(
            type: "bloodwork",
            source: "Quest Diagnostics",
            reportDate: "2025-11-14",
            laboratory: "Quest Diagnostics",
            panels: panels,
            metrics: metrics,
            notes: ["Fasting 12h", "AM draw"],
            rawText: mockBloodworkPDFText(),
            confidence: 0.95
        )
    }

    static func mockDexaReport() -> DexaReportData {
        DexaReportData(
            type: "dexa",
            source: "Hologic",
            scanDate: "2025-09-22",
            totalBodyFatPercent: 18.4,
            totalLeanMassKg: 67.2,
            visceralFatRating: 1.2,
            visceralFatAreaCm2: 42.8,
            visceralFatVolumeCm3: 312.4,
            boneDensityTotal: DexaBoneDensityTotal(bmd: 1.28, tScore: 0.6, zScore: 0.8),
            androidGynoidRatio: 0.84,
            regions: [
                DexaRegionMetrics(region: "left arm",  bodyFatPercent: 14.2, leanMassKg: 3.8, fatMassKg: 0.64, boneDensityGPerCm2: 0.82, tScore: 0.1, zScore: 0.2),
                DexaRegionMetrics(region: "right arm", bodyFatPercent: 13.8, leanMassKg: 3.9, fatMassKg: 0.62, boneDensityGPerCm2: 0.84, tScore: 0.2, zScore: 0.3),
                DexaRegionMetrics(region: "trunk",     bodyFatPercent: 16.1, leanMassKg: 32.4, fatMassKg: 6.22, boneDensityGPerCm2: nil, tScore: nil, zScore: nil),
                DexaRegionMetrics(region: "left leg",  bodyFatPercent: 20.4, leanMassKg: 12.1, fatMassKg: 3.12, boneDensityGPerCm2: 1.14, tScore: 0.5, zScore: 0.7),
                DexaRegionMetrics(region: "right leg", bodyFatPercent: 21.0, leanMassKg: 12.3, fatMassKg: 3.26, boneDensityGPerCm2: 1.16, tScore: 0.6, zScore: 0.8),
                DexaRegionMetrics(region: "pelvis",    bodyFatPercent: 22.8, leanMassKg: 7.4, fatMassKg: 2.20, boneDensityGPerCm2: 1.42, tScore: 1.1, zScore: 1.2),
            ],
            notes: ["Hologic Horizon A", "Operator: R. Gonzalez DXA RT"],
            rawText: mockDexaPDFText(),
            confidence: 0.92
        )
    }

    // MARK: - Mock PDF text

    static func mockBloodworkPDFText() -> String {
        """
        Quest Diagnostics
        Patient Name: Test Patient
        Date of Service: 11/14/2025
        Ordering Physician: Dr. Smith

        COMPREHENSIVE METABOLIC PANEL
        Glucose                           94          65-99         mg/dL          Normal
        Sodium                           141          136-145       mmol/L         Normal
        Potassium                         4.1         3.5-5.1       mmol/L         Normal
        Creatinine                        0.92        0.7-1.3       mg/dL          Normal
        eGFR                             98           >60           mL/min/1.73m2  Normal

        LIPID PANEL
        Total Cholesterol                182          <200          mg/dL          Normal
        LDL Cholesterol                   98          <100          mg/dL          Normal
        HDL Cholesterol                   62          >40           mg/dL          Normal
        Triglycerides                     88          <150          mg/dL          Normal
        Apolipoprotein B                  72          <90           mg/dL          Normal

        DIABETES PANEL
        Glucose                           94          65-99         mg/dL          Normal
        HbA1c                             5.2         < 5.7         %              Normal
        Insulin, Fasting                  4.8         2.6-24.9      uIU/mL         Normal

        THYROID PANEL
        TSH                               1.82        0.45-4.5      mIU/L          Normal

        VITAMINS
        Vitamin D, 25-OH                  42          30-100        ng/mL          Normal

        IRON STUDIES
        Ferritin                          85          15-150        ng/mL          Normal

        LIVER PANEL
        AST                               22          10-40         U/L            Normal
        ALT                               18          7-56          U/L            Normal

        INFLAMMATION
        hs-CRP                            0.4         <1.0          mg/L           Normal

        HORMONE PANEL
        Testosterone, Total              620          264-916       ng/dL          Normal
        Cortisol (AM)                     14.2        6.2-19.4      mcg/dL         Normal

        This is a computer generated report. Authorized Signature on File.
        """
    }

    static func mockDexaPDFText() -> String {
        """
        Hologic
        DEXA Body Composition Report
        Scan Date: 09/22/2025
        Facility: Advanced Imaging Center

        TOTAL BODY COMPOSITION
        Body Fat Percent: 18.4 %
        Lean Mass (kg): 67.2
        Total BMD: 1.28 g/cm2
        T-score: 0.6
        Z-score: 0.8

        VISCERAL FAT
        Visceral Fat Rating: 1.2
        Visceral Fat Area: 42.8 cm2
        Visceral Fat Volume: 312.4 cm3
        Android/Gynoid Ratio: 0.84

        Left Arm
        14.2   3.8   0.64   0.82

        Right Arm
        13.8   3.9   0.62   0.84

        Trunk
        16.1   32.4  6.22

        Left Leg
        20.4   12.1  3.12   1.14

        Right Leg
        21.0   12.3  3.26   1.16

        Pelvis
        22.8   7.4   2.20   1.42

        BONE DENSITY BY REGION
        Lumbar Spine L1-L4 BMD: 1.42 g/cm2  T-score: 1.1  Z-score: 1.2

        Operator: R. Gonzalez DXA RT
        Device: Hologic Horizon A
        """
    }

    // MARK: - PDF generation (for integration tests)

    /// Generate a minimal but valid PDF containing the bloodwork text.
    /// Uses PDFKit's write(to:) path via in-memory data.
    static func mockBloodworkPDF() -> Data {
        makePDF(text: mockBloodworkPDFText(), title: "Bloodwork Report - Quest Diagnostics")
    }

    static func mockDexaPDF() -> Data {
        makePDF(text: mockDexaPDFText(), title: "DEXA Scan Report - Hologic")
    }

    private static func makePDF(text: String, title: String) -> Data {
        let pdfDocument = PDFDocument()
        let page = PDFPage()

        // Create an annotated text page
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "AmachHealth Tests"
        ]

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        return renderer.pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            ]
            text.draw(
                in: CGRect(x: 36, y: 36, width: 540, height: 720),
                withAttributes: attributes
            )
        }
    }
}
