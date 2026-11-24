import Foundation
import RexplainCore

@main
struct RexplainMain {
    static func main() async {
        let code = await RexplainCLI.run(Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(code)
    }
}
