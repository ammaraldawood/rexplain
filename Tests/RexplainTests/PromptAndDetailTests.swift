import Foundation
import Testing
@testable import RexplainCore

@Suite("Prompt Templates, Effort Levels & Terminal Rendering")
struct PromptAndDetailTests {
    @Test("Three effort levels have distinct step ranges and increasing token ceilings")
    func detailLevels() {
        #expect(DetailLevel.allCases == [.compact, .standard, .firstPrinciples])
        #expect(DetailLevel.compact.stepRange == 3...5)
        #expect(DetailLevel.standard.stepRange == 6...10)
        #expect(DetailLevel.firstPrinciples.stepRange == 14...22)

        #expect(DetailLevel.parse("1") == .compact)
        #expect(DetailLevel.parse("2") == .standard)
        #expect(DetailLevel.parse("3") == .firstPrinciples)
        #expect(DetailLevel.parse("first-principles") == .firstPrinciples)

        #expect(DetailLevel.compact.safetyMaxResponseTokens == 450)
        #expect(DetailLevel.standard.safetyMaxResponseTokens == 1_100)
        #expect(DetailLevel.firstPrinciples.safetyMaxResponseTokens == 2_600)
    }

    @Test("Plain natural instructions and 1-sentence effort directives omit scaffolding and metadata")
    func selectionOnlyPromptDesign() {
        #expect(!PromptTemplates.systemInstructions.contains("Rexplain"))
        #expect(!PromptTemplates.systemInstructions.contains("Assumption:"))

        #expect(PromptTemplates.detailDirective(for: .compact).contains("3–5"))
        #expect(PromptTemplates.detailDirective(for: .standard).contains("6–10"))
        let fp = PromptTemplates.detailDirective(for: .firstPrinciples)
        #expect(fp.contains("first-principles"))
        #expect(fp.contains("foundational definitions"))
        #expect(fp.contains("concrete example"))

        for detail in DetailLevel.allCases {
            let prompt = PromptTemplates.buildExplainPrompt(selection: "SELECT_TOKEN_MARKER", detail: detail)
            #expect(prompt.hasPrefix(PromptTemplates.stablePrewarmPrefix))
            for forbidden in ["[Output Template", "Context:", "Language:", "Source:", "Material/Filetype", "<selection>", "<context>", "(none)", "Assumption:"] {
                #expect(!prompt.contains(forbidden))
            }
            #expect(prompt.contains("SELECT_TOKEN_MARKER"))
            let prefixEnd = prompt.range(of: PromptTemplates.stablePrewarmPrefix)!.upperBound
            let selStart = prompt.range(of: "SELECT_TOKEN_MARKER")!.lowerBound
            #expect(prefixEnd < selStart)
        }
    }

    @Test("TerminalRenderer header formats On-device badge for FMF and Local badge for MLX")
    func terminalHeaderBox() {
        let fmfHeader = TerminalRenderer.headerString(detail: .compact, modelLabel: "On-device", width: 72, includeOSCTitle: true)
        #expect(fmfHeader.contains("Rexplain · On-device · Compact"))
        #expect(!fmfHeader.contains("stays on this Mac"))
        #expect(fmfHeader.contains("\u{001B}]0;Rexplain · On-device · Compact\u{0007}"))

        let mlxHeader = TerminalRenderer.headerString(
            detail: .firstPrinciples,
            modelLabel: "Local · Qwen2.5-0.5B-Instruct-4bit",
            width: 84,
            includeOSCTitle: false
        )
        #expect(mlxHeader.contains("Rexplain · Local · Qwen2.5-0.5B-Instruct-4bit · First-principles"))
        #expect(!mlxHeader.contains("On-device"))
    }
}
