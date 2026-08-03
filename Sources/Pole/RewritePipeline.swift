import Foundation

struct RewriteAuditBundle: @unchecked Sendable {
    let fact: FactAuditResult
    let voice: VoiceAuditResult
    let alignment: RewriteAlignmentAuditResult
    let quality: RewriteQualityAuditResult
    let contextual: ContextualExpansionAuditResult?

    var isSafe: Bool {
        fact.accepted && alignment.accepted
    }

    var isQualityAccepted: Bool {
        quality.accepted && (contextual?.accepted ?? true)
    }

    var retryIssues: [String] {
        if !isSafe {
            return fact.issues + alignment.issues
        }
        return Array(
            (quality.issues + (contextual?.issues ?? [])).prefix(1)
        )
    }

    var guardHits: [String] {
        var hits: [String] = []
        if !fact.accepted { hits.append("fact") }
        if !alignment.accepted { hits.append("alignment") }
        if !quality.accepted { hits.append("quality") }
        if contextual?.accepted == false { hits.append("contextual") }
        if !voice.accepted { hits.append("voice_warning") }
        if !quality.warnings.isEmpty { hits.append("quality_warning") }
        return hits
    }

    var blockingIssues: [String] {
        fact.issues
            + alignment.issues
            + quality.issues
            + (contextual?.issues ?? [])
    }
}

struct RewritePipeline {
    private struct AuditRequest: @unchecked Sendable {
        let sourceText: String
        let result: StructuredRewriteResult
        let applicationRole: ApplicationWritingRole
        let expansionRatio: Double
        let semanticLibraries: Set<SemanticLibraryID>
        let expectedVoice: VoiceMetrics
        let rewriteMode: RewriteMode
        let lengthBudget: RewriteLengthBudget?
        let expansionPlan: ContextualExpansionPlan?
    }

    func audit(
        sourceText: String,
        result: StructuredRewriteResult,
        applicationRole: ApplicationWritingRole,
        expansionRatio: Double,
        semanticLibraries: Set<SemanticLibraryID>,
        expectedVoice: VoiceMetrics,
        rewriteMode: RewriteMode,
        lengthBudget: RewriteLengthBudget?,
        expansionPlan: ContextualExpansionPlan?
    ) async -> RewriteAuditBundle {
        let request = AuditRequest(
            sourceText: sourceText,
            result: result,
            applicationRole: applicationRole,
            expansionRatio: expansionRatio,
            semanticLibraries: semanticLibraries,
            expectedVoice: expectedVoice,
            rewriteMode: rewriteMode,
            lengthBudget: lengthBudget,
            expansionPlan: expansionPlan
        )
        return await Task.detached(priority: .userInitiated) {
            let outputText = request.result.rewrittenText
            return RewriteAuditBundle(
                fact: FactGuard.audit(
                    sourceText: request.sourceText,
                    result: request.result,
                    applicationRole: request.applicationRole,
                    expansionRatio: request.expansionRatio,
                    semanticLibraries: request.semanticLibraries,
                    lengthBudget: request.lengthBudget
                ),
                voice: VoiceGuard.audit(
                    sourceText: request.sourceText,
                    outputText: outputText,
                    expectedVoice: request.expectedVoice,
                    applicationRole: request.applicationRole
                ),
                alignment: RewriteAlignmentGuard.audit(
                    sourceText: request.sourceText,
                    outputText: outputText,
                    applicationRole: request.applicationRole,
                    rewriteMode: request.rewriteMode,
                    lengthBudget: request.lengthBudget
                ),
                quality: RewriteQualityGuard.audit(
                    sourceText: request.sourceText,
                    outputText: outputText,
                    applicationRole: request.applicationRole,
                    rewriteMode: request.rewriteMode,
                    lengthBudget: request.lengthBudget
                ),
                contextual: request.expansionPlan.map {
                    ContextualExpansionGuard.audit(
                        sourceText: request.sourceText,
                        outputText: outputText,
                        plan: $0
                    )
                }
            )
        }.value
    }
}
