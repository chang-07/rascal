import Foundation

private let usage = "usage: FileOpsCrashProbe --self-check\n"

guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--self-check" else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(EX_USAGE)
}

print("FileOpsCrashProbe M1 skeleton: ready")
