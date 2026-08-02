import Foundation

private struct CandidateAudit {
    let accepted: Bool
    let issues: [String]
}

@main
struct QualityEvaluationMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let rewriteMode: RewriteMode = arguments.contains("--expand")
                ? .expand
                : .polish
            let selector = arguments.first { !$0.hasPrefix("--") }
            let keychainAPIKey = try KeychainStore().read()
            let apiKey = ProcessInfo.processInfo.environment["POLE_API_KEY"]
                ?? keychainAPIKey
            guard let apiKey,
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fputs("未找到 Pole 钥匙串中的通义千问 API Key。\n", stderr)
                Foundation.exit(2)
            }

            let client = QwenClient()
            let model = QwenClient.defaultModel
            let corpus = rewriteMode == .expand
                ? ExpansionQualityCorpus.core
                : RewriteQualityCorpus.core
            let samples: [RewriteQualitySample]
            if let selector, let limit = Int(selector) {
                samples = Array(corpus.prefix(max(0, limit)))
            } else if let selector {
                samples = corpus.filter { $0.id == selector }
            } else {
                samples = corpus
            }
            var passed = 0
            var unchangedFailures = 0
            var guardFailures = 0
            var retried = 0
            var totalMilliseconds = 0

            for sample in samples {
                let role: ApplicationWritingRole = sample.category == .development
                    ? .development
                    : .messaging
                let prompt = prompt(
                    for: sample.sourceText,
                    role: role,
                    rewriteMode: rewriteMode
                )
                let startedAt = DispatchTime.now().uptimeNanoseconds
                var candidate = try await client.optimize(
                    text: sample.sourceText,
                    apiKey: apiKey,
                    model: model,
                    prompt: prompt
                )
                var candidateAudit = audit(
                    sourceText: sample.sourceText,
                    outputText: candidate,
                    role: role,
                    rewriteMode: rewriteMode
                )

                if !candidateAudit.accepted {
                    retried += 1
                    candidate = try await client.optimize(
                        text: sample.sourceText,
                        apiKey: apiKey,
                        model: model,
                        prompt: prompt,
                        retryIssues: candidateAudit.issues
                    )
                    candidateAudit = audit(
                        sourceText: sample.sourceText,
                        outputText: candidate,
                        role: role,
                        rewriteMode: rewriteMode
                    )
                }

                let changed = normalized(sample.sourceText) != normalized(candidate)
                let meetsChangeExpectation: Bool
                if rewriteMode == .expand, sample.requiresImprovement {
                    meetsChangeExpectation = candidate.count
                        >= RewriteLengthBudget.expansion.preferredMinimumCharacters(
                            for: sample.sourceText.count
                        )
                } else {
                    meetsChangeExpectation = sample.requiresImprovement ? changed : true
                }
                let accepted = candidateAudit.accepted && meetsChangeExpectation
                if accepted {
                    passed += 1
                } else if !meetsChangeExpectation {
                    unchangedFailures += 1
                } else {
                    guardFailures += 1
                }

                let elapsed = Int(
                    (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                )
                totalMilliseconds += elapsed
                print("[\(accepted ? "PASS" : "FAIL")] \(sample.id) \(elapsed)ms")
                print("原文：\(sample.sourceText)")
                print("结果：\(candidate)")
                if !candidateAudit.issues.isEmpty {
                    print("问题：\(candidateAudit.issues.joined(separator: "；"))")
                }
                print("")
            }

            let average = samples.isEmpty ? 0 : totalMilliseconds / samples.count
            print(
                "SUMMARY mode=\(rewriteMode == .expand ? "expand" : "polish") "
                    + "total=\(samples.count) passed=\(passed) "
                    + "unchanged_failures=\(unchangedFailures) guard_failures=\(guardFailures) "
                    + "retried=\(retried) average_ms=\(average)"
            )
            if passed != samples.count { Foundation.exit(1) }
        } catch {
            fputs("质量评估失败：\(error.localizedDescription)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func prompt(
        for sourceText: String,
        role: ApplicationWritingRole,
        rewriteMode: RewriteMode
    ) -> String {
        let applicationContext = ApplicationContext(
            bundleIdentifier: role == .messaging
                ? "com.tencent.xinwechat"
                : "com.openai.codex",
            displayName: role == .messaging ? "微信" : "Codex",
            role: role
        )
        let communicationInstruction: String?
        if role == .messaging {
            communicationInstruction = CommunicationPolicy(
                intent: CommunicationIntentAnalyzer.infer(from: sourceText),
                relationshipRole: nil,
                relationshipConfidence: 0,
                dimensions: nil,
                voice: VoiceMetrics(),
                voiceSampleCount: 0,
                customInstruction: nil,
                messageExpansionRatio: 1.35
            ).modelInstruction
        } else {
            communicationInstruction = nil
        }
        let applicationInstruction = ApplicationContextPolicy.contextInstruction(
            for: applicationContext,
            conversationInstruction: communicationInstruction
        )
        let semanticInstruction = SemanticLibraryCatalog.modelInstruction(
            for: sourceText,
            enabled: SemanticLibraryID.defaultEnabled
        )
        let contextInstruction = [applicationInstruction, semanticInstruction]
            .compactMap { $0 }
            .joined(separator: "\n")
        if rewriteMode == .expand {
            return PromptPolicy.expansionPrompt(
                contextInstruction: contextInstruction
            )
        }
        return PromptPolicy.polishPrompt(
            basePrompt: PromptPolicy.currentDefault,
            contextInstruction: contextInstruction,
            adaptivePlan: AdaptivePolishPolicy.plan(
                for: sourceText,
                applicationRole: role
            )
        )
    }

    private static func audit(
        sourceText: String,
        outputText: String,
        role: ApplicationWritingRole,
        rewriteMode: RewriteMode
    ) -> CandidateAudit {
        let lengthBudget: RewriteLengthBudget?
        switch rewriteMode {
        case .expand:
            lengthBudget = .expansion
        case .polish:
            lengthBudget = AdaptivePolishPolicy.plan(
                for: sourceText,
                applicationRole: role
            ).lengthBudget
        }
        let result = StructuredRewriteResult(rewrittenText: outputText)
        let fact = FactGuard.audit(
            sourceText: sourceText,
            result: result,
            applicationRole: role,
            expansionRatio: 1.35,
            lengthBudget: lengthBudget
        )
        let voice = VoiceGuard.audit(
            sourceText: sourceText,
            outputText: outputText,
            expectedVoice: VoiceMetrics(),
            applicationRole: role
        )
        let alignment = RewriteAlignmentGuard.audit(
            sourceText: sourceText,
            outputText: outputText,
            applicationRole: role,
            rewriteMode: rewriteMode,
            lengthBudget: lengthBudget
        )
        let quality = RewriteQualityGuard.audit(
            sourceText: sourceText,
            outputText: outputText,
            applicationRole: role,
            rewriteMode: rewriteMode,
            lengthBudget: lengthBudget
        )
        let issues = fact.issues + voice.issues + alignment.issues + quality.issues
        return CandidateAudit(
            accepted: fact.accepted && voice.accepted && alignment.accepted && quality.accepted,
            issues: issues
        )
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
