import Foundation

/// Round 8 probes (PR 134, owner decision 2026-11-20, variant A). Every text is invented. They are the probes
/// of the fifth verification, tagged `R5-`. `ok` is true for a correct cleanup; a text that loses the final
/// version (L) or turns the sentence round (R) is false. With a negation before the first marker the guard
/// pastes the raw text for all of them (`FormatterGuard.negationBeforeMarker`); the others get the verdict of
/// `main`. The correct cleanups with a negation before the marker are false alarms, the price of the rule.
extension GuardProbeTable {
    static let round8: [Row] = [
        (
            "R5-O1", "we meet on monday and the review is on friday sorry on thursday and then we all go home",
            "We meet on Thursday and then we all go home.", false
        ),
        (
            "R5-O2", "zamów dwie pizze i trzy cole czekaj cztery cole i to wszystko na dziś",
            "Zamów 4 cole i to wszystko na dziś.", false
        ),
        ("R5-O3", "to nie jest właściwie gotowe do wysyłki", "Gotowe do wysyłki.", false),
        ("R5-O4", "we should not actually ship it today", "Ship it today.", false),
        ("R5-O5", "napisz Piotrkowi nie czekaj na mnie z kolacją", "Na mnie z kolacją.", false),
        ("R5-O6", "tell her i am sorry about the delay", "About the delay.", false),
        (
            "R5-P1", "spotkanie jest w piątek ale nie przyjdę czekaj w czwartek o dziesiątej rano",
            "Spotkanie jest w czwartek o dziesiątej rano.", false
        ),
        ("R5-P2", "put it on the shelf do not touch it sorry on the big table", "Put it on the big table.", false),
        (
            "R5-P3", "idę na zakupy i nie kupię mleka czekaj na targ przy rynku w sobotę",
            "Idę na targ przy rynku w sobotę.", false
        ),
        (
            "R5-P4", "send the report to anna and do not call her sorry to mark and to the whole team",
            "Send the report to Mark and to the whole team.", false
        ),
        ("R5-P5", "jedziemy do Krakowa w piątek pociągiem czekaj w sobotę", "Jedziemy do Krakowa w sobotę.", false),
        (
            "R5-P6", "pay the rent and the bills today sorry the bills tomorrow",
            "Pay the rent and the bills tomorrow.", true
        ),
        ("R5-P7", "to jest drogie to znaczy to jest tanie", "To jest drogie.", false),
        ("R5-P8", "spotkanie w poniedziałek w sali B czekaj w sali C", "Spotkanie w poniedziałek w sali C.", true),
        ("R5-P9", "spotkanie w poniedziałek w sali B czekaj w sali C", "Spotkanie w sali C.", false),
        ("R5-P10", "przyjdę o ósmej o ile zdążę czekaj o dziewiątej", "Przyjdę o 8 o 9.", false),
        ("R5-P11", "spotkanie we wtorek w sali pięć czekaj w środę", "Spotkanie we wtorek w środę.", false),
        ("R5-G1", "nie przyjdę jutro czekaj przyjdę jutro", "Nie przyjdę jutro.", false),
        ("R5-G2", "nie kupuj tego teraz czekaj kupuj", "Nie kupuj.", false),
        ("R5-G3", "do not send it yet sorry send it now", "Do not send it now.", false),
        ("R5-G4", "nie dzwoń do Anny czekaj do Marka", "Nie dzwoń do Marka.", true),
        ("R5-G5", "wyślij to w piątek czekaj nie w piątek tylko w sobotę", "Wyślij to w piątek.", false),
        ("R5-G6", "przyjdę w piątek czekaj nie przyjdę w piątek", "Nie przyjdę w piątek.", true),
        ("R5-G7", "it is ready actually it is not ready", "It is ready.", false),
        ("R5-G8", "the store is never closed on sunday sorry on monday", "The store is never closed on Monday.", true),
        ("R5-G9", "nigdy nie płać gotówką czekaj płać kartą", "Nigdy nie płać kartą.", false),
        ("R5-G12", "don't ever send it to them sorry send it", "Don't ever send it.", false),
        ("R5-G10", "it is not ready actually it is ready", "It is ready.", true),
        ("R5-S1", "kup chleb a właściwie bułki", "Bułki.", false),
        ("R5-S2", "she is tired or actually just bored", "Just bored.", false),
        ("R5-S3", "Anna zostaje a właściwie Marek wychodzi", "Marek wychodzi.", false),
        ("R5-S4", "nie idę albo jednak idę", "Nie idę.", false),
        ("R5-S5", "pójdziemy do kina albo jednak nie pójdziemy", "Nie pójdziemy.", true),
        ("R5-S6", "we pay cash or actually card", "Card.", false),
        ("R5-S7", "tea or actually coffee", "Coffee.", true),
        ("R5-S8", "ja a właściwie my zapłacimy", "My zapłacimy.", true),
        ("R5-S9", "nie płać albo jednak płać", "Nie płać.", false),
        (
            "R5-M1", "wyślij w piątek czekaj w sobotę właściwie w niedzielę", "Wyślij w sobotę właściwie w niedzielę.",
            true
        ),
        ("R5-M2", "wyślij w piątek czekaj w sobotę właściwie w niedzielę", "Wyślij w sobotę.", false),
        ("R5-M3", "wait for me at the gate sorry at the door", "Wait for me at the door.", true),
        ("R5-M4", "i mean it the deadline is friday sorry monday", "I mean it, the deadline is Friday.", false),
        ("R5-M5", "the test actually passed on friday sorry on monday", "The test actually passed on Monday.", true),
        ("R5-M6", "to właściwie nie działa czekaj działa", "To nie działa.", false),
        ("R5-D1", "zamów dwadzieścia pięć sztuk czekaj trzydzieści sztuk", "Zamów 30 sztuk.", true),
        ("R5-D2", "zamów dwadzieścia pięć sztuk czekaj trzydzieści sztuk", "Zamów 25 sztuk.", false),
        ("R5-D3", "mamy trzy sale i dwadzieścia krzeseł czekaj trzydzieści krzeseł", "Mamy 3 sale i 30 krzeseł.", true),
        ("R5-D4", "pokój numer pięć dwadzieścia osób czekaj trzydzieści osób", "Pokój numer 30 osób.", false),
        ("R5-D5", "pokój numer pięć dwadzieścia osób czekaj trzydzieści osób", "Pokój numer 5, 30 osób.", true),
        ("R5-D6", "room five twenty people sorry thirty people", "Room 30 people.", false),
        ("R5-X1", "w piątek czekaj w sobotę", "W sobotę.", true),
        ("R5-X2", "w piątek czekaj w sobotę", "W piątek.", false),
        ("R5-X3", "tak czekaj nie", "Tak.", false),
        ("R5-X4", "nie sorry tak", "Nie.", false),
        ("R5-X5", "yes or actually no", "No.", true),
        ("R5-X6", "no or actually yes", "No.", false),
        ("R5-X7", "dwa czekaj trzy", "2.", false),
        ("R5-X8", "dwa czekaj trzy", "3.", true),
        ("R5-X9", "to Anna sorry to Mark", "To Mark.", true),
    ]
}
