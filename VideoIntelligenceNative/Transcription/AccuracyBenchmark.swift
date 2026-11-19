import Foundation

enum AccuracyBenchmark {
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceWords = words(reference)
        let hypothesisWords = words(hypothesis)
        guard !referenceWords.isEmpty else { return hypothesisWords.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesisWords.count)
        for (i, referenceWord) in referenceWords.enumerated() {
            var current = [i + 1]
            for (j, hypothesisWord) in hypothesisWords.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (referenceWord == hypothesisWord ? 0 : 1)))
            }
            previous = current
        }
        return Double(previous.last ?? referenceWords.count) / Double(referenceWords.count)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
