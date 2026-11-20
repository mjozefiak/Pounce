# Autopoprawki w dyktowaniu: wybór spanu i HUD z cofnięciem (wariant B)

> Status: **projekt, tylko dokumenty.** Nic z tego pliku nie jest zaimplementowane. Decyzje właściciela z 2026-11-20 są zapisane jako decyzje (sekcja „Decyzje właściciela"); wszystko, czego te decyzje nie rozstrzygają, jest w sekcji „Pytania otwarte" z opcjami i bez wybranej wartości.
>
> Prototype: makieta v2 (zaakceptowana przez właściciela 2026-11-20 jako wzorzec 1:1, **łącznie ze zmianą rozmiaru HUD względem dzisiejszych 248×40 pt**). Źródło i zrzuty: `.ai/specs/assets/dictation-self-correction-cut/` (`index.html`, `README.md`, `wzorzec-*.png` = zrzuty działającego HUD i historii z builda debug `--qa`, `zrzut-<jasny|ciemny>-<pl|en>-<ref|b|life|big|hist>.png`). Implementacja UI idzie 1:1 z makietą.
>
> Dokumenty powiązane: `.ai/specs/2026-11-01-voice-dictation.md`, `docs/decisions/0004-dictation-formatting.md`, `docs/decisions/0005-builtin-llm.md`, nota pomiarowa `docs/decisions/notes/2026-11-20-span-selection-measurement.md` (PR #180, gałąź `feat/dictation-span-select-measure`, `do-not-merge`, oparta na PR #134), `.ai/specs/2026-11-20-dictation-vocabulary-auto-learn.md` (kontrakt `FocusContextReader`), `BACKWARD_COMPATIBILITY.md` (sekcje 2, 3, 5).
>
> Wszystkie przykłady w tym pliku i w makiecie są wymyślone. Żaden nie pochodzi z prawdziwego dyktowania ani spotkania.

## 📝 TLDR

Gdy ktoś dyktuje „wyślij raport w piątek, nie, czekaj, w poniedziałek”, dziś model wbudowany przepisuje cały fragment, a `FormatterGuard` zgaduje z wyniku, co model zrobił. Pomiar (PR #180, niezależnie powtórzony) pokazał, że prościej jest odwrócić role: **kod** znajduje marker wycofania, **model** odpowiada tylko liczbą (od którego słowa marker cofa) albo `none` pod gramatyką llama.cpp, a **kod** buduje tekst jako „wejście minus [start … koniec markera]”. Model nigdy nie pisze tekstu. Na Qwen3 4B, N = 6: 66 z 79 przypadków korpusu end to end wobec 44 dla `main`.

Metoda nie jest bezbłędna (1 z 5 „negatywów” nadal się tnie, 9 sond bez wycofania też), więc cięcie jest **widoczne i odwracalne jednym klawiszem**: po wklejeniu HUD pokazuje linię z przekreślonym fragmentem, **⌃Z** cofa ostatnie cięcie, **⇧⌃Z** wszystkie, przez 6 s. Gdy cięcie jest „niepewne”, **nie tnie**, tylko je proponuje tym samym klawiszem. Historia dyktowania pokazuje przekreślony fragment, plakietkę i akcję „Wklej bez cięcia”.

Czego ten spec **nie** rozstrzyga: domyślnego stanu przełącznika, mechanizmu cofnięcia w miejscu i kilku zachowań klawisza przy wielu cięciach (sekcja „Pytania otwarte”, Q1–Q12). **Kod wolno zacząć dopiero po podłączeniu Claude w notatkach (A5b).**

## ✅ Decyzje właściciela (2026-11-20)

| Nr | Decyzja |
|---|---|
| **D1** | Wariant B: linia w HUD z przekreślonym fragmentem i cofnięciem jednym klawiszem. Wariant E (historia) jako uzupełnienie. |
| **D2** | Klawisz **⌃Z**, przechwytywany tylko na czas widoczności linii. Do potwierdzenia testem na działającej aplikacji, w tym kolizja z suspend (SIGTSTP) w terminalu. |
| **D3** | **6 s** życia linii. Linia znika wcześniej przy dalszym pisaniu, zmianie pola lub ruchu kursora. |
| **D4** | Lista do **3 cięć** (+N dla reszty). Klawisz cofa ostatnie, **⇧ + klawisz** wszystkie. |
| **D5** | Cięcie niepewne: **NIE ciąć, zaproponować** cięcie tym samym klawiszem. |
| **D6** | Historia: przekreślony fragment, plakietka, akcja „wklej bez cięcia” (**⌥Return**). Addytywna migracja `dictation.sqlite`. |
| **D7** | VoiceOver krótko „Wklejono, 1 cięcie”; przycisk cofnięcia w HUD; reszta punktów dostępności wg listy z DECYZJE.md (tabela w makiecie). |
| **D8** | Drugi ⌃Z tnie ponownie: klawisz jest przełącznikiem, dopóki linia jest widoczna. |
| **D9** | „Niepewne” = reguły z pomiaru: negacja przed poprawką, cięcie > 6 słów, kilka markerów pod rząd, brak wyraźnej wersji zastępczej. **Próg do weryfikacji pomiarem przed wydaniem.** |
| **D10** | Makieta v2 zaakceptowana jako wzorzec 1:1, także zmiana rozmiaru HUD względem 248×40. |
| **D11** | Kod dopiero PO podłączeniu Claude w notatkach (A5b). |
| **D12** | Modele pomiarowe: Qwen3 4B, Qwen3 30B-A3B, Gemma 4 E4B. Model 122B został usunięty i nie jest używany w żadnym pomiarze z tego specu. |

D8 i D4 razem zostawiają niedomkniętą sytuację z wieloma cięciami (Q2).

## 📝 Cel i nie-cele

**Cel.** Usuwać z dyktowanego tekstu samopoprawki z jawnym markerem („w piątek, nie, czekaj, w poniedziałek”), tak aby (1) błąd modelu nigdy nie odwracał sensu (negacja), (2) użytkownik widział, co wycięto, i mógł to cofnąć w ciągu sekund bez wchodzenia w historię, (3) niepewne przypadki nie zmieniały tekstu bez wiedzy użytkownika.

**Nie-cele.**
- Poprawki bez markera („wyślij w piątek w poniedziałek”), fałszywe starty i wypełniacze („yyy”) zostają przy dzisiejszym oczyszczaniu (cleanup prompt + `FormatterGuard`). Cięcie ich nie dotyka (0 z 20 takich przypadków trafia do modelu cięcia).
- Dyktowanie w trybie surowym (bez modelu) i formatter „Mój serwer” (OpenAI-compatible): patrz Q9.
- Dostawca zewnętrzny (Claude) dla samego cięcia: poza zakresem pierwszej wersji (Q10).
- Zmiana `CleanupPrompt` albo `FormatterGuard` poza tym, że guard liczy się względem tekstu po cięciu.
- Uczenie się z cofnięć (telemetria, statystyki). Żadne cofnięcie nie jest liczone ani zapisywane poza historią użytkownika (sekcja „Prywatność”).

## 📝 Proposed Solution

### Przepływ

1. **Marker.** Kod szuka w tekście markera wycofania z listy (PL i EN: „nie, czekaj”, „nie, to znaczy”, „to znaczy”, „a właściwie”, „no wait”, „I mean”, „sorry”, „actually” i pozostałe z `FormatterGuard.retractionMarkers` z PR #134). Wygrywa **najwcześniejszy, a przy równym początku najdłuższy**. Tekst bez markera nie dotyka modelu i nie kosztuje nic (stan „B5” makiety, identyczny z dzisiejszym HUD).
2. **Miejsce w potoku (punkt 1 checklisty recenzenta).** Cięcie działa **po transkrypcji i przed `Segmenter`**, bo wycofanie nie może przechodzić przez granicę dwóch chunków. Realizacja: `SelfCorrectionCutter` stoi między segmentami z silnika mowy a `Segmenter.add`. Zatrzymuje (hold-back) ostatnie **N = 6 słów** każdego tekstu, dopóki kolejny segment nie pokaże, czy zaczyna się od markera, albo do `flush` na końcu nagrania; marker bez ani jednego słowa po sobie czeka na kolejne słowa (reguła `requireRepair`). Okno modelu to zawsze najwyżej 6 słów przed markerem, w obrębie tekstu trzymanego w buforze, więc nigdy nie sięga w chunk już oddany do formatowania. Skutek: oddanie chunka do formatowania opóźnia się o co najwyżej 6 słów mowy (do zmierzenia w bramce opóźnienia).
3. **Decyzja modelu.** Model dostaje słowa z okna ponumerowane 1…N i odpowiada **jednym tokenem**: numerem pierwszego słowa, które marker cofa, albo `none`. Odpowiedź ogranicza gramatyka GBNF (`llama_sampler_init_grammar`, w pinned llama.cpp b11600): `root ::= "none" | "1" | … | "6"`. Dekodowanie zachłanne, odpowiedź spoza gramatyki = `none` (w pomiarze 0 z 268 wywołań na model). Prompt jest wersjonowany (`SelfCorrectionPrompt.version`, ten sam rodzaj zachowania widocznego dla użytkownika co `CleanupPrompt.version`, wpis w sekcji 5 `BACKWARD_COMPATIBILITY.md`), 6 wymyślonych przykładów few-shot, sprawdzonych jawnym testem, że nie pokrywają się z korpusem.
4. **Reguły ochronne (kod, nie model).** W tej kolejności, każda może tylko **zostawić, odmówić albo przesunąć start o jedno słowo** (test własnościowy, niżej):
   1. **negacja na wyborze modelu**: usunięty span zawiera negację, a po markerze żadna nie zostaje, to `none`; ocenia **własny wybór modelu, przed wyrównaniem** (inaczej start na „nie” przesunięty o słowo dawał „nie wysyłaj tego teraz” z odwróconym sensem, błąd znaleziony przez recenzenta, 4B);
   2. **wyrównanie** (`align`): start przesuwany o jedno słowo na pierwsze słowo poprawki, z równoważeniem „we/w”; na korpusie naprawia 45 przesunięć o jeden i psuje 0 trafnych;
   3. **wymagana poprawka** (`requireRepair`): zero słów po markerze = brak cięcia (marker na końcu chunka, „potrzebujemy sześćdziesięciu sztuk właściwie”, 4B ciął do „potrzebujemy”);
   4. **kotwica markera z negacją** (`anchorNegatingMarkers`): marker zawierający negację („nie, czekaj”) tnie tylko gdy pierwsze słowo po markerze występuje w usuwanym spanie (odmawia 11 z 34 trafnych cięć, ale uniemożliwia oba negatywy z negującym markerem użytym jako treść);
   5. **negacja na końcowym spanie**: ponowne sprawdzenie po wszystkich przesunięciach.
5. **Łańcuchy.** Od lewej do prawej, jedna decyzja na marker; usunięty span może pokryć wcześniejszy marker; cięcie nie może utworzyć nowego markera (asercja w teście). Na sześciu oznaczonych łańcuchach „od końca” wypada gorzej lub tak samo i traci negację na jednym nieoznaczonym, więc zostaje lewo→prawo. **Sześć łańcuchów niczego nie rozstrzyga**: przed wydaniem powstaje syntetyczny zbiór łańcuchów (bramka B6).
6. **Budowa tekstu.** Wynik = wejście bez [start … koniec markera]. Następnie dalszy potok jak dziś: słownik użytkownika (`TermReplacer`), cleanup prompt, `FormatterGuard` **liczony względem tekstu po cięciu**. Gdy guard odrzuci wynik cleanupu, wklejany jest **tekst po cięciu**, nie surowy (punkt 7 checklisty).
7. **Niepewne.** Gdy reguła (1), (4) albo (5) odmówiła cięcia, które model zaproponował, albo zachodzi któryś z warunków D9 (negacja przed poprawką; usuwany span razem z markerem dłuższy niż **6 słów**; kilka markerów pod rząd, czyli łańcuch; brak wyraźnej wersji zastępczej, startowo poprawka krótsza niż 2 słowa), tekst jest wklejany **w całości, bez cięcia**, a HUD pokazuje stan „Propozycja cięcia” (B6): ten sam ⌃Z **wycina** (D5, D8). Odpowiedź `none` modelu i reguła (3) nie tworzą propozycji (nie ma czego proponować). Liczby progowe (6 słów, 2 słowa) są **wartościami startowymi do weryfikacji pomiarem przed wydaniem** (bramka B4), nie decyzją.
8. **Wklejenie i HUD.** Po wklejeniu HUD pokazuje linię „Wycięto: …” (jedno cięcie, B1), listę do 3 cięć z „+N” (B3, B4) albo propozycję (B6). Szczegóły niżej.

### Co model dostaje i co zwraca (przykład, wymyślony)

Wejście: „wyślij raport w piątek nie czekaj w poniedziałek rano”. Marker: „nie, czekaj”. Okno (N = 6): `1 wyślij 2 raport 3 w 4 piątek`. Odpowiedź: `3`. Wynik cięcia: „wyślij raport w poniedziałek rano”. Przy wejściu „napisz do Piotra nie czekaj na mnie”: marker „nie czekaj” użyty jako treść; po wyborze modelu `none` albo regułach (1) i (4) wynik pozostaje bez cięcia.

### Zmiany w `LLMRuntime` (punkt 4 checklisty)

- **Addytywnie**: parametr gramatyki w `generate`/`generateResult` (domyślna implementacja rozszerzenia protokołu **nie ignoruje po cichu** gramatyki: rzuca `unsupported`, bo wynik bez gramatyki łamie kontrakt „model zwraca tylko liczbę”). `LlamaRuntime` implementuje przez `llama_sampler_init_grammar`. Opcjonalnie (faza późniejsza, Q11): prawdopodobieństwa tokenów odpowiedzi jako margines pewności.
- **Klucz dzierżawy równy kluczowi cleanupu** (ten sam model, ta sama długość kontekstu), żeby cięcie nie wymieniało modelu w `LLMLease`. Priorytet `interactive`. Gdy dzierżawa jest zajęta innym kluczem (`ModelLeaseError.busy`): **bez cięcia**, tekst wklejany jak dziś, bez propozycji i bez komunikatu (cichy powrót do dzisiejszego zachowania, zapis w diagnostyce jako licznik).
- Brak zainstalowanego modelu wbudowanego, błąd ładowania, przekroczony budżet czasu: te same powroty co `BuiltInFormatter` (tekst bez cięcia). Nigdy nie blokuje wklejenia.

### Opóźnienie i budżet (punkt 9 checklisty)

Pomiar w ścieżce produktu (bez cache prefiksu, bo `LlamaRuntime` czyści KV przed każdym żądaniem, a w kolejności „wywołanie spanu, potem cleanup” cache i tak znika): Qwen3 4B **≈ 0,33 s na marker** (p50; 30B 0,32 s, Gemma 4 E4B 0,36 s), pierwsze wywołanie po załadowaniu 0,34 s, ładowanie 0,3 do 1,1 s przy pliku w cache stron. Cleanup 4B bez cache 0,43 s. Chunk bez markera: koszt 0.

Budżet proponowany (do potwierdzenia pomiarem w aplikacji na referencyjnym Macu, bramka B5): **p50 ≤ 0,4 s i p95 ≤ 0,6 s na marker**, a suma dodana do jednego dyktowania **≤ 1,5 s** (przy 4 markerach). Po przekroczeniu sumy: kolejne markery w tym dyktowaniu **nie dostają cięcia ani propozycji** (tekst jak dziś); licznik w diagnostyce. Cache prefiksu wymagałby dwóch stanów KV w `LlamaRuntime`, a `LLMLease` oddaje ten sam model Meetings i Notes, które by go wyparły, więc **nie wchodzi do tego zakresu**. Jeśli budżet p95 nie zostanie spełniony na 4B, przełącznik zostaje domyślnie wyłączony (Q1) i opisujemy to w wydaniu.

## 📝 UI/UX (1:1 z makietą v2)

Wzorzec: `.ai/specs/assets/dictation-self-correction-cut/index.html` (przełączniki jasny/ciemny, PL/EN) i zrzuty `zrzut-*`. Poniżej opis, który nie zastępuje makiety.

### HUD (decyzje D1–D5, D7, D10)

- **Brak cięcia (B5)**: kapsuła 248×40 pt, identyczna z dzisiejszym HUD „Wklejono”, bez linii i bez opóźnienia.
- **Cięcie wykonane (B1)**: karta szerokości 336 pt (rośnie w dół): górny wiersz to dzisiejsza kapsuła „Wklejono” + przycisk **Cofnij**; poniżej wiersz „Wycięto: ~~w piątek, nie,~~”; na dole pasek odliczania 6 s (2 pt). Przycisk jest też w HUD, bo klawisz globalny nie jest jedyną drogą.
- **Po cofnięciu (B2)**: „Cięcie cofnięte” / „Cięcia cofnięte”, tekst w polu jest dokładnie tym, co podyktowano. Zachowanie kolejnego ⌃Z: patrz D8 i Q2.
- **Kilka cięć (B3, B4)**: do 3 wierszy od najstarszego do najnowszego; reszta jako „+N więcej (w historii)”; ⌃Z cofa **ostatnie**, ⇧⌃Z **wszystkie** (także ukryte pod „+N”).
- **Propozycja (B6)**: nagłówek „Propozycja cięcia”, wiersz „Nie wycięto (niepewne): <fragment>” z **przerywanym podkreśleniem** (nic nie jest wycięte), przycisk **Wytnij** i bursztynowa ikona. Ten sam klawisz ma tu **przeciwne** znaczenie niż w B1, więc etykieta, nagłówek i ikona różnią się, a kolor nie jest jedynym nośnikiem.
- **Czas życia i zdarzenia (D3)**: 6 s od wklejenia. Linia znika **od razu** przy dalszym pisaniu lub dyktowaniu w tym samym polu (⌃Z zwolniony), zmianie pola lub aplikacji, ruchu kursora (strzałki, kliknięcie: cofnięcie w miejscu przestaje być pewne) i po 6 s. Wpis zostaje w historii.
- **Rozmiar tekstu**: dzisiejszy HUD ma stałe 248×40 pt i **nie skaluje się** z `app.textSize`. Karta z linią skaluje się (XL = ×1,3, `TextSize.scale`): 336 → ok. 437 pt, wiersze zawijają się, przycisk Cofnij nie znika; szerokość ogranicza ekran. Wymiary narysowane w makiecie, **nie zmierzone w aplikacji** (do sprawdzenia w bramce B7).
- **Zwiększony kontrast**: obrys 1 pt w kolorze tekstu jak w dzisiejszym HUD (`contrast == .increased`), pasek odliczania w kolorze tekstu. **Redukcja ruchu**: pasek statyczny (pełny), linia znika bez przejścia.
- **Kolory** wyłącznie z `LintelBrand`; szkło HUD jak dziś (Liquid Glass w makiecie przybliżone: porównać w aplikacji).

### Klawisze (D2, D4, D8, D9)

| Klawisz | Gdy widać cięcie | Gdy widać propozycję |
|---|---|---|
| **⌃Z** | cofa ostatnie cięcie; drugi ⌃Z tnie ponownie (przełącznik, D8) | wycina zaproponowany fragment |
| **⇧⌃Z** | cofa wszystkie cięcia tego dyktowania | wycina wszystkie propozycje |

⌃Z i ⇧⌃Z są przechwytywane **tylko na czas widoczności linii** (jak tymczasowy claim Esc, `PluginContext.claimEscapeKey`). To wymaga **addytywnego** uogólnienia kontraktu `LintelKit`: `PluginContext.claimKey(_:handler:)` z wartością domyślną „nic nie przechwytuje” (zwraca nieaktywny claim) i z regułą „jeden claim na klawisz”; zmiana w jednym PR kontraktowym, zgodnie z kolejką PR-ów `LintelKit`. Gdy rejestracja zostanie odrzucona (inna aplikacja), `isActive == false` i HUD pokazuje samą nazwę przycisku bez podpowiedzi klawisza (jak dziś „✕ cancels”). **Kolizja z terminalem** (⌃Z = SIGTSTP) i z ⌃Z aplikacji docelowych jest bramką B1 (nie rozstrzygniętą); do czasu jej wyniku nie wiadomo, czy przechwycenie na 6 s jest akceptowalne (Q3).

### Historia (D6, wariant E)

- Wiersz z cięciem: ikona, tytuł, „wiek · czas” jak dziś; w tytule fragment przekreślony (tytuł to jedna linia z wielokropkiem, więc przekreślenie widać tylko, gdy cięcie mieści się w ok. 240 pt), plakietka „N cięć” (PL: 1 cięcie, 2–4 cięcia, 5+ cięć).
- Podgląd: tekst z przekreślonym wyciętym fragmentem **zawsze** widoczny; przełącznik Sformatowany/Surowy jak dziś.
- Stopka: „Wklej”, „Wklej surowy ⌘↩” (istnieje), nowe **„Wklej bez cięcia” ⌥↩**. Wiersz bez cięcia wygląda jak dziś. Klawisz ⌥↩ jest w makiecie placeholderem: ⌘↩ jest już „Wklej surowy”, a ⌥ na układzie polskim wpisuje znaki, więc kolizja wymaga sprawdzenia (Q4).
- Akcja „Wklej bez cięcia” wkleja tekst odtworzony bez cięć (definicja: Q5).

### VoiceOver (D7)

| Moment | Co słychać |
|---|---|
| Po wklejeniu z 1 cięciem | „Wklejono, 1 cięcie” (jedno ogłoszenie, wysoki priorytet) |
| Kilka cięć | „Wklejono, 3 cięcia” (polskie liczby: 1 cięcie, 2–4 cięcia, 5+ cięć; warianty liczby w String Catalog `en` i `pl`) |
| Brak cięcia | „Wklejono” jak dziś |
| Propozycja | „Wklejono, propozycja cięcia” |
| Przycisk | „Cofnij cięcie, Control Z” / „Wytnij, Control Z” |
| Wiersz z cięciem | „Wycięto:” czytane przed fragmentem; przekreślenie nie jest jedynym nośnikiem |

Ogłoszenia idą przez mechanizm ogłoszeń HUD (w kodzie `AnnouncementGate` jest dziś w `MeetingHUD`/`DictationHUD`; sprawdzić przy implementacji, czy wymaga przeniesienia do `LintelUI`). Tabela jest z makiety; pełna lista punktów dostępności z DECYZJE.md obowiązuje jako źródło, a ten spec jej nie powiela.

## 📝 Data Model

### `dictation.sqlite` (addytywna migracja `v2-cuts`; BC sekcja 2)

Migracja `v1-history` **nie jest edytowana**. Nowa migracja `v2-cuts` dodaje do `dictation_entry`:

| Kolumna | Typ | Domyślnie | Znaczenie |
|---|---|---|---|
| `cut_count` | `INTEGER NOT NULL` | `0` | liczba wykonanych cięć; 0 dla wszystkich dotychczasowych wpisów (plakietka i filtr bez parsowania JSON) |
| `cuts_json` | `TEXT` | `NULL` | wersjonowana tablica cięć i propozycji, patrz niżej; `NULL` = brak |

Format `cuts_json` (wersja 1): `{"v":1,"cuts":[{"kind":"cut"|"proposal","start":Int,"length":Int}]}`, gdzie `start`/`length` to **przesunięcia w jednostkach UTF-16 w `raw_text` tego samego wpisu** (tekst „tak, jak usłyszano”, już zapisany). **Wycięty fragment nie jest kopiowany do nowej kolumny**: jest podłańcuchem `raw_text`. Dzięki temu migracja nie dodaje żadnej nowej kopii treści, a FTS (`dictation_fts` nad `raw_text` i `formatted_text`) zostaje bez zmian. Nieznana wersja `v` = wpis bez cięć w widoku (nic się nie psuje).

`formatted_text` zostaje tym, co wklejono (po cięciu). `paste_result` bez zmian. Wpis z propozycją ma `cut_count = 0` i wpis `proposal` w `cuts_json`.

**BC**: wyłącznie kolumny z wartościami domyślnymi i migracja addytywna; test „otwórz bazę w schemacie v1 z danymi i zmigruj” (wymóg sekcji 2) jest w kroku 3.1. Starsza kompilacja widząca nowszy schemat wyłącza historię z komunikatem, jak dziś (nie migruje wstecz). **Aktualizacja `BACKWARD_COMPATIBILITY.md`** w tym samym PR: wiersz tabeli sekcji 2 (nazwa migracji, kolumny, format), klucz ustawienia w sekcji 3, klawisze i zachowanie w sekcji 5, `SelfCorrectionPrompt.version` w sekcji 5.

### Ustawienie (nazwa i wartość domyślna: Q1)

Jedno ustawienie typu Bool w przestrzeni `plugins.dictation.*` (nazwa robocza `plugins.dictation.selfCorrectionCut`; **chroniona przestrzeń kluczy, nazwa zamrożona w pierwszym wydaniu**). **Wartość domyślna nie jest rozstrzygnięta** (Q1); do czasu odpowiedzi właściciela spec jej nie zakłada, a plan PR-ów zakłada, że kod wchodzi z przełącznikiem czytanym z jednego miejsca, więc zmiana domyślnej jest jednolinijkowa.

## 📝 Prywatność

- **Wycięty fragment: gdzie żyje.** (1) w pamięci kontrolera dyktowania na czas okna cofnięcia (do 6 s plus czas dopóki linia jest widoczna) razem z tekstem alternatywnym; zerowany po zniknięciu linii, jak `lastRawText` dziś (które zostaje w pamięci, nie na dysku); (2) w historii **wyłącznie jako przesunięcia** w `raw_text` (patrz „Data Model”), czyli w tej samej zaszyfrowanej bazie SQLCipher co cała historia dyktowania (klucz w Keychain, `service = com.lintelapp.dictation`), z tą samą retencją (30 dni / 500 wpisów) i tym samym Clear History / Erase Data. Nie powstaje żaden nowy plik, cache ani kopia tekstu. Czy fragment ma żyć krócej niż wpis: Q6.
- **Nigdy w logach.** Ani fragment, ani tekst alternatywny, ani prompt, ani odpowiedź modelu cięcia; logowane są tylko liczby (liczba markerów, liczba cięć, długość w słowach, czas) i kody powrotu (`busy`, `timeout`, `noModel`). Test skanujący źródła jak dla Meetings.
- Nic do `ranking.sqlite`, nic na schowek ponad dzisiejsze okno przywracania (`TextPaster`): tekst alternatywny wkleja się tą samą ścieżką co zwykłe wklejenie, z tym samym znacznikiem transient i przywracaniem schowka.
- **Nie dodaje sieci.** Cięcie działa wyłącznie na modelu wbudowanym lokalnie.
- Obserwacja pola do unieważnienia cofnięcia (D3: pisanie, zmiana pola, ruch kursora) **czyta wyłącznie to, czy pole i zaznaczenie się zmieniły, nie ich treść** (Q7 opisuje zależność od `FocusContextReader`); żadna treść pola nie jest czytana na potrzeby tej funkcji.

## 📝 Edge Cases & Failure Scenarios

| Sytuacja | Zachowanie |
|---|---|
| Marker bez słów po sobie | brak cięcia, brak propozycji; czeka na kolejne słowa albo `flush` |
| Marker w pierwszych N słowach chunka | okno sięga w bufor hold-back, nie w oddany chunk |
| Marker użyty jako treść („napisz Piotrowi nie czekaj na mnie”) | `none` modelu albo reguły (1), (4); 2 z 5 negatywów korpusu z negującym markerem to znana luka reguł (negacja jest częścią markera) |
| Dwa markery pod rząd | łańcuch: wszystkie decyzje lewo→prawo; wynik niepewny wg D9 (kilka markerów pod rząd), więc propozycja zamiast cięcia |
| Model niezainstalowany, dzierżawa zajęta, błąd, przekroczony budżet | tekst bez cięcia, bez komunikatu; licznik diagnostyczny |
| Pole nieobserwowalne (aplikacja bez dostępności, np. część aplikacji Electron) albo brak zaufania Dostępności | cofnięcie w miejscu nie jest pewne: Q7 |
| Użytkownik zaczął pisać zanim linia się pojawiła | brak linii (zdarzenie zdążyło unieważnić); wpis w historii |
| Wklejenie zakończone `copied` (tylko schowek, np. brak zaufania do wklejania) | brak linii cofnięcia (nie ma co cofać w polu); wpis w historii z cięciem |
| Rozmiar tekstu XL, wąski ekran | karta zawija wiersze, przycisk zostaje (do zmierzenia w B7) |
| Dyktowanie przerwane Esc | brak wklejenia, brak linii, brak wpisu (jak dziś) |

## 📝 Testy

- **Model-free (CI):** testy z PR #180 (`SpanSelectPropertyTests` i pochodne) przeniesione do kodu produktu: każda decyzja o starcie przed pierwszym markerem plus `none` zostawia słowa wejścia w kolejności i wszystko po markerze bez zmian; dla łańcuchów każdy liść drzewa decyzji w oknie (bez cichego limitu); **`theDeterministicRulesOnlyKeepCancelOrShiftByOne`**: dla każdego startu okna, N = 4/6/8/12, każdy zestaw reguł, reguła tylko zostawia, odmawia albo przesuwa o jedno słowo, nigdy nie zamienia `none` w cięcie.
- **Test własnościowy „0 odwróceń sensu” (bramka B3):** dla każdego wejścia ze zbioru syntetycznego i każdej decyzji modelu z przestrzeni decyzji (nie tylko tej z nagrania) wynik końcowy **nie traci żadnej negacji spoza usuwanego markera**, a negacja, która jest częścią markera, jest sprawdzana osobno (znana luka: 2 przypadki korpusu). Zliczanie z noty („0 z 147 sond”) zamienione na asercję.
- Testy parsowania odpowiedzi, gramatyki (każda dozwolona i każda niedozwolona odpowiedź), reguł z osobna i w kolejności, propozycji (D9), budżetu i powrotów (busy/brak modelu/timeout).
- Testy HUD: stan B1–B6 jako czyste modele (`HUDState` i nowy model linii), wygasanie (czas wstrzyknięty), unieważnianie zdarzeniami, ⌃Z jako przełącznik, ⇧⌃Z, „+N”, liczba mnoga, ogłoszenie VoiceOver raz.
- Testy migracji `v2-cuts` ze schematu v1 z danymi; test, że `cuts_json` z nieznaną wersją nie psuje widoku; test, że przesunięcia zawsze mieszczą się w `raw_text` (UTF-16, znaki złożone, polskie znaki).
- Testy tekstowe String Catalog (`en` i `pl`, warianty liczby), skan źródeł: brak logowania tekstu, brak `fatalError`/`try!`/force unwrap, brak surowych kolorów poza `LintelBrand`.
- Testy z prawdziwym modelem: wyłączone domyślnie, jak dla Dictation i Meetings (zmienna środowiskowa), nigdy w CI.

## 📝 Bramki przed wydaniem

Kod nie jest „gotowy do wydania”, dopóki **wszystkie** bramki B1–B8 nie mają wyniku w PR (a przy nieudanej: decyzji właściciela).

| Nr | Bramka | Kryterium |
|---|---|---|
| **B1** | **Test ⌃Z na działającej aplikacji** (build debug z `--qa…`, nie /Applications) | Przechwycenie ⌃Z tylko na czas linii działa; zwolnienie po zniknięciu, po zdarzeniu i po 6 s; **kolizja z terminalem** (suspend, SIGTSTP) w co najmniej jednym emulatorze terminala i z ⌃Z aplikacji docelowych (cofnięcie w edytorach); rejestracja odrzucona = HUD bez podpowiedzi klawisza. Wynik z zrzutami w komentarzu QA. |
| **B2** | **Cofnięcie w miejscu** | Wybrany w Q8 mechanizm działa w co najmniej: polu tekstowym AppKit, polu w przeglądarce (WebKit i Chromium), edytorze kodu, aplikacji Electron, polu hasła (nie dotyczy, ma być bezpiecznie pominięte). Wynik „zastąpiono dokładnie wklejony tekst albo nic nie zmieniono” (nigdy częściowo). |
| **B3** | **Test własnościowy 0 odwróceń sensu** | Wyniki jak w sekcji „Testy”; 0 utraconych negacji na zbiorze syntetycznym, w tym negatywy z negującym markerem użytym jako treść i znana luka opisana wprost. |
| **B4** | **Pomiar progu „niepewne”** | Progi D9 (6 słów, 2 słowa poprawki, łańcuch) zmierzone na większym zbiorze syntetycznym (punkt 10 checklisty): liczba cięć zamienionych na propozycje, liczba trafnych cięć utraconych, liczba fałszywych cięć, które przeszły. Wynik wpisany do noty pomiarowej; wartości progowe w kodzie są tymi z noty. |
| **B5** | **Opóźnienie w ścieżce produktu** | p50 ≤ 0,4 s i p95 ≤ 0,6 s na marker oraz ≤ 1,5 s na dyktowanie (Qwen3 4B, bez cache prefiksu), oraz zimny start (pierwsze dyktowanie po załadowaniu). Nie „0,33 s z noty”, tylko pomiar w aplikacji. |
| **B6** | **Zbiór syntetyczny i korpus** | Korpus autocorrect (79 przypadków, w zleceniu „C1”) plus 265 wejść sond PR #134 plus **nowy** zbiór: markery jako treść (zwłaszcza negujące), łańcuchy (min. kilkadziesiąt), marker na końcu chunka, marker blisko granicy chunka, poprawki bez markera (poza zakresem, opisane). Kryterium: **0 utraconych negacji; fałszywe cięcia na negatywach, które trafiają do modelu, 0 jako cięcie zastosowane** (niepewne zamienione na propozycje liczą się osobno). Jeśli nie osiągnięte: przełącznik zostaje domyślnie wyłączony (Q1). |
| **B7** | **UI 1:1 z makietą** | Porównanie każdego stanu B1–B6, historii, jasny/ciemny, PL/EN, XL, Zwiększony kontrast, Redukcja ruchu z zrzutami makiety; pomiar karty XL; VoiceOver (nagranie lub opis odsłuchu), czego makieta nie sprawdziła. |
| **B8** | **Prywatność** | Test skanujący źródła (brak logowania tekstu), potwierdzenie, że nowa migracja nie dodaje kopii treści, Erase Data/Clear History usuwają wpisy z cięciami (test). |

Modele pomiarowe: tylko Qwen3 4B (rekomendowany), Qwen3 30B-A3B i Gemma 4 E4B (D12). Gemma 4 wymaga własnego szablonu rozmowy (`llama_chat_apply_template` go nie zna): bez rozwiązania tego nie jest kandydatem do produktu.

## ❓ Pytania otwarte (niczego nie rozstrzygnięto za właściciela)

| Nr | Pytanie | Opcje | Rekomendacja autora (nie decyzja) |
|---|---|---|---|
| **Q1** | **Domyślny stan przełącznika i jego miejsce w Ustawieniach.** Właściciel nie podał. | A: domyślnie wyłączone, włącza użytkownik; B: domyślnie włączone; C: domyślnie włączone dopiero po spełnieniu bramki B6 (do tego czasu wyłączone). Miejsce: Dictation → Basics, obok „Clean up text”, albo Advanced. | C (zależność od bramki B6 jest jawna), ale to decyzja produktowa. |
| **Q2** | **Wiele cięć a przełącznik.** D4: ⌃Z cofa ostatnie; D8: drugi ⌃Z tnie ponownie. Co robi drugi ⌃Z przy 3 cięciach, i czy ⇧⌃Z też jest przełącznikiem? | A: ⌃Z zawsze przełącza **to samo** (ostatnio ruszane) cięcie: cofnij, potem wytnij ponownie; ⇧⌃Z cofa wszystkie, drugi ⇧⌃Z tnie wszystkie. B: kolejne ⌃Z cofają po kolei od ostatniego do pierwszego, po ostatnim kolejne ⌃Z tnie ponownie od pierwszego. | A (dosłownie „przełącznik” z D8). |
| **Q3** | **Kolizja ⌃Z z terminalem i edytorami.** Przechwycenie ⌃Z na 6 s odbiera aplikacji docelowej ⌃Z (w terminalu suspend). | A: przechwytywać zawsze; B: nie przechwytywać, gdy aplikacja docelowa jest na liście terminali/edytorów (bundle ID, lista w kodzie), przycisk w HUD zostaje; C: zależnie od wyniku bramki B1. | C (wynik B1 decyduje). |
| **Q4** | **Klawisz „Wklej bez cięcia”** (⌥↩ w makiecie jest placeholderem; ⌘↩ = Wklej surowy; ⌥ na układzie PL). | A: ⌥↩ (jeśli bramka sprawdzi kolizję); B: ⇧⌘↩; C: tylko przycisk w stopce, bez skrótu. | A po sprawdzeniu na układzie PL, wynik w bramce B7. |
| **Q5** | **Czym jest „tekst bez cięcia”** (cofnięcie w HUD i „Wklej bez cięcia” w historii). Cleanup jest liczony na tekście po cięciu, więc wersja bez cięcia go nie ma. | A: chunk „jak podyktowano” (z słownikiem, bez cleanupu; szybko, bez LLM, mniej wygładzone); B: w oknie 6 s w tle liczony drugi cleanup bez cięcia, gotowy na ⌃Z (dodatkowe ≈ 0,43 s LLM na chunk z cięciem; gdy niegotowy, wariant A); C: zawsze oba cleanupy od razu (podwaja koszt chunków z markerem). Dla historii: A albo B przy zapisie. | B dla HUD, A dla historii; wymaga zgody właściciela, bo wpływa na to, co „przywrócono dokładnie”. |
| **Q6** | **Okres życia wyciętego fragmentu w historii.** Dziś: jako przesunięcia w `raw_text`, czyli tak długo jak wpis. | A: tak długo jak wpis (30 dni / 500); B: krócej (np. po kilku dniach `cuts_json` jest zerowane, fragment zostaje w `raw_text`, więc to tylko ukrywa przekreślenie); C: bez zapisu w historii (wariant E odpada). | A (nie ma nowej kopii treści; D6 wymaga zapisu). |
| **Q7** | **Skąd wiadomo, że cofnięcie jest jeszcze bezpieczne** (pisanie, zmiana pola, ruch kursora), oraz co gdy pola nie da się obserwować. Wymaga obserwacji pola przez Dostępność (kontrakt `FocusContextReader` ze specu auto-nauki: tożsamość pola, powiadomienie o utracie fokusu; jeszcze nie w `main`). | A: zależność od `FocusContextReader` (cięcie wchodzi po DICT-2.1/2.2); B: własne, węższe źródło zdarzeń (zdarzenia klawiatury i myszy) bez treści pola; c) pole nieobserwowalne: C1 nie ciąć wcale (propozycja w historii), C2 ciąć z linią i przyciskiem z krótszym czasem życia, C3 ciąć bez cofania w miejscu (cofnięcie tylko z historii). | A + C1 (najostrożniejsze), ale opóźnia wydanie o DICT-2.x. |
| **Q8** | **Mechanizm cofnięcia w miejscu.** | A: ⌘Z w aplikacji docelowej (jeśli wklejenie jest jednym krokiem cofania), potem wklejenie tekstu alternatywnego; B: Dostępność: zaznaczenie zakresu wklejonego tekstu i wklejenie alternatywy; C: usunięcie N znaków (Backspace) i wklejenie. Każdy ma luki (A: grupowanie cofania w aplikacji; B: pole bez zakresu; C: dowolny ruch kursora). | Decyzja po bramce B2; autor nie rekomenduje przed testem. |
| **Q9** | **Zakres formatterów.** Gramatyka wymaga lokalnego `LlamaRuntime`. | A: tylko model wbudowany (wymagany zainstalowany Qwen3 4B); B: także „Mój serwer” (llama-server z parametrem gramatyki; inne serwery bez); C: także tryb surowy (z modelem tylko do cięcia). | A w pierwszej wersji. |
| **Q10** | **Claude (dostawca zewnętrzny) dla cięcia** po A5b. Wysyła tekst dyktowania do dostawcy (inna prywatność niż dziś). | A: nigdy w tym zakresie; B: opcjonalnie, osobna zgoda w oknie zgody dostawców; C: spec osobno później. | A lub C. |
| **Q11** | **Margines pewności z prawdopodobieństw tokenów** (opcjonalne rozszerzenie `LLMRuntime`) jako dodatkowe kryterium „niepewne”. | A: nie w pierwszej wersji; B: tak, jeśli pomiar B4 pokaże korzyść. | A, B jako faza późniejsza. |
| **Q12** | **Lista markerów.** Dziś nie ma jej na `main` (jest w PR #134). Brakujące: „albo jednak”, samo „no”. | A: lista w nowym typie `RetractionMarkers` w kodzie produktu (PR #134 jej używa później); B: czekać na PR #134; C: dodać „albo jednak”, nie dodawać samego „no” (zbyt częste jako treść). | A + C jako punkt wyjścia; decyzja o „no” wymaga pomiaru. |
| **Q13** | **Linia a propozycja w jednym dyktowaniu** (np. 1 cięcie i 1 propozycja). Makieta pokazuje je osobno. | A: jedna lista, propozycje po cięciach, ⌃Z wg Q2 działa na cięciach, propozycje przyjmuje tylko ⇧⌃Z; B: propozycje tylko gdy nie ma cięć w tym dyktowaniu. | A. |
| **Q14** | **Zależność od PR #134 i #180.** #180 to pomiar (`do-not-merge`, oparty na #134), #134 to CleanupPrompt v2 i guard. | A: kod produktu niezależny od #134 (nowe typy, guard `main` liczony względem tekstu po cięciu); B: PR #180 przenosi kod prototypu do produktu po zmergowaniu #134. | A (spec zakłada guard z `main`). |

## 📋 Phasing

| Faza | Treść | Warunek wejścia | Wdrażalna osobno |
|---|---|---|---|
| **0. Dokumenty** | ten spec, makieta, odpowiedzi właściciela na Q1–Q14 | — | tak (dokumenty) |
| **1. Rdzeń bez UI** | `RetractionMarkers`, `SelfCorrectionCutter`, reguły, `SelfCorrectionPrompt`, gramatyka w `LLMRuntime`, testy model-free i właściwościowe | **A5b na `main`**, Q9, Q12, Q14 | tak; wyłączone przełącznikiem, bez zmiany zachowania |
| **2. Zbiór i pomiary** | zbiór syntetyczny (B6), pomiar progu (B4), opóźnienia (B5) na 4B/30B/Gemma 4 E4B | faza 1 | tak (testy i noty) |
| **3. Historia** | migracja `v2-cuts`, plakietka, przekreślenie, „Wklej bez cięcia” | faza 1, Q4, Q5, Q6 | tak |
| **4. HUD i klawisze** | HUD B1–B6, `claimKey` w `LintelKit`, cofnięcie w miejscu, VoiceOver | faza 1, Q2, Q3, Q7, Q8; bramki B1, B2 | tak; za przełącznikiem |
| **5. Wydanie** | domyślny stan (Q1), `AGENTS.md`, `BACKWARD_COMPATIBILITY.md`, QA, bramki B1–B8 | fazy 1–4 | — |

## 📋 Implementation Plan

Każdy krok to jedna gałąź `feat/` i jeden PR oparty na `main`, pełna bramka (`swift build`, `swift test`, `swift format lint --strict -r Sources Tests`), teksty `en` i `pl`, `AGENTS.md` i `BACKWARD_COMPATIBILITY.md` w tym samym PR, gdy dochodzi typ, klucz albo format. **Żaden krok kodu nie startuje przed A5b.** Etykiety `risk-*` wg `SDLC.md`; PR zmieniający zachowanie lub wygląd wymaga manualnego QA w uruchomionej aplikacji ze zrzutami (jasny i ciemny) i porównaniem z makietą; `qa-approved` nadaje wyłącznie właściciel.

| Krok | Treść | Zależy od | Test, który go zamyka | Etykiety |
|---|---|---|---|---|
| 0.1 | Ten spec i makieta w `.ai/specs/` (PR docs-only) | — | recenzja | `documentation`, `skip-qa`, `risk-low` |
| 0.2 | Odpowiedzi właściciela na Q1–Q14 wpisane do specu | 0.1 | sekcja pytań zamknięta | `documentation`, `skip-qa`, `risk-low` |
| 1.1 | `RetractionMarkers` + `SelfCorrectionCutter` (bufor hold-back, okno N = 6), czyste, bez modelu | A5b, Q12 | testy tabelaryczne i właściwościowe | `feature`, `risk-low` |
| 1.2 | `LLMRuntime`: parametr gramatyki (addytywny), `LlamaRuntime` z `llama_sampler_init_grammar`; domyślne `unsupported` | 1.1 | test parsowania i gramatyki; `LintelSpeechTests`; TSan dla dzierżawy | `feature`, `risk-medium` |
| 1.3 | `SelfCorrectionPrompt` (wersjonowany, przykłady rozłączne z korpusem), reguły (1) do (5), propozycje D9, powroty (busy, brak modelu, timeout, budżet) | 1.1, 1.2 | testy reguł + `theDeterministicRulesOnlyKeepCancelOrShiftByOne` | `feature`, `risk-medium` |
| 1.4 | Podłączenie do `DictationSession`/`BuiltInFormatter` za przełącznikiem (wyłączony); guard względem tekstu po cięciu; wklejany tekst po cięciu przy odrzuceniu guarda | 1.3 | testy sesji na atrapie; zachowanie przy wyłączonym = jak dziś | `feature`, `risk-medium` |
| 2.1 | Zbiór syntetyczny (markery jako treść, łańcuchy, koniec chunka, granica chunka) i test „0 odwróceń sensu” | 1.3 | B3, B6 | `feature`, `risk-low`, `skip-qa` |
| 2.2 | Pomiar progu „niepewne” i opóźnienia w aplikacji; nota pomiarowa | 1.4, 2.1 | B4, B5 | `documentation`, `risk-low`, `skip-qa` |
| 3.1 | Migracja `v2-cuts`, zapis `cut_count`/`cuts_json` po wklejeniu, test migracji ze schematu v1, `BACKWARD_COMPATIBILITY.md` | 1.4, Q6 | test migracji; Clear/Erase | `feature`, `risk-medium` |
| 3.2 | Historia: przekreślenie, plakietka, „Wklej bez cięcia” (Q4, Q5) | 3.1 | zrzuty QA, PL/EN, jasny i ciemny | `feature`, `risk-medium` |
| 4.1 | **Kontrakt**: `PluginContext.claimKey` w `LintelKit` (addytywnie, default nieaktywny), implementacja w `LintelApp` (jeden PR kontraktowy naraz w kolejce `LintelKit`) | Q2, Q3 | `LintelKitTests` wartości domyślnych; test jednego claimu na klawisz | `feature`, `risk-high` |
| 4.2 | Model linii HUD i stany B1–B6, wygasanie, unieważnianie zdarzeniami (Q7), VoiceOver | 1.4, 4.1 | testy modelu; QA B1, B7 | `feature`, `risk-medium` |
| 4.3 | Cofnięcie w miejscu (Q8), ⌃Z/⇧⌃Z, przycisk, tekst alternatywny (Q5) | 4.2, 3.1 | QA B1, B2 | `feature`, `risk-high` |
| 5.1 | Domyślny stan i przełącznik w Ustawieniach (Q1), `AGENTS.md`, notatka wydania | wszystkie bramki B1–B8 | QA końcowe | `feature`, `risk-medium` |

### Mapa zależności

`A5b → 1.1 → 1.2 → 1.3 → 1.4 → {2.1 → 2.2, 3.1 → 3.2, 4.1 → 4.2 → 4.3} → 5.1`. Odpowiedzi na Q1–Q14 odblokowują kroki oznaczone w kolumnie „Zależy od”.

## 📋 Pokrycie checklisty recenzenta PR #180 (10 punktów)

| Pkt | Wymóg | Gdzie w specu |
|---|---|---|
| 1 | Miejsce przed `Segmenter`, marker blisko granicy chunka | „Przepływ” p. 2 (hold-back N słów), „Edge Cases” |
| 2 | Lista markerów wspólna z `FormatterGuard`, brakujące („albo jednak”, „no”), najwcześniejszy i najdłuższy | „Przepływ” p. 1, Q12 |
| 3 | Prompt (wersjonowany, przykłady sprawdzone względem korpusu), GBNF, zachłanne, okno N = 6, niepoprawna odpowiedź = `none` | „Przepływ” p. 3 |
| 4 | Zmiany `LLMRuntime` (addytywny parametr gramatyki, opcjonalnie prawdopodobieństwa), klucz dzierżawy równy cleanupowi, dzierżawa zajęta = brak cięcia | „Zmiany w `LLMRuntime`”, Q11 |
| 5 | Reguły w kolejności: negacja na wyborze, wyrównanie, wymagana poprawka, kotwica markera z negacją, negacja na końcowym spanie; każda tylko odmawia lub przesuwa o jedno słowo (testy własnościowe) | „Przepływ” p. 4, „Testy” |
| 6 | Łańcuchy lewo→prawo, jedna decyzja na marker, span może pokryć wcześniejszy marker, syntetyczny zbiór łańcuchów przed wydaniem | „Przepływ” p. 5, B6 |
| 7 | Cleanup i guard na tekście po cięciu; przy odrzuceniu wklejany jest tekst po cięciu | „Przepływ” p. 6 |
| 8 | UX: linia z fragmentem, jeden klawisz, cofnięcie w miejscu z pamięci, surowy transkrypt w pamięci (`pasteLastRaw`), nic w logach | „UI/UX”, „Prywatność”; surowy transkrypt zostaje w pamięci jak dziś |
| 9 | Opóźnienie w ścieżce produktu (bez cache prefiksu), zimny start | „Opóźnienie i budżet”, B5 |
| 10 | Większy zbiór syntetyczny (markery jako treść, w tym negujące, łańcuchy, marker na końcu chunka, poprawki bez markera poza zakresem) i bramka „bez utraconej negacji i bez fałszywych cięć na negatywach, które trafiają do modelu” przed włączeniem domyślnym | B3, B6, Q1 |

## 📝 Ryzyka

| Ryzyko | Skutek | Środek |
|---|---|---|
| Model tnie za dużo (1 z 5 negatywów, 9 sond bez wycofania w pomiarze) | utrata treści | cięcie widoczne i odwracalne (D1), propozycja zamiast cięcia dla niepewnych (D5), bramka B6, przełącznik (Q1) |
| Utrata negacji (odwrócenie sensu) | użytkownik wysyła przeciwną treść | reguły (1), (4), (5), test własnościowy B3; luka „negacja jest markerem” opisana wprost |
| Przechwycenie ⌃Z psuje terminal i edytory | utrata funkcji aplikacji docelowej na 6 s | bramka B1, Q3, claim tylko na czas linii |
| Cofnięcie w miejscu zmienia nie ten tekst | uszkodzenie pola użytkownika | unieważnianie zdarzeniami (D3), „zastąp dokładnie albo nic” (B2), Q7, Q8 |
| Opóźnienie ≈ 0,33 s na marker | dyktowanie wolniejsze | budżet i limit na dyktowanie (B5), powrót do tekstu bez cięcia |
| Rozjazd z PR #134 (guard) | niespójne zachowanie | Q14, guard `main` liczony względem tekstu po cięciu |
| Nowa migracja | niezgodność wersji | wyłącznie kolumny z domyślnymi, test migracji, BC sekcja 2 |

Risk label tego PR: `risk-low` (tylko dokumenty i makieta). PR-y kodu: patrz tabela kroków.
