import Foundation

struct RewriteQualitySample {
    enum Category: String {
        case manufacturing
        case optics
        case embedded
        case customer
        case colleague
        case casual
        case development
        case boundary
    }

    let id: String
    let category: Category
    let sourceText: String
    let requiresImprovement: Bool
    let protectedTokens: [String]

    init(
        _ id: String,
        _ category: Category,
        _ sourceText: String,
        requiresImprovement: Bool = true,
        protectedTokens: [String] = []
    ) {
        self.id = id
        self.category = category
        self.sourceText = sourceText
        self.requiresImprovement = requiresImprovement
        self.protectedTokens = protectedTokens
    }
}

enum RewriteQualityCorpus {
    // Synthetic and de-identified examples only. These cover the shapes of the
    // user's real work without persisting chat names or private message text.
    static let core: [RewriteQualitySample] = [
        .init("mfg-01", .manufacturing, "王工，BOM里面局部镀的规格现在还没确认，这个你先帮我确认一下然后我这边再算成本。", protectedTokens: ["BOM"]),
        .init("mfg-02", .manufacturing, "CAPA这块的话目前来说还缺原因分析和改善措施，麻烦补充以后再发我。", protectedTokens: ["CAPA"]),
        .init("mfg-03", .manufacturing, "260件订单的备料情况你帮我再确认一下，然后的话有缺料的提前说。", protectedTokens: ["260"]),
        .init("mfg-04", .manufacturing, "这个局部镀报价和之前差的比较多，具体差在哪里你再核对一下。"),
        .init("mfg-05", .manufacturing, "材料已经准备了一部分，剩下的什么时候能好现在还不能确定。"),
        .init("mfg-06", .manufacturing, "成本这边需要先等BOM确定，然后再按最终规格重新算一下。", protectedTokens: ["BOM"]),
        .init("opt-01", .optics, "780 nm激光经过准直以后光斑还是比较大，这个原因现在还需要再分析。", protectedTokens: ["780 nm"]),
        .init("opt-02", .optics, "周总，和俞博讨论了一下，上述指标做不到，原理上好像就不对——无法实现聚焦前后都是方形光斑。"),
        .init("opt-03", .optics, "这个瑞利距离计算的结果和软件不一样，然后参数我又重新检查了一遍暂时没发现问题。"),
        .init("opt-04", .optics, "M²测量的的重复性不太好，今天测了三次结果差别都比较大。", protectedTokens: ["M²"]),
        .init("opt-05", .optics, "准直镜换成20 mm以后发散角有变小，但是还没有达到指标。", protectedTokens: ["20 mm"]),
        .init("embedded-01", .embedded, "新的I2C驱动不太稳定，加电过程中会突然通讯中断，之后一直报错。", protectedTokens: ["I2C"]),
        .init("embedded-02", .embedded, "SDA引脚可能有问题，板子已经寄过去了，收到以后麻烦先帮我测一下。", protectedTokens: ["SDA"]),
        .init("embedded-03", .embedded, "ESP32这边目前来说能够连上，但是数据传一会就会断。", protectedTokens: ["ESP32"]),
        .init("embedded-04", .embedded, "固件升级以后设备有时候起不来，这个还需要再进行一个复现。"),
        .init("customer-01", .customer, "这个指标我们现在还不能确认能做到，需要验证以后才能给结论。"),
        .init("customer-02", .customer, "您提的方案我们看了一下，有两个参数还需要确认，确认以后再回复您。"),
        .init("customer-03", .customer, "报价已经按新的数量重新核算了，附件里面是更新后的版本，您看一下。"),
        .init("customer-04", .customer, "交期目前可能会受材料影响，但是现在还没有最终确定。"),
        .init("customer-05", .customer, "这个问题我们高度重视，现将目前的处理进展同步如下。"),
        .init("colleague-01", .colleague, "你先帮我把报价发给客户，然后再帮我确认一下合同，确认完再回复我。"),
        .init("colleague-02", .colleague, "这个表你更新一下，然后的话里面缺的数据也一起补上。"),
        .init("colleague-03", .colleague, "下午开会要用的材料你先准备一下，有问题提前和我说。"),
        .init("colleague-04", .colleague, "测试做完以后把结果发我一下，然后异常的地方单独标出来。"),
        .init("colleague-05", .colleague, "我看了下这个版本，整体没什么问题，有两个小地方你再改一下。"),
        .init("casual-01", .casual, "你去帮我拿一瓶可乐，帮我打开，然后再帮我拿个小蛋糕吃。"),
        .init("casual-02", .casual, "这个电影我感觉相对来说比较一般，没有之前那个好看。"),
        .init("casual-03", .casual, "好的", requiresImprovement: false),
        .init("casual-04", .casual, "辛苦了", requiresImprovement: false),
        .init("casual-05", .casual, "这个方案我再看看", requiresImprovement: false),
        .init("boundary-01", .boundary, "正文里面的逻辑有点乱，而且前后说法不一致。怎么优化？"),
        .init("boundary-02", .boundary, "这个结果不对，，麻烦再检查一下！！"),
        .init("boundary-03", .boundary, "这个是的的确需要修改。"),
        .init("boundary-04", .boundary, "这次调整的目的主要是为了减少重复操作。"),
        .init("boundary-05", .boundary, "目前来说这边的话还没有收到相关的一个回复。"),
        .init("boundary-06", .boundary, "今天和供应商讨论了材料和交期以及成本几个问题有些地方还没有确定需要他们回去确认之后再统一回复我们。"),
        .init("dev-01", .development, "这个接口现在报错了，你帮我看一下怎么修改，不要改POST /api/v1/calculate。", protectedTokens: ["POST /api/v1/calculate"]),
        .init("dev-02", .development, "运行swift build以后还是失败，然后的话错误信息和之前不一样。", protectedTokens: ["swift build"]),
        .init("dev-03", .development, "请保留/Users/zh/Documents/test/spacepolish这个路径，其他表达可以优化。", protectedTokens: ["/Users/zh/Documents/test/spacepolish"]),
        .init("dev-04", .development, "currentText == capturedText这个判断不能删，这个是为了防止等待的时候覆盖用户新的内容。", protectedTokens: ["currentText", "capturedText"])
    ]
}
