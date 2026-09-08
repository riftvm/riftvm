import RiftVMCLIKit
import Foundation

let cli = RiftVMCLI()
let (exitCode, response) = cli.run(arguments: Array(CommandLine.arguments.dropFirst()))
do {
    FileHandle.standardOutput.write(try cli.encode(response))
} catch {
    FileHandle.standardError.write(Data("riftvm: could not encode response: \(error)\n".utf8))
    exit(RiftVMCLIExit.internalError.rawValue)
}
exit(exitCode.rawValue)
