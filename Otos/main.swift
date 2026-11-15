import OtosKit
import SwiftUI

// Started to read text for search, Otos serves readings and never starts the app (ADR 0048).
if CommandLine.arguments.dropFirst().first == SearchTextReadingProcess.argument {
    SearchTextReadingProcess.serve()
}

OtosApp.main()
