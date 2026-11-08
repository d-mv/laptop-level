import Foundation
import LaptopLevelCore

exit(CLI.run(arguments: Array(CommandLine.arguments.dropFirst()), deps: .live))
