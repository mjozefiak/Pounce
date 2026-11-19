import Foundation

/// The value of spoken numbers (Polish and English, 1 to 999 999), so `FormatterGuard` can tell that a
/// digit the model wrote stands for the number words the speaker said ("sześćdziesięciu" is 60) and not for
/// some other number. Pure; conservative: a word list that is not a well-formed number gives `nil`.
enum NumberWords {
    private enum Kind { case unit, teen, tens, hundred, thousand, hundredMultiplier }

    private static let english: [String: (Kind, Int)] = {
        var table: [String: (Kind, Int)] = [:]
        let units = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        ]
        for (index, word) in units.enumerated() { table[word] = (.unit, index + 1) }
        let unitOrdinals = [
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        ]
        for (index, word) in unitOrdinals.enumerated() { table[word] = (.unit, index + 1) }
        let teens = [
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
            "nineteen",
        ]
        for (index, word) in teens.enumerated() { table[word] = (.teen, index + 10) }
        let teenOrdinals = [
            "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
            "seventeenth", "eighteenth", "nineteenth",
        ]
        for (index, word) in teenOrdinals.enumerated() { table[word] = (.teen, index + 10) }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let tensOrdinals = [
            "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        ]
        for (index, word) in tens.enumerated() { table[word] = (.tens, (index + 2) * 10) }
        for (index, word) in tensOrdinals.enumerated() { table[word] = (.tens, (index + 2) * 10) }
        table["hundred"] = (.hundredMultiplier, 100)
        table["hundredth"] = (.hundredMultiplier, 100)
        table["thousand"] = (.thousand, 1000)
        table["thousandth"] = (.thousand, 1000)
        return table
    }()

    /// Polish whole words for the hundreds (the inflected forms are too irregular for a stem rule).
    private static let polishHundreds: [String: Int] = [
        "sto": 100, "stu": 100, "sta": 100, "setny": 100, "setna": 100, "setnego": 100,
        "dwieście": 200, "dwustu": 200, "dwusta": 200,
        "trzysta": 300, "trzystu": 300, "czterysta": 400, "czterystu": 400,
        "pięćset": 500, "pięciuset": 500, "sześćset": 600, "sześciuset": 600,
        "siedemset": 700, "siedmiuset": 700, "osiemset": 800, "ośmiuset": 800,
        "dziewięćset": 900, "dziewięciuset": 900,
    ]

    /// Polish stems, checked longest first: a word that starts with a stem has that value ("dwunastej" is 12,
    /// "piętnastu" 15, "pięciu" 5). The longer stems come first so "dwadzie" is not read as "dw".
    private static let polishStems: [(String, Kind, Int)] = {
        var list: [(String, Kind, Int)] = []
        let teens: [(String, Int)] = [
            ("jedena", 11), ("dwana", 12), ("dwuna", 12), ("trzyna", 13), ("czterna", 14), ("piętna", 15),
            ("szesna", 16), ("siedemna", 17), ("osiemna", 18), ("dziewiętna", 19),
        ]
        for (stem, value) in teens { list.append((stem, .teen, value)) }
        let tens: [(String, Int)] = [
            ("dwadzie", 20), ("dwudzie", 20), ("trzydzie", 30), ("czterdzie", 40), ("pięćdzies", 50),
            ("pięćdzies", 50), ("sześćdzies", 60), ("siedemdzies", 70), ("osiemdzies", 80),
            ("dziewięćdzies", 90), ("dziesi", 10),
        ]
        for (stem, value) in tens { list.append((stem, value == 10 ? .teen : .tens, value)) }
        let units: [(String, Int)] = [
            ("jedn", 1), ("pierw", 1), ("dw", 2), ("drug", 2), ("trz", 3), ("czter", 4), ("czwar", 4),
            ("pię", 5), ("pią", 5), ("sześ", 6), ("szós", 6), ("siedem", 7), ("siedmi", 7), ("siódm", 7),
            ("osiem", 8), ("ośmi", 8), ("ósm", 8), ("dziewi", 9),
        ]
        for (stem, value) in units { list.append((stem, .unit, value)) }
        list.append(("tysi", .thousand, 1000))
        return list.sorted { $0.0.count > $1.0.count }
    }()

    private static func classify(_ word: String) -> (Kind, Int)? {
        if let entry = english[word] { return entry }
        if let value = polishHundreds[word] { return (.hundred, value) }
        for (stem, kind, value) in polishStems where word.hasPrefix(stem) { return (kind, value) }
        return nil
    }

    /// The number the words say, or `nil` when a word is not a number word or the order is not a number.
    /// The tokens are lower-cased words with no punctuation.
    static func value(of words: [String]) -> Int? {
        guard !words.isEmpty, words.count <= 9 else { return nil }
        var total = 0
        var group = 0
        // 3 hundreds, 2 tens and teens, 1 units; 4 before anything in a group.
        var lastClass = 4
        var lastUnit = 0
        var thousandsUsed = false
        for word in words {
            guard let (kind, value) = classify(word) else { return nil }
            switch kind {
            case .hundred:
                guard lastClass == 4, group == 0 else { return nil }
                group = value
                lastClass = 3
            case .hundredMultiplier:
                guard lastClass == 1, group == lastUnit, group >= 1, group <= 9 else { return nil }
                group *= 100
                lastClass = 3
            case .tens:
                guard lastClass > 2 else { return nil }
                group += value
                lastClass = 2
            case .teen:
                guard lastClass > 2 else { return nil }
                group += value
                lastClass = 2
            case .unit:
                guard lastClass > 1 else { return nil }
                group += value
                lastUnit = value
                lastClass = 1
            case .thousand:
                guard !thousandsUsed, group < 1000 else { return nil }
                total += (group == 0 ? 1 : group) * 1000
                group = 0
                lastClass = 4
                thousandsUsed = true
            }
        }
        let result = total + group
        return result > 0 ? result : nil
    }

    /// The value of a digit token: "60", "6", or an English ordinal such as "10th". Anything else is `nil`.
    static func value(ofDigits token: String) -> Int? {
        let digits = token.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 7, digits.allSatisfy({ $0.isASCII }) else { return nil }
        let suffix = token.dropFirst(digits.count)
        guard suffix.isEmpty || ["st", "nd", "rd", "th"].contains(String(suffix)) else { return nil }
        return Int(digits)
    }

    /// The value of the digit tokens starting at `index`, grouped the way the tokenizer splits "25 000":
    /// a number of one to three digits followed by groups of exactly three digits. Gives every group length
    /// that reads as one number: 1 token, then 2, ... ("25", "000" is 25 and 25000).
    static func digitValues(in tokens: [String], at index: Int) -> [(tokens: Int, value: Int)] {
        guard index < tokens.count, let first = value(ofDigits: tokens[index]) else { return [] }
        var result = [(tokens: 1, value: first)]
        guard tokens[index].count <= 3, tokens[index].allSatisfy(\.isNumber) else { return result }
        var combined = tokens[index]
        var count = 1
        while index + count < tokens.count, tokens[index + count].count == 3,
            tokens[index + count].allSatisfy({ $0.isASCII && $0.isNumber }), combined.count < 7
        {
            combined += tokens[index + count]
            count += 1
            if let value = Int(combined) { result.append((count, value)) }
        }
        return result
    }
}
