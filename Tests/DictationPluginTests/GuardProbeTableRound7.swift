import Foundation

/// Round 7 probes (PR 134, final verification). Every text is invented. A run of number words before the
/// nearest parallel number joins the span only when the words read as ONE number with it: "pięć dwadzieścia" is
/// a room number and a count, so the room is not withdrawn with the count.
extension GuardProbeTable {
    static let round7: [Row] = [
        ("NR1", "pokój numer pięć dwadzieścia osób czekaj trzydzieści osób", "Pokój numer 30 osób.", false),
        ("NR2", "room five twenty people sorry thirty people", "Room 30 people.", false),
        ("NR3", "pokój numer pięć dwadzieścia osób czekaj trzydzieści osób", "Pokój numer 5, 30 osób.", true),
        ("NR4", "room five twenty people sorry thirty people", "Room 5, 30 people.", true),
        ("NR5", "zamów dwadzieścia pięć sztuk czekaj trzydzieści sztuk", "Zamów 30 sztuk.", true),
        ("NR6", "zamów dwadzieścia pięć sztuk czekaj trzydzieści sztuk", "Zamów 20 30 sztuk.", false),
        ("NR7", "we need one hundred and five chairs sorry ninety folding chairs", "We need 90 folding chairs.", true),
        (
            "NR8", "we need one hundred and five chairs sorry ninety folding chairs", "We need 100 90 folding chairs.",
            false
        ),
    ]
}
