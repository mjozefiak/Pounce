import Foundation

/// The short transcript "Wypróbuj na przykładzie" runs the notes on. Made up for the purpose, Polish like the
/// meetings it is meant for; nothing in it is real.
enum NotesSample {
    static let utterances: [NotesUtterance] = [
        NotesUtterance(
            startMs: 0, speaker: "Anna", text: "Dzień dobry, zaczynamy przegląd wdrożenia nowej wersji aplikacji."),
        NotesUtterance(
            startMs: 12_000, speaker: "Marek", text: "Testy są gotowe, ale brakuje jeszcze dokumentacji dla klienta."),
        NotesUtterance(
            startMs: 27_000, speaker: "Anna", text: "Zatwierdzamy wdrożenie na czwartek, jeśli wszystkie testy przejdą."
        ),
        NotesUtterance(startMs: 41_000, speaker: "Anna", text: "Marek, prześlij dokumentację do środy."),
        NotesUtterance(startMs: 48_000, speaker: "Marek", text: "Dobrze, wyślę ją w środę rano."),
        NotesUtterance(
            startMs: 60_000, speaker: "Ola", text: "Czy klient wie o oknie serwisowym w czwartek wieczorem?"),
        NotesUtterance(startMs: 70_000, speaker: "Anna", text: "Nie wiem, to trzeba jeszcze sprawdzić."),
    ]
}
