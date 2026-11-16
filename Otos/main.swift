import OtosKit
import SwiftUI

// Started to read text for search, Otos serves readings and never starts the app (ADR 0048).
if CommandLine.arguments.dropFirst().first == SearchTextReadingProcess.argument {
    SearchTextReadingProcess.serve(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

OtosApp.main()
