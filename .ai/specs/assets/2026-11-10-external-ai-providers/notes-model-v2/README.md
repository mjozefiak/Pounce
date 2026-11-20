# Makieta v2: wybór dostawcy i modelu notatek ze spotkań

Statyczny HTML, bez kodu aplikacji. **ZAAKCEPTOWANY wzorzec dla PR z UI (A6), 1:1; decyzje: `DECYZJE.md`.** Otwórz `index.html` (przełączniki Light/Dark i EN/PL na pasku; `?theme=dark&lang=pl`).
Zrzuty: `zrzut-<ekran>-<light|dark>-<pl|en>.png` (32 pliki), generowane `shots.mjs` jednym procesem headless Chromium (nie Chrome właściciela).
Wdrożone uwagi właściciela z 2026-11-20: zero kart, **dostawca → model jako menu**, bez okna zgody, krótka wspólna informacja z odnośnikiem „Szczegóły”.

## Ekrany
| Id | Co pokazuje |
|---|---|
| A-local | Domyślnie: Lokalnie + model wbudowany. Podpis „nic nie opuszcza Maca”. |
| A-menu | **DZIŚ**: menu dostawcy otwarte. Grupy: „Na tym Macu” (Lokalnie), „Narzędzia na Twojej subskrypcji” (Claude Code), „Dodaj dostawcę…”. |
| A-models | Drugie menu: modele Claude Code (lewo), modele wbudowane (prawo). |
| A2-claude-on | Wybrany Claude Code: baner, wiersze, **stała informacja 2 zdania + „Szczegóły”**. Brak okna. |
| B-details | „Szczegóły” rozwinięte w miejscu (niemodalnie): pełna lista. |
| E-tomorrow | **JUTRO**: kilku dostawców i trzy rodzaje podłączenia (Lokalnie / CLI na subskrypcji / klucz API). Dwa warianty menu dla niedostępnych (A: wyszarzone z powodem, C: tylko działające + „Dodaj dostawcę…”), wybrane CLI i wybrany klucz API ze wspólną informacją i nazwą firmy. **Wszystkie przyszłe pozycje (Codex, Pi, OpenCode, Anthropic API) mają przerywaną ramkę „przykład” i nagłówek „przykład układu, nie obietnica”; nazw ich modeli nie podano („modele dostawcy”).** |
| C-states | 9 stanów: 1 brak CLI, 2 niezalogowany, 3 niezgodna wersja, 4 model niedostępny w planie, **5a błąd bez fallbacku** (wcześniejszy wybór właściciela), **5b pytanie po awarii** (D7-C), 6 za długi, 7 powrót na Lokalnie (D6), 8 zmiana modelu bez pytania, 9 „Użyj Lokalnie” podczas zadania (D12). |
| D-marker | „Wysłano do: Claude · Sonnet” w Szczegółach notatki i w wierszu biblioteki. |

Informacja przy wyborze (PL): „Transkrypty spotkań, imiona mówców i zatwierdzone terminy ze słownika opuszczają tego Maca i trafiają do **Anthropic**. Wybór tego dostawcy oznacza Twoją zgodę.” Ta sama konstrukcja dla każdego dostawcy zewnętrznego, z nazwą firmy z deskryptora (`recipient`). Wariant klucza API ma w „Szczegółach” inne wiersze (inne warunki, brak słownika; patrz niżej).

## Skąd fakty
- **Spec** `.ai/specs/2026-11-10-external-ai-providers.md`, **ADR 0011** i **0013** (origin/main): co wychodzi, kiedy, „nigdy”, automatyczne ponowienia, uczestnicy nie są informowani, znacznik, stany, fallback jednokierunkowy.
- **Kod** `Sources/LintelProviders/ProviderDescriptor.swift`: `claudeCode` ma dziś modele `sonnet` i `haiku` (id = alias CLI), `--model <id>` w argv, id walidowane (`isValidModelID`: do 64 znaków, litery, cyfry, `. _ - [ ]`), zakres wersji CLI 2.1.0–2.1.x (zmierzone na 2.1.328), `isolationVerified: false` do decyzji o kanarku 5. **Lokalnie**: `LLMModelCatalog` ma dwa modele: Qwen3 4B Instruct 2507 (domyślny, ok. 2,5 GB, od 8 GB RAM) i Qwen3 30B-A3B Instruct 2507 (ok. 18,6 GB, od 32 GB RAM); menu pokazuje też, który jest zainstalowany.
- **Claude Code CLI**: `claude --version` → `2.1.329 (Claude Code)` (mieści się w zakresie deskryptora), `claude --help` (tylko pomoc i wersja; żadnego wywołania z treścią ani sesji) oraz dokumentacja przez Context7 (`/websites/code_claude`, strony model-config, cli-reference, settings-reference, errors).

## Jak Claude Code nazywa i wybiera modele
**Pewne** (z `--help` 2.1.329 i dokumentacji):
- `--model <model>`: „alias najnowszego modelu (np. `fable`, `opus`, `sonnet`) albo pełna nazwa modelu”. Aliasy: `sonnet`, `opus`, `haiku`, `fable`. Pełne nazwy np. `claude-opus-5-5`, `claude-fable-5-2`. `--model` ma pierwszeństwo nad ustawieniem `model` i zmienną `ANTHROPIC_MODEL`.
- Alias wskazuje najnowszą wersję znaną danej wersji CLI i **zmienia się w czasie**. Dokumentacja dziś: na Anthropic API `opus`→Opus 5.5, `sonnet`→Sonnet 5.5, `haiku`→Haiku 5.5, `fable`→Fable 5.2. „Earlier versions resolve these aliases to older models”; minimalne wersje CLI: Sonnet 5.5 ≥ 2.1.284, Opus 5.5 ≥ 2.1.280, Haiku 5.5 ≥ 2.1.293. Pełna nazwa przypina wersję.
- Istnieje „domyślny” model zależny od typu konta (dziś według dokumentacji Opus 5.5 na Pro/Max/Team/Enterprise/API; historycznie inne).
- Plan może nie obejmować modelu: dokumentacja podaje komunikat „Claude Opus is not available with the Claude Pro plan…”. Organizacja może ograniczać wybór (`availableModels` w ustawieniach zarządzanych).
- `claude --help` (2.1.329) **nie pokazuje komendy wypisującej modele**. Wybór listy modeli jest w sesji interaktywnej (`/model`), której nie wolno nam uruchamiać.

**Założenia (niesprawdzone, bo nie wolno było uruchomić wywołania):**
1. Lista modeli musi być **wkompilowana** w deskryptor (jak dziś `sonnet`, `haiku`) albo użytkownik wpisuje identyfikator; z CLI nie da się jej odczytać bez wywołania. Makieta pokazuje wersję wkompilowaną: Sonnet, Haiku.
2. Czy `--model default` jest przyjmowane jako „model konta”: **nie wiadomo**. W menu go nie ma; D15.
3. Czy wynik `--output-format json` mówi, który konkretny model odpowiedział (potrzebne, żeby znacznik pokazał „Sonnet 5.5” zamiast samego aliasu). Makieta pokazuje alias („Sonnet”), bo to jedyne, co Lintel wie na pewno.
4. Które modele dopuszcza plan użytkownika: Lintel tego nie wie z góry, więc pokazuje stan 4 (błąd po fakcie). Czy `--setting-sources ""` wyłącza też `availableModels`: nie sprawdzono.
5. Opus i Fable w menu wymagają zmiany deskryptora i powtórzenia kanarka oraz bramki G dla każdego (spec: kanarek „powtarzany dla każdego nowego zakresu”). Dziś w deskryptorze ich nie ma.
6. Zużycie limitu subskrypcji różni się między modelami; Lintel go nie zna (D8).

## Czego NIE sprawdzono
Zgodności 1:1 z aplikacją (menu to nowy komponent; w `SettingsPane` są dziś `MenuPicker` i `ModelChoiceRow`), VoiceOver i klawiatury (menu otwarte tylko statycznie), `lintelTextSize`, długich nazw modeli, działania żadnego przyszłego dostawcy. Kolory i okno z prototypu `lintel-app` (jak v1). Dane wymyślone (Orchard weekly sync, Kasia, Marek).
Pliki: `DECYZJE.md` (D5–D10, D12–D15, bez wyboru), `CO-OSLABIA.md` (co słabnie bez okna zgody).
