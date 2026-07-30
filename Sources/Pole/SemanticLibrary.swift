import Foundation

enum SemanticLibraryID: String, CaseIterable, Codable, Hashable {
    case opticsAndLaser
    case manufacturingAndQuality
    case projectAndDelivery
    case procurementAndCommercial
    case embeddedHardware
    case softwareDevelopment

    static let defaultEnabled = Set(allCases)

    var displayName: String {
        switch self {
        case .opticsAndLaser:
            return "光学与激光"
        case .manufacturingAndQuality:
            return "制造与质量"
        case .projectAndDelivery:
            return "项目与交付"
        case .procurementAndCommercial:
            return "采购与商务"
        case .embeddedHardware:
            return "嵌入式与硬件"
        case .softwareDevelopment:
            return "软件开发"
        }
    }

    var summary: String {
        switch self {
        case .opticsAndLaser:
            return "保护光斑、波长、焦距、M²、NA、FWHM、镀膜等术语与参数关系。"
        case .manufacturingAndQuality:
            return "区分 BOM、CAPA、8D、批次、工艺、检验、返工与质量状态。"
        case .projectAndDelivery:
            return "保护交期、排期、里程碑、依赖、责任对象与交付状态。"
        case .procurementAndCommercial:
            return "保护报价口径、税费、币种、数量、账期、成本与供应条件。"
        case .embeddedHardware:
            return "保护 I2C、SPI、SDA、GPIO、引脚、总线、上电与故障现象。"
        case .softwareDevelopment:
            return "保护代码标识、命令、路径、版本、接口、错误信息与技术缩写。"
        }
    }
}

struct SemanticLibraryMatch: Equatable {
    let id: SemanticLibraryID
    let score: Int
    let matchedTerms: [String]
}

enum SemanticLibraryPreferences {
    static let defaultsKey = "enabledSemanticLibraries"
    private static let catalogVersionKey = "semanticLibraryCatalogVersion"
    private static let currentCatalogVersion = 2

    static func load(from defaults: UserDefaults) -> Set<SemanticLibraryID> {
        guard defaults.object(forKey: defaultsKey) != nil else {
            return SemanticLibraryID.defaultEnabled
        }
        let rawValues = defaults.stringArray(forKey: defaultsKey) ?? []
        var enabled = Set(rawValues.compactMap(SemanticLibraryID.init(rawValue:)))
        if defaults.integer(forKey: catalogVersionKey) < currentCatalogVersion {
            enabled.insert(.embeddedHardware)
        }
        return enabled
    }

    static func save(_ enabled: Set<SemanticLibraryID>, to defaults: UserDefaults) {
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: defaultsKey)
        defaults.set(currentCatalogVersion, forKey: catalogVersionKey)
    }
}

enum SemanticLibraryCatalog {
    private struct Cue {
        let term: String
        let weight: Int

        init(_ term: String, weight: Int = 2) {
            self.term = term
            self.weight = weight
        }
    }

    private struct Definition {
        let id: SemanticLibraryID
        let cues: [Cue]
        let protectedTerms: [String]
        let modelInstruction: String
    }

    private static let definitions: [Definition] = [
        Definition(
            id: .opticsAndLaser,
            cues: [
                Cue("激光"), Cue("光斑"), Cue("光束"), Cue("波长"), Cue("焦距"),
                Cue("发散角"), Cue("瑞利长度"), Cue("光纤"), Cue("准直"), Cue("聚焦"),
                Cue("透过率"), Cue("镀膜"), Cue("M²"), Cue("M2"), Cue("BPP"),
                Cue("NA"), Cue("FWHM"), Cue("Gaussian"), Cue("功率", weight: 1),
                Cue("能量", weight: 1)
            ],
            protectedTerms: ["M²", "M2", "BPP", "NA", "FWHM", "局部镀"],
            modelInstruction: "保留光学量、符号、单位及输入/输出、聚焦前/后等关系；不要混淆光斑半径与直径、波长与频率，也不要把工程判断改成确定结论。"
        ),
        Definition(
            id: .manufacturingAndQuality,
            cues: [
                Cue("BOM"), Cue("CAPA"), Cue("8D"), Cue("FAI"), Cue("IQC"),
                Cue("OQC"), Cue("NCR"), Cue("ECN"), Cue("ECR"), Cue("来料"),
                Cue("出货"), Cue("返工"), Cue("报废"), Cue("良率"), Cue("批次"),
                Cue("图纸"), Cue("公差"), Cue("工艺"), Cue("质检"), Cue("备料"),
                Cue("局部镀"), Cue("异常单")
            ],
            protectedTerms: [
                "BOM", "CAPA", "8D", "FAI", "IQC", "OQC", "NCR", "ECN", "ECR",
                "局部镀", "备料"
            ],
            modelInstruction: "保留物料、工艺、检验、缺陷、处置和状态之间的区别；缩写、批次、数量、版本与质量结论不得被泛化或擅自补全。"
        ),
        Definition(
            id: .projectAndDelivery,
            cues: [
                Cue("里程碑"), Cue("交期"), Cue("排期"), Cue("交付"), Cue("验收"),
                Cue("样件"), Cue("试产"), Cue("量产"), Cue("发货"),
                Cue("项目", weight: 1), Cue("进度", weight: 1), Cue("跟进", weight: 1),
                Cue("风险", weight: 1), Cue("阻塞", weight: 1), Cue("依赖", weight: 1)
            ],
            protectedTerms: [],
            modelInstruction: "完整保留责任对象、当前状态、依赖、先后顺序和时间口径；不要把计划写成承诺，也不要新增截止日期、下一步或责任人。"
        ),
        Definition(
            id: .procurementAndCommercial,
            cues: [
                Cue("报价"), Cue("单价"), Cue("含税"), Cue("未税"), Cue("税点"),
                Cue("账期"), Cue("付款"), Cue("合同"), Cue("采购"), Cue("供应商"),
                Cue("成本"), Cue("运费"), Cue("币种"), Cue("起订量"), Cue("MOQ"),
                Cue("物料", weight: 1), Cue("数量", weight: 1)
            ],
            protectedTerms: ["含税", "未税", "税点", "账期", "MOQ"],
            modelInstruction: "保留价格口径、税费、币种、数量、单位、运费、交期和付款条件；询价、讨论、确认与接受是不同状态，不要擅自升级。"
        ),
        Definition(
            id: .embeddedHardware,
            cues: [
                Cue("I2C"), Cue("SPI"), Cue("UART"), Cue("GPIO"), Cue("SDA"),
                Cue("SCL"), Cue("MCU"), Cue("ADC"), Cue("DAC"), Cue("PWM"),
                Cue("引脚"), Cue("总线"), Cue("寄存器"), Cue("固件"), Cue("驱动"),
                Cue("上电"), Cue("加电"), Cue("断电"), Cue("复位"), Cue("板卡"),
                Cue("模块", weight: 1), Cue("通信", weight: 1), Cue("通讯", weight: 1),
                Cue("中断", weight: 1), Cue("报错", weight: 1)
            ],
            protectedTerms: [
                "I2C", "SPI", "UART", "GPIO", "SDA", "SCL", "MCU", "ADC",
                "DAC", "PWM"
            ],
            modelInstruction: "逐字保留总线、接口、引脚和信号名称，并保留测试对象、故障现象、发生阶段与排查状态。中文术语采用嵌入式常用表达：设备供电过程优先写“上电”，“通讯”规范为“通信”。描述故障现象时让被观察对象作主语，例如写“通信会突然中断”，不要写“会突然通信中断”；同时区分通信中断与硬件中断，不要把初步怀疑改成已确认故障。"
        ),
        Definition(
            id: .softwareDevelopment,
            cues: [
                Cue("API"), Cue("SDK"), Cue("JSON"), Cue("Swift"), Cue("SwiftUI"),
                Cue("Python"), Cue("Rust"), Cue("TypeScript"), Cue("JavaScript"),
                Cue("React"), Cue("Electron"), Cue("Xcode"), Cue("Git"), Cue("CI/CD"),
                Cue("WASM"), Cue("HTTP"), Cue("HTTPS"), Cue("数据库"), Cue("编译"),
                Cue("前端"), Cue("后端"), Cue("接口"), Cue("报错")
            ],
            protectedTerms: [
                "API", "SDK", "JSON", "Swift", "SwiftUI", "Python", "Rust",
                "TypeScript", "JavaScript", "React", "Electron", "Xcode", "Git",
                "CI/CD", "WASM", "HTTP", "HTTPS"
            ],
            modelInstruction: "逐字保留代码标识、命令、路径、版本、参数、错误信息和逻辑条件；可以改善说明文字，但不要改写代码或推断未提供的技术结论。"
        )
    ]

    static func matches(
        in text: String,
        enabled: Set<SemanticLibraryID> = SemanticLibraryID.defaultEnabled
    ) -> [SemanticLibraryMatch] {
        definitions.compactMap { definition -> SemanticLibraryMatch? in
            guard enabled.contains(definition.id) else { return nil }
            let matched = definition.cues.filter { contains($0.term, in: text) }
            let score = matched.reduce(0) { $0 + $1.weight }
            guard score >= 2 else { return nil }
            return SemanticLibraryMatch(
                id: definition.id,
                score: score,
                matchedTerms: matched.map(\.term)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lhsIndex = SemanticLibraryID.allCases.firstIndex(of: lhs.id) ?? 0
            let rhsIndex = SemanticLibraryID.allCases.firstIndex(of: rhs.id) ?? 0
            return lhsIndex < rhsIndex
        }
    }

    static func modelInstruction(
        for text: String,
        enabled: Set<SemanticLibraryID> = SemanticLibraryID.defaultEnabled
    ) -> String? {
        let selected = matches(in: text, enabled: enabled).prefix(3)
        guard !selected.isEmpty else { return nil }
        let lines: [String] = selected.compactMap { match -> String? in
            guard let definition = definitions.first(where: { $0.id == match.id }) else {
                return nil
            }
            return "- \(definition.id.displayName)：\(definition.modelInstruction)"
        }
        return """
        本机语义库命中了以下专业语境。它们只用于保护原文已有的专业含义，不代表可以补充事实：
        \(lines.joined(separator: "\n"))
        """
    }

    static func protectedTerms(
        in text: String,
        enabled: Set<SemanticLibraryID> = SemanticLibraryID.defaultEnabled
    ) -> [String] {
        definitions
            .filter { enabled.contains($0.id) }
            .flatMap(\.protectedTerms)
            .filter { contains($0, in: text) }
            .reduce(into: [String]()) { terms, term in
                guard !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
                    return
                }
                terms.append(term)
            }
    }

    private static func contains(_ term: String, in text: String) -> Bool {
        let normalizedText = text.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        let normalizedTerm = term.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        let isASCIIWord = normalizedTerm.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII
        }
        guard isASCIIWord else {
            return normalizedText.localizedCaseInsensitiveContains(normalizedTerm)
        }
        let escaped = NSRegularExpression.escapedPattern(for: normalizedTerm)
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        return normalizedText.range(of: pattern, options: .regularExpression) != nil
    }
}
