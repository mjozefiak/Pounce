# Dogfood notatek ze spotkań bez kodu: sprawdzian pełnej godziny i failures.md, zanim powstanie spec edycji

- Date: 2026-11-09
- Category: documentation
- Priority signal: medium — jedyny sposób, by dowiedzieć się, czy notatki spełniają cel użytkownika, bo dotąd oceniali je agenci i sędzia LLM
- Risk signal: low — bez zmian w kodzie produktu
- Routing: om-prepare-issue "Dogfood notatek ze spotkań bez kodu: sprawdzian pełnej godziny na main + failures.md, spec edycji dopiero po ≥5 parach oryginał/edycja — brief: .ai/specs/briefs/2026-11-09-meeting-notes-dogfood.md"

## Problem

Użytkownik chce nagrać spotkanie, zakończyć je i później dostać z transkryptu zwykłą notatkę: kto co mówił, kiedy, co ma zrobić i dlaczego, tak by „jutro usiadł i wiedział, co robić”. Prace zaczęły się, gdy godzinne spotkanie dało kilka linijek z pierwszych sekund. Od tego czasu notatki testowali i oceniali głównie agenci i sędzia Opus, a użytkownik prawie nie widział prawdziwego wyniku. Audyt (`Pounce-eval-archive/audit/AUDIT.md`) pokazał brak prawdy wzorcowej, nieprzetestowanego sędziego i nagrania bez zadań (polskie to podcast).

## Agreed direction

Najpierw proces bez kodu, na obecnym `main`:
1. Sprawdzian: jedno prawdziwe godzinne spotkanie; czy notatki obejmują całą godzinę (blokuje resztę, bo pierwotna porażka nie jest potwierdzona jako naprawiona w aplikacji).
2. Dwa tygodnie: po każdym prawdziwym spotkaniu eksport `.md` → kopia `*.edited.md` z poprawkami → wpis w `failures.md`: „czy wiem, co robić bez odsłuchu?”, „czego brakuje?”, „co zmyślone?”, „kto/co/termin błędne?”. Diff oryginał/edycja daje dane referencyjne.
3. Spec edycji notatek w aplikacji dopiero po ≥5 parach oryginał/edycja albo wyraźnie powtarzającym się wzorcu błędów.

Odrzucone: (a) ręcznie spisany złoty zbiór 3–5 spotkań (1–2 dni pracy użytkownika; wraca, jeśli dogfood zbierze za mało danych); (b) spec UI poprawek od razu (tygodnie pracy przed potwierdzeniem, że użytkownik regularnie nagrywa; kolizja z niezmergowanym `feat/notes-workspace`); (c) „nic” — nie wystarcza, bo bez danych od użytkownika dalsze zmiany jakości nie mają wiarygodnego miernika.

## Resolved unknowns

| Question | Answer (from the conversation) |
|----------|--------------------------------|
| Główny cel? | Notatka z kto/co/kiedy/dlaczego i następnymi krokami, generowana w tle po spotkaniu |
| Jak oceniać? | Dogfood + poprawki użytkownika (wybór użytkownika), początkowo bez kodu |
| Czy edycja notatek istnieje w aplikacji? | Nie na `origin/main` (jest eksport `.md`); edytor tylko na niezmergowanym `feat/notes-workspace`, zapis edycji do `meetings.sqlite` niepotwierdzony |
| Kiedy przejść do speca? | Min. 5 par oryginał/edycja albo powtarzalny wzorzec |
| Kiedy zatrzymać inwestycję? | Mniej niż 3 wpisy w `failures.md` w 2 tygodnie |
| Stan PR | #57, #58, #59, #62 zmergowane; #63 otwarty, `needs-qa`, wymaga rebase na main |

## Non-goals

- Brak zmian w kodzie produktu, UI edycji i nowego magazynu danych w tym kroku.
- Brak włączania `NotesVerifier` (zostaje wyłączony).
- Brak ręcznego złotego zbioru na tym etapie.
- Poprawki nie są mierzone jako recall; pominięcia łapie tylko pole „czego brakuje”.

## Affected areas (if known)

- `Sources/MeetingsPlugin/Export/MarkdownExporter.swift` (eksport `.md`, istnieje).
- Dane i audyt: `Pounce-eval-archive/audit/` (poza repozytorium).
