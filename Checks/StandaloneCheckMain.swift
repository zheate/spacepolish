import Foundation

@main
struct StandaloneCheckMain {
    static func main() {
        if runPoleRegressionChecks() > 0 {
            exit(1)
        }
    }
}
