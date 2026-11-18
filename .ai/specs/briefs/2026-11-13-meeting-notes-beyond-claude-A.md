# Notatki ze spotkań lepsze niż Claude Meetings: wygrać tam, gdzie chmura nie może, i zmierzyć to

- Date: 2026-11-13
- Category: feature
- Priority signal: high — Anthropic wydał Claude Meetings w becie 2026-11-12, a notatki Lintela wciąż nie mają potwierdzenia, że obejmują całą godzinę spotkania w wydanej aplikacji
- Risk signal: high — program obejmuje nowe uprawnienie (kalendarz), zmianę decyzji prywatności (przechowywanie audio), nowe tabele w `meetings.sqlite` i nowy kanał wyjścia danych (MCP)
- Routing: `om-spec-writing "Spotkania: Faza 1 (kto mówił), dopiero po przejściu bramek Fazy 0 — brief: .ai/specs/briefs/2026-11-13-meeting-notes-beyond-claude-A.md"`
- Autor: agent A (praca równoległa, bez koordynacji z drugim agentem). Surowy research: `.ai/specs/research/2026-11-13-meeting-notes-beyond-claude-A.md`.

> **Jak czytać.** Proza po polsku, identyfikatory po angielsku. Fakty mają źródło (URL, stan na 2026-11-13) albo odwołanie do kodu lub archiwum pomiarów; wnioski są oznaczone słowem „Wniosek”. Kierunek **nie jest potwierdzony przez właściciela**: bramkę potwierdzenia z `om-brainstorm` zastępuje sekcja Open Questions z wartościami przyjętymi domyślnie.
>
> **To jest brief programu, nie jeden spec.** Zawiera pięć niezależnie wdrażalnych możliwości. Każda faza powinna dostać własny spec i własny PR (Open Questions Q1).
>
> **Stan kodu.** Lokalny checkout (`77905a8`) ma tylko część pluginu. Pełny pipeline jest na `origin/main` (`3356906`, 2026-11-10): 87 plików w `Sources/MeetingsPlugin/`, plugin zarejestrowany, domyślnie wyłączony; targety nazywają się tam `Lintel*`. Brief opisuje stan `origin/main`.

## 📝 TLDR

Claude Meetings (beta od 2026-11-12) to widoczny uczestnik w chmurze, który dołącza do Google Meet w planach Team i Enterprise i zapisuje transkrypt, podsumowanie i opisy ekranu, bez audio. Lintel nagrywa lokalnie dowolną rozmowę bez bota, szyfruje wszystko na Macu i działa po polsku, ale jego notatki są dziś słabsze: domyślny model 4B, brak właścicieli zadań, 15–20% segmentów z pomieszanymi mówcami, a poprawka pierwotnej porażki („godzina spotkania, kilka linijek”) czeka w otwartym PR #63. Proponowany przyszły kierunek: nie ścigać się z Claude na jakość modelu, tylko wygrać w pięciu miejscach, których produkt chmurowy z botem nie pokryje:

1. Działa wszędzie i dla jednej osoby: każda aplikacja, rozmowa na żywo, offline.
2. Wiadomo, kto mówił, więc zadania mają właścicieli.
3. Notatki hybrydowe: to, co użytkownik zapisał w trakcie, steruje tym, co ważne.
4. Każdy punkt da się sprawdzić: cytat, czas i (opcjonalnie) odsłuch.
5. Dane są użytkownika: archiwum z pytaniami lokalnie i otwarty, lokalny dostęp dla jego własnego asystenta.

Pierwszym krokiem jest domknięcie zaległości, dogfood uzgodniony 2026-11-09 i jedno ślepe porównanie z Claude na tym samym transkrypcie, bo dotychczasowe próby poprawy jakości nie wyszły poza szum sędziego (±8 punktów), a założenie „struktura wygra z jakością modelu” nie było jeszcze sprawdzone.

## 📝 Problem Statement

- **Cel użytkownika** (brief `2026-11-09-meeting-notes-dogfood`): po spotkaniu dostać notatkę „kto co mówił, kiedy, co ma zrobić i dlaczego”, tak by „jutro usiadł i wiedział, co robić”.
- **Pierwotna porażka nie jest potwierdzona jako naprawiona w wydanej aplikacji.** Pipeline zweryfikował 91 punktów, a pokazał podsumowanie i 2 pytania; 89 punktów miało rodzaj `SUM`, którego kompozytor nie renderuje, więc wynik pokrywał 2 z 6 dziesięciominutowych odcinków (`.ai/specs/research/2026-11-06-meeting-eval-harness-enterprise.md` na `origin/main`). Poprawka („Kluczowe punkty”) jest w PR #63: otwarty, po rebase i QA (`qa-approved`, `merge-queue`), czeka na merge właściciela; sprawdzenie „Build signed DMG” jest czerwone (stan z `gh pr view 63`, 2026-11-13).
- **Brak wiarygodnego miernika.** Audyt z 2026-11-09 (`Pounce-eval-archive/audit/AUDIT.md`): brak prawdy wzorcowej, brak oceny człowieka, sędzia i „panel” to ta sama klasa modelu, polskie nagranie testowe to podcast bez zadań. Krok 1.12 specu (prawdziwe Zoom/Meet/Teams, echo, Bluetooth, 3 godziny) nie został wykonany; wiersze Meetings w `docs/perf.md` to „not yet measured”.
- **Konkurent z ogromną dystrybucją wszedł na rynek.** Claude Meetings jest wliczony w plany Team/Enterprise na czas bety. Doniesienia z sierpnia 2026 opisują też niewydany lokalny rejestrator w Claude Desktop („Parka”), bez potwierdzenia Anthropic.

Wniosek: „lepsze niż Claude” musi być zdefiniowane mierzalnie (tabela niżej), inaczej będzie to kolejna seria zmian ocenianych na wyczucie.

## 📝 Research (stan na 2026-11-13)

Pełny materiał: `.ai/specs/research/2026-11-13-meeting-notes-beyond-claude-A.md`. Część o Claude sprawdzona niezależnie na trzech stronach Anthropic.

### Claude: co jest potwierdzone, a co nie

| Cecha | Stan | Źródło |
|---|---|---|
| Produkt | „Introducing Claude Meetings, now in beta”, 2026-11-12 | [artykuł Anthropic](https://claude.com/resources/articles/claude-meetings), [release notes](https://support.claude.com/en/articles/12138966-release-notes) |
| Sposób przechwycenia | „add Claude to a Google Meet call as a visible participant”; inne platformy „coming soon” | [help center](https://support.claude.com/en/articles/18325154-use-claude-meetings) |
| Plany | Team (domyślnie włączone) i Enterprise (po włączeniu przez właściciela); organizacje z ZDR, konfiguracją HIPAA i własnymi kluczami szyfrowania są wyłączone z bety | help center |
| Co zapisuje | „a transcript, summary, and screen descriptions, not audio”, na stronie spotkania w claude.ai | artykuł, help center |
| Limit | do ośmiu godzin na rozmowę | help center |
| W trakcie | odpowiada na pytania, tworzy dokumenty, tablice i slajdy; może użyć konektorów uczestnika za jego zgodą | artykuł |
| Archiwum | w zwykłym czacie można pytać o przeszłe spotkania, do których ma się dostęp | help center, artykuł |
| Goście zewnętrzni | dwie strony Anthropic podają sprzeczne ustawienie domyślne dla planu Team | artykuł vs help center |
| Języki (polski), etykiety mówców, retencja, użycie do treningu, cena po becie, szablony, API/MCP danych spotkań | **nie podano na stronach Anthropic** | — |
| „Parka”: lokalny rejestrator w Claude Desktop (dźwięk systemowy + mikrofon, bez bota, zadania do Cowork/Code) | **plotka**: doniesienia z analizy buildów, sierpień 2026; Anthropic nie potwierdził | [Reworked 2026-08-25](https://www.reworked.co/digital-workplace/anthropic-explores-meeting-recorder-that-assigns-tasks-to-claude-agents/), [RuntimeWire 2026-08-19](https://runtimewire.com/article/anthropic-s-project-parka-sits-through-meetings-and-assigns-claude-agents-the-ho) |

Uwaga do sformułowań: stwierdzenie „nie ma w planach Free/Pro/Max” to wniosek z pominięcia (strony wymieniają tylko Team i Enterprise); słowo „bot” nie pada u Anthropic.

Wniosek: Claude Meetings jest dziś silniejszy w trzech rzeczach, których lokalne narzędzie szybko nie dogoni: artefakty tworzone w trakcie rozmowy, odpowiedzi z danych z konektorów i współdzielenie w zespole. Nie obsługuje natomiast osoby indywidualnej, Zooma, Teams, rozmów na żywo ani pracy offline, a przetwarzanie jest w chmurze. Jeśli „Parka” wyjdzie, zniknie przewaga „bez bota”; zostaną lokalne przetwarzanie, polski i otwartość danych.

### Konkurencja (skrót)

| Produkt | Przechwycenie | Przetwarzanie | Mówcy | Polski | Notatki hybrydowe | Pytania do archiwum / MCP |
|---|---|---|---|---|---|---|
| Granola | dźwięk urządzenia, bez bota | chmura; audio kasowane | „Me/Them” na desktopie | tylko mobile, **nie desktop** ([docs](https://docs.granola.ai/help-center/customising-granola/multi-language)) | tak (wzorzec rynku) | tak; MCP od 2026-02-04 |
| ChatGPT Record | aplikacja Mac | chmura | sprzeczne doniesienia | „najlepiej po angielsku” (niezweryfikowane) | nie | — |
| Notion AI Meeting Notes | mikrofon + system na desktopie | chmura | etykiety tylko po angielsku (źródła wtórne) | brak na liście | tak | w Notion |
| Google Meet (Gemini) | natywnie | chmura | tak | **nie** (8 języków) ([pomoc Google](https://support.google.com/meet/answer/14925782)) | nie | Gemini |
| Otter, Fireflies, Fathom, tl;dv | zwykle bot | chmura | tak | deklarowany (źródła wtórne), bez pomiaru | nie | tak |
| Krisp | poziom systemu | chmura (angielski lokalnie) | tak | deklarowany | nie | tak |
| Apple Notatki | nagranie mikrofonu | na urządzeniu | nie | brak | ręczne | nie |
| Anarlog (d. Hyprnote), Meetily, MacWhisper, Talat | dźwięk systemu | na urządzeniu | różnie | zależy od modelu | częściowo | ograniczone |

Nie znaleziono żadnego niezależnego pomiaru jakości polskiego dla któregokolwiek produktu. Wniosek: w polu lokalnym jest tłok nakładek na Whisper/Parakeet, ale nikt nie łączy udokumentowanej jakości polskiego, notatnika hybrydowego i szyfrowanego magazynu.

### Co mówią użytkownicy (głównie źródła wtórne; Reddit był niedostępny dla narzędzia)

1. Błędne lub zlane etykiety mówców, przez co zadania tracą właściciela (najczęstsza skarga na Notion w próbie 35 wątków, [MetaWhisp 2026-10-26](https://metawhisp.com/blog/notion-ai-meeting-notes-review/), blog konkurenta).
2. Notatek nie da się sprawdzić: luźne pomysły stają się zadaniami z nazwiskiem i datą, a audio nie ma (Granola, Claude Meetings).
3. Ciche awarie nagrywania.
4. Boty są natrętne; uczelnie i Teams je blokują.
5. Pozwy o zgodę: *Chamberlain v. Granola* (N.D. Cal., 2026-07-30), *In re Otter.AI Privacy Litigation* (wniosek o oddalenie częściowo odrzucony 2026-08-13); pozwy BIPA o „odciski głosu” przeciw Otter, Fireflies, Teams. Źródła to blogi kancelarii i dostawców, do sprawdzenia w aktach.
6. Krótkie listy języków, płatna historia, zamknięcie danych (zaszyfrowana pamięć podręczna Granoli).

Chwalone: brak bota, notatnik hybrydowy, dostęp do archiwum przez MCP z własnego asystenta.

### Techniki (to, co zmienia plan)

- **Polski ASR na trudnym audio:** w benchmarku PUMA (100 trudnych polskich nagrań, 2026-08) Whisper large-v3 ma 86,40 trafności słów, turbo 85,69, Parakeet TDT v3 79,80 ([arXiv 2608.21853](https://arxiv.org/html/2608.21853)). Czyste FLEURS ukrywa tę różnicę. Własny pomiar Lintela: Parakeet Ultra WER 15,0% na polskim podcaście, 19 razy szybszy od Whispera (RTF 0,0062 wobec 0,120, M4 Max; ten sam dokument harnessu).
- **Nowe modele już w FluidAudio 0.18.x:** Nemotron Unified ASR 0.6B (polski WER 6,01% uśredniony z FLEURS/CV/MLS), Nemotron 3.5 Transcribe Lite (czasy słów co 40 ms i mówcy w jednym przebiegu), `Nemotron3Diarizer` ([wydania FluidAudio](https://github.com/FluidInference/FluidAudio/releases)). Brak opublikowanych liczb dla polskich rozmów; port na Maca miał wczesne awarie.
- **Diaryzacja:** potok offline FluidAudio ma 20,3% DER na AMI SDM z nakładaniem i 24,2% w trybie wyłącznym; opublikowany community-1 to 17,0% ([Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), pomiar 2026-10-30). Pomieszane segmenty to problem ziarnistości: udokumentowana poprawka to przypisanie mówcy do słowa i podział segmentu przy zmianie mówcy. To samo proponuje już spec `2026-11-06-meeting-segment-split`.
- **Model Apple odpada:** polski nie jest językiem Apple Intelligence ([Apple, 2026-11-05](https://support.apple.com/en-us/121115)), a kontekst to około 4 tys. tokenów.
- **Scalanie hierarchiczne wzmacnia halucynacje;** bezpieczniejsze jest scalanie wobec źródła lub cytatów ([Ou i Lapata, ACL 2025](https://arxiv.org/abs/2502.00977)). Pipeline Lintela (MAP z cytatami, REDUCE zwracający identyfikatory, Markdown składany kodem) już tak działa.
- **Notatki hybrydowe:** Granola używa trzech wejść (transkrypt, surowe notatki użytkownika, wydarzenie z kalendarza), tekst użytkownika pozostaje wizualnie odrębny, a przy każdej notatce jest podgląd źródła ([docs Granoli](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)). Metoda wyrównania notatek z transkryptem nie jest opublikowana.
- **Archiwum:** Qwen3-Embedding-0.6B jest słaby w polskim wyszukiwaniu (50,71 na PIRB wobec 61–63 dla modeli polskich); nowa rodzina PolDense (17M–1B) jest do sprawdzenia ([arXiv 2609.12913](https://arxiv.org/abs/2609.12913)). Połączenie sqlite-vec + SQLCipher + GRDB nie ma żadnego potwierdzenia w źródłach.
- **MCP:** serwery Granoli i Fireflies są zdalne; dla lokalnego bezpieczny jest transport stdio (brak portu do ataku z przeglądarki), narzędzia tylko do odczytu ([OWASP MCP cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html)).
- **Ocena:** jednorazowy werdykt sędziego LLM odwraca się w 13,6% porównań, a stabilna większość wymaga około 11 powtórzeń ([arXiv 2606.13685](https://arxiv.org/abs/2606.13685)); panel mniejszych sędziów z różnych rodzin bije jednego dużego ([Verga i in. 2024](https://arxiv.org/abs/2404.18796)). To wyjaśnia szum ±8 punktów. Metryki transkryptu z mówcami (cpWER, tcpWER, DER) liczy [MeetEval](https://github.com/fgnt/meeteval).
- **Prawo (źródła wtórne, to nie porada prawna):** polskie kancelarie zgodnie piszą, że uczestnik nagrywający własną rozmowę nie popełnia czynu z art. 267 KK, ale zostają dobra osobiste i RODO, gdy nagrywa firma. Rozpoznawanie głosu między spotkaniami to dane biometryczne.

## 📝 Gap analysis (kod i specy wobec researchu)

| Obszar | Co mamy (`origin/main`, chyba że zaznaczono) | Czego brakuje | Ocena |
|---|---|---|---|
| Przechwycenie | mikrofon + Core Audio process tap, bez bota, dowolna aplikacja, rozmowa w pokoju, wskazówka w HUD po 20 s ciszy toru systemowego | pomiar na prawdziwych Zoom/Meet/Teams, Bluetooth, echo z głośników (krok 1.12) | **przewaga**, niezmierzona |
| Prywatność | SQLCipher, zaszyfrowany spool, klucz w Pęku kluczy, zero sieci | — | **przewaga** nad wszystkimi produktami chmurowymi |
| Polski ASR | Parakeet Ultra (domyślny), Whisper turbo z językiem `pl`/`en` | pomiar na polskim spotkaniu z zadaniami; słownik; ocena Nemotron Unified; przebieg dokładniejszym silnikiem po spotkaniu | szansa (nikt nie mierzy polskiego), dziś niepotwierdzona |
| Mówcy | diaryzacja offline per tor, „Ja” z toru mikrofonu, ręczna zmiana nazw | podział segmentów (tylko spec), podpowiedzi imion (tylko spec), uczestnicy z kalendarza, limit 90 min (dłuższe spotkanie traci mówców) | **największa luka produktowa**; jedyny powtarzalny zysk w pomiarach to właściciele zadań: 0 bez imion, 3 z 25 po ręcznym podaniu imion, 10 z 24 po dodaniu reguły `ownerFromSpeaker` (PR #63) |
| Notatki | MAP z cytatami, `NotesGuard`, REDUCE po identyfikatorach, Markdown z kodu | „Kluczowe punkty” i `ownerFromSpeaker` czekają w PR #63; 57% napraw strażnika było zbędnych; odwrócenie sensu przechodzi | fundament dobry; wpływ rozmiaru modelu nierozstrzygnięty (niżej) |
| Notatki hybrydowe | Notes workspace (#56): edycja po fakcie, paski autora, historia, komentarze, poprawka skomentowanych bloków | notatki pisane **w trakcie** nie trafiają do `NotesPipeline` | luka; wzorzec najbardziej chwalony na rynku; **brak dozwolonej ścieżki danych** (Faza 2, Q12) |
| Weryfikowalność | `[mm:ss]` przy punkcie, chipy cytatów skaczące do transkryptu | odsłuch (audio kasowane przy `ready`; `keepAudio` tylko jako niezacommitowane zmiany) | pół przewagi; z odsłuchem pełna (Claude i Granola nie mają audio) |
| Szablony | jeden stały (Q8) | — | świadoma decyzja; audyt zaleca szablony per typ spotkania |
| Archiwum | FTS5 z polskim składaniem znaków, tylko słowa kluczowe | pytania w języku naturalnym, zadania między spotkaniami | luka wobec Claude („ask about past meetings”) |
| Integracje | Kopiuj/Zapisz Markdown | automatyczny eksport, MCP, kalendarz | luka; zarazem szansa na „otwarte dane” |
| Na żywo w rozmowie | nic (poza zakresem) | artefakty, odpowiedzi w czacie | **nie gonić** |
| Pomiar | harness (#57), ślad notatek (#59), archiwum wyników | zbiór wzorcowy, ocena człowieka, metryki deterministyczne, panel sędziów | **warunek wstępny** wszystkiego |
| Zewnętrzny LLM | spec `2026-11-10-external-ai-providers` (lokalny, nieśledzony plik; bez kodu) | — | opcjonalna droga do jakości modelu chmurowego za zgodą |

Czego nie powtarzać (pomiary z `Pounce-eval-archive`, 2026-11-06): weryfikator semantyczny i prompt MAP v4 nie dały zysku ponad szum i obniżyły wierność na polskim nagraniu (3 → 1); Qwen3-14B, Bielik 11B v2.3 i Gemma 3 12B wypadły gorzej od Qwen3-4B (46 / 44 / 36 wobec 55), a Qwen3-30B-A3B nieco lepiej (59/65 wobec 55/55, lepsza kompletność, wierność bez poprawy). Te wyniki mają n = 1–2 przy szumie ±8, więc audyt mówi „dane nie rozstrzygają”: to jest „nie udowodniono zysku”, a nie „udowodniono brak”. Ocena „57% napraw strażnika zbędnych” to według audytu sygnał, nie fakt.

## 📝 Rekomendowany kierunek

### Co znaczy „lepsze niż Claude” (mierzalnie)

| Wymiar | Claude Meetings (potwierdzone) | Lintel dziś | Cel programu |
|---|---|---|---|
| Gdzie działa | Google Meet, Team/Enterprise | każda aplikacja, na żywo, offline; niezmierzone | potwierdzone testem na Zoom, Meet, Teams i w pokoju |
| Kto jest na spotkaniu | widoczny uczestnik „Claude” | nikt | bez zmian |
| Dokąd idą dane | chmura Anthropic | nigdzie | bez zmian; każde wyjście jawne i za zgodą |
| Polski i mieszany PL/EN | nie podano | działa, WER 15% na podcaście | zmierzony WER i błąd na terminach angielskich na ≥ 3 prawdziwych polskich spotkaniach |
| Kto mówił | nie podano | „Mówca N”, 15–20% pomieszanych segmentów | < 5% słów z błędnym mówcą; imiona w ≥ 80% spotkań z zaproszeniem w kalendarzu |
| Właściciele zadań | „action items” | 0 bez imion | ≥ 70% zadań z poprawnym właścicielem na zbiorze wzorcowym |
| Pokrycie | nie podano | 2 z 6 dziesięciominutowych odcinków na `main` | 6 z 6; pokrycie punktów wzorcowych ≥ 80% |
| Sprawdzalność | transkrypt, bez audio | cytat + czas | cytat + czas + opcjonalny odsłuch |
| Notatki użytkownika | edycja strony po fakcie | edycja po fakcie | notatki z trakcie sterują wynikiem |
| Pytania do archiwum | tak, w czacie | słowa kluczowe | lokalne odpowiedzi z cytatem; dostęp dla asystenta użytkownika |
| Artefakty w trakcie, konektory, zespół | tak | nie | **świadomie nie** |

Progi liczbowe w kolumnie „Cel” to propozycje autora, nie wyniki badań. Na 3–5 spotkaniach wzorcowych nie da się ich rozstrzygnąć statystycznie; do czasu większego zbioru służą jako kierunek, a decyzje zapadają na porównaniach parami tych samych spotkań. Pięć komórek po stronie Claude to „nie podano”, więc tabela nie mierzy Claude. Jedyny bezpośredni pomiar to ślepe porównanie z kroku 0.3.

### Rozważone kierunki

| Kierunek | Ocena |
|---|---|
| **A. Nie budować dalej; używać Claude Meetings lub Granoli** | Odrzucony dla głównego przypadku: Claude nie obsługuje osoby indywidualnej ani Zooma/Teams/rozmów na żywo, Granola nie ma polskiego na desktopie, oba są chmurowe (spec spotkań: rozmowy klienckie nie mogą wyjść poza Maca). Pozostaje uczciwą opcją dla spotkań zespołowych w Google Meet. **Kryterium zatrzymania z briefu dogfood obowiązuje:** mniej niż 3 wpisy w `failures.md` w 2 tygodnie → wstrzymać inwestycję. |
| **A′. Hybryda: Lintel nagrywa i transkrybuje lokalnie, notatki pisze Claude** (wklejony transkrypt albo Faza 2 specu dostawców) | Najtańsza droga do jakości modelu chmurowego; tekst opuszcza Maca, więc tylko za zgodą i nie dla rozmów klienckich. **Jeśli ślepe porównanie (0.3) wyraźnie wygra Claude, ten wariant wyprzedza Fazy 1–4.** |
| **B. Gonić Claude: uczestnik w rozmowie, artefakty na żywo, konektory** | Odrzucony: wymaga chmury i bota, niszczy jedyne trwałe przewagi. |
| **C. Sama jakość modelu: większy LLM albo dostawca chmurowy** | Niewystarczający sam: pomiary nie pokazały zysku z większych modeli lokalnych, a dostawca zewnętrzny to wyjątek od lokalności. Zostaje jako opcja za zgodą (istniejący spec dostawców), nie jako strategia. |
| **D. Zalecany: pomiar, potem przewagi strukturalne** | Mówcy, notatki hybrydowe, sprawdzalność, archiwum, otwarte dane. Każda z nich podnosi użyteczność bez mocniejszego modelu i każda jest czymś, czego Claude Meetings dziś nie ma albo nie deklaruje. |

### Jak to się układa (kierunek D)

1. **Najpierw domknięcie, dogfood i bramki (Faza 0).** Kolejność z briefu 2026-11-09 zostaje: merge PR #63, sprawdzian pełnej godziny, dwa tygodnie dogfoodu bez zmian w kodzie produktu, kryterium zatrzymania. Dochodzi jedno ślepe porównanie z Claude. Dopiero po bramkach: `keepAudio`, zbiór wzorcowy, metryki. Napięcie: bez zachowanego audio nie powstanie poprawiony transkrypt wzorcowy, bo audio znika przy `ready`; czy `keepAudio` ma wejść przed dogfoodem, rozstrzyga właściciel (Q3).
2. **Kto mówił (Faza 1).** Podział segmentów po słowach (spec istnieje), podpowiedzi imion z rozmowy (spec istnieje), **uczestnicy i tytuł z kalendarza** jako kandydaci na imiona i kontekst dla MAP (EventKit, nowe uprawnienie, opt-in; to odwraca decyzję „bez kalendarza” ze specu imion i „poza zakresem” ze specu spotkań, więc tylko po decyzji Q6 i dopiero gdy podpowiedzi z rozmowy nie przejdą swojej bramki 80%), zdjęcie limitu 90 minut po pomiarze, ocena `Nemotron3Diarizer` i Transcribe Lite w harnessie. Bez odcisków głosu.
3. **Notatki hybrydowe (Faza 2).** Notatnik otwarty w czasie nagrania, każda linia ze znacznikiem czasu. **Uwaga architektoniczna:** dziś dane płyną w jedną stronę (`NoteSource`: Notes czyta z Meetings; `NoteSourceEditing` ma tylko `renameTitle`, `renameSpeaker`, `markSelf`), spec `2026-11-04-notes-workspace` trzyma tekst użytkownika jako nakładki w `notes.sqlite` (N10: zapis zwrotny do `meetings.sqlite` odrzucony, bo Meetings nie mogłoby ręczyć za cytaty) i zabrania zakładania warstwy, gdy spotkanie ma stan `recording`. Faza 2 wymaga więc zmiany jednej z tych decyzji (Q12). Po spotkaniu linie użytkownika są obowiązkowymi nagłówkami: pipeline dobiera okno transkryptu wokół każdej (przyjęte: 60 s przed, 30 s po) i rozwija ją punktami z cytatami; reszta trafia do „Omówiono również”. Tekst użytkownika nie jest przepisywany i zachowuje pasek autora „Ty”. Bez notatek użytkownika wynik jest taki jak dziś.
4. **Notatki, które da się sprawdzić (Faza 3).** Odsłuch fragmentu przy cytacie (z zaszyfrowanego spoolu, gdy `keepAudio` włączone), drugi przebieg dokładniejszym silnikiem po spotkaniu jako opcja („Dokładniejszy transkrypt”), wspólny słownik z dyktowaniem (imiona uczestników, żargon), termin zadania rozwiązywany względem daty spotkania. Zmiany modelu notatek tylko przez harness z Fazy 0.
5. **Zapytaj archiwum i zadania (Faza 4).** Pytanie w języku naturalnym → wyszukiwanie hybrydowe (istniejące FTS5 + wektory przechowywane w zaszyfrowanej bazie, pełne przeszukanie, bez sqlite-vec) → odpowiedź lokalnego LLM z cytatem i czasem, sprawdzana tym samym dopasowaniem cytatu co notatki. Tabela zadań ze stanem (otwarte / zrobione) i widok „Otwarte zadania” ze wszystkich spotkań.
6. **Otwarte dane i mosty (Faza 5).** Automatyczny eksport Markdown do wskazanego folderu (np. skarbiec Obsidian) i lokalny serwer MCP tylko do odczytu, żeby własny asystent użytkownika (Claude Desktop, Claude Code) mógł pytać o spotkania. Wniosek: to zamienia Claude z konkurenta w klienta archiwum Lintela. Domyślnie wyłączone, z jasnym ostrzeżeniem, że tekst oddany asystentowi chmurowemu opuszcza Maca.

### Zasady architektury dla wszystkich faz

- Wszystko w `MeetingsPlugin` (i `NotesPlugin` dla notatnika), bez importów między pluginami; wspólne elementy mowy w `LintelSpeech`; zmiany `LintelKit` wyłącznie addytywne z wartością domyślną.
- `meetings.sqlite` tylko przez addytywne migracje nazwane od funkcji (słowa segmentów, uczestnicy, notatki użytkownika, zadania, wektory), numerowane w kolejności wydania, każda z testem z poprzedniego schematu. Spec podziału segmentów ma jeszcze otwartą decyzję: zmiana `v1-meetings` w miejscu czy nowa migracja.
- Nowe klucze `plugins.meetings.*` (kandydaci: `selfName`, `keepAudio`, `keptAudioDays`, `calendarContext`, `accurateTranscript`, `autoExportFolder`, `mcpEnabled`), wszystkie domyślnie wyłączone, gdy przechwytują lub przechowują więcej.
- Nigdy nie logować tekstu transkryptu ani notatek; nic do `ranking.sqlite`; bez ładowania kodu w czasie działania.
- Nowe uprawnienie tylko jedno: kalendarz (`Permission.calendar`, addytywne), proszone dopiero przy włączeniu funkcji.
- MCP: mały pomocnik stdio uruchamiany przez asystenta, który pyta działającą aplikację; klucz bazy nie opuszcza procesu Lintela. To nowy cel wykonywalny i komunikacja między procesami, więc wymaga własnego ADR.

### Budżety

Budżety ze specu spotkań pozostają (ogon po Stop < 3 s, pamięć w trakcie < 1,5 GB, notatki z godziny ≤ 8 min na słabszym Macu), ale **żaden nie jest zmierzony**; Faza 0 wypełnia `docs/perf.md`. Nowe cele do ustalenia po pomiarze: notatnik hybrydowy bez dodatkowego obciążenia w trakcie nagrania; drugi przebieg Whisperem w tle po spotkaniu (z pomiaru: około 7 min na godzinę audio na M4 Max); odpowiedź z archiwum z pierwszym tokenem w kilka sekund na tym samym modelu co notatki.

## 📋 Phasing

Każda faza to osobny spec, gałąź `feat/` i PR (lub seria PR-ów); każda niezależnie wdrażalna i wyłączalna.

- **Faza 0 — Domknięcie, dogfood, bramki, potem pomiar.**
- **Faza 1 — Kto mówił.**
- **Faza 2 — Notatki hybrydowe.**
- **Faza 3 — Sprawdzalność i dokładność.**
- **Faza 4 — Zapytaj archiwum i zadania.**
- **Faza 5 — Otwarte dane i mosty.**

Zależności: Faza 1 i każda zmiana jakości wymagają Fazy 0; odsłuch (3.1) wymaga `keepAudio` (0.6); wspólny słownik (3.3) wymaga zatwierdzenia briefu dyktowania; tabela zadań (4.1) korzysta z właścicieli z Fazy 1 i terminów z 3.4. Poza tym Fazy 2, 4 i 5 są od siebie niezależne.

## 📋 Implementation Plan

Wspólne: bramka `swift build` → `swift test` → `swift format lint --strict -r Sources Tests`; testy z prawdziwymi modelami wyłączone domyślnie; PR-y dotykające chronionych powierzchni są `risk-high`.

### Faza 0 — Domknięcie, dogfood, bramki, potem pomiar

Kroki 0.1–0.4 nie zmieniają kodu produktu (zgodnie z briefem 2026-11-09); spec Fazy 1 powstaje dopiero po bramce 0.4.

- **0.1 Merge PR #63** (decyzja właściciela; wyjaśnić czerwone „Build signed DMG”). *Sprawdzenie ręczne:* notatki z prawdziwego godzinnego spotkania pokrywają 6 z 6 odcinków w zbudowanej aplikacji. To blokuje resztę.
- **0.2 Dogfood, dwa tygodnie** według briefu `2026-11-09`: `failures.md`, pary oryginał/edycja.
- **0.3 Ślepe porównanie z Claude (jeden wieczór).** Jeden prawdziwy polski godzinny transkrypt z buildu po 0.1 (spotkanie, na które jest zgoda): notatki Lintela (Qwen3-4B i Qwen3-30B-A3B) oraz notatki Claude z wklejonego transkryptu; właściciel szereguje je na ślepo i zapisuje, czego brakuje w każdej. *Wynik:* jeśli Claude wygrywa wyraźnie także z 30B, kierunek A′ (Faza 2 specu dostawców) wyprzedza Fazy 1–4.
- **0.4 Bramka.** Mniej niż 3 wpisy w `failures.md` → wstrzymać inwestycję (kryterium z briefu dogfood). Inaczej: przegląd wzorców błędów i decyzja, czy Faza 1 jest nadal pierwsza.
- **0.5 Krok 1.12 specu spotkań** (ręczne QA, nie test jednostkowy): prawdziwe Zoom, Meet, Teams, rozmowa w pokoju, słuchawki Bluetooth, głośniki, 3 godziny. *Wynik:* wypełnione wiersze w `docs/perf.md`, lista awarii.
- **0.6 `keepAudio` jako opcja** (po decyzji Q3). Dokończyć zmiany z worktree `Pounce-keepaudio`: klucz domyślnie false, `AudioState.kept`, wygasanie po N dniach, „Usuń zachowane nagrania” w Prywatności. *Test:* migracja stanu, wygasanie, usuwanie; domyślnie zachowanie bez zmian.
- **0.7 Limit 90 minut.** Pomiar diaryzacji 2 h i 3 h istniejącym `DiarizationBenchmarks` (czas, pamięć); podniesienie `DiarizationBudget` albo diaryzacja w oknach ze scaleniem klastrów. Limit jest dziś zgadnięty i odbiera mówców długim spotkaniom. *Bramka:* pamięć w budżecie.
- **0.8 Zbiór wzorcowy.** Z nagrań dogfood z zachowanym audio: 3–5 spotkań na początek (docelowo 8–12), dla każdego poprawiony transkrypt z mówcami, 10–25 punktów kluczowych, decyzje, zadania z właścicielem i terminem. Poza repozytorium, zaszyfrowane. Zależy od Q4 i Q10.
- **0.9 Metryki deterministyczne w harnessie.** WER z jednym normalizatorem polskim, błąd na liście terminów angielskich, udział słów z błędnym mówcą, DER/tcpWER przez MeetEval. *Test:* metryki na syntetycznych parach.
- **0.10 Metryki notatek na poziomie twierdzeń.** Pokrycie punktów wzorcowych, wierność (twierdzenie wobec cytowanego fragmentu), F1 zadań na trzech poziomach (zadanie / + właściciel / + termin); panel 2–3 sędziów z różnych rodzin, ≥ 5 powtórzeń dla spornych decyzji, porównanie parami na tych samych spotkaniach. Sędziowie chmurowi tylko na nagraniach, na które jest zgoda; bez niej panel lokalny.
- **0.11 Linia bazowa.** Jeden przebieg całości na `main`; tabela „Cel programu” dostaje liczby zmierzone zamiast szacowanych.

### Faza 1 — Kto mówił

- **1.1 Podział segmentów** według specu `2026-11-06-meeting-segment-split` (czasy słów, przypisanie mówcy do słowa, minimalna długość serii; decyzja o kolumnie `words_json`). *Bramka:* udział słów z błędnym mówcą spada na zbiorze wzorcowym.
- **1.2 Imię nagrywającego i `ownerFromSpeaker`** (z PR #63, jeśli nie weszły w 0.1).
- **1.3 Podpowiedzi imion z rozmowy** według specu `2026-11-06-meeting-speaker-names`, Faza 2 (z jego bramką 80% trafności).
- **1.4 Kontrakt i uprawnienie kalendarza** (tylko po decyzji Q6 i gdy 1.3 nie przejdzie bramki). `Permission.calendar` i port odczytu wydarzeń w `LintelKit` (addytywnie), implementacja EventKit w `LintelApp`, tekst uprawnienia w `InfoPlist.xcstrings`. *Test:* domyślny port bez wydarzeń. *QA ręczne:* brak monitu systemowego bez włączenia funkcji (TCC nie da się sprawdzić testem jednostkowym).
- **1.5 Kontekst z kalendarza.** Przy starcie nagrania dopasowanie bieżącego wydarzenia: tytuł spotkania, lista uczestników jako kandydaci na imiona (potwierdzane przez użytkownika, nigdy przypisywane automatycznie) i jako wejście MAP. Addytywna migracja uczestników. *Test:* brak wydarzenia, dwa nakładające się, wydarzenie całodniowe.
- **1.6 Ocena alternatyw w harnessie** (bez zmiany domyślnej): `stepRatio 0.1`, `Nemotron3Diarizer`, Transcribe Lite. Wynik w ADR; zmiana domyślnej tylko przy zysku ponad szum.

### Faza 2 — Notatki hybrydowe

- **2.1 Notatnik spotkania i ścieżka danych** (po decyzji Q12). Wariant zalecany: notatnik należy do `MeetingsPlugin` (linie z czasem w `meetings.sqlite`, addytywna migracja), otwierany z HUD, a Notes widzi go jako warstwę tylko do odczytu przez istniejący `NoteSource`; Meetings dalej ręczy za cytaty, bo tekst użytkownika jest osobną warstwą, a nie edycją notatek AI. Wariant drugi: nowy addytywny port w `LintelKit`, którym Notes przekazuje Meetings linie użytkownika z czasem. Oba zmieniają N10 albo regułę „bez warstwy w stanie `recording`” ze specu Notes workspace. *Test:* zapis w trakcie, awaria w trakcie nagrania nie gubi notatek, brak importu między pluginami (test grafu).
- **2.2 Kotwice w `NotesPipeline`.** Linie użytkownika jako wymagane nagłówki; okno transkryptu wokół czasu linii; punkty z cytatami pod nagłówkiem; sekcja „Omówiono również”. *Test:* każda linia użytkownika występuje w wyniku dosłownie; brak notatek daje dzisiejszy wynik; `NotesGuard` bez zmian dla punktów modelu.
- **2.3 Prezentacja.** Paski autora „Ty” / „AI”, regeneracja po edycji notatek użytkownika, eksport Markdown z oznaczeniem autora. *Test:* golden eksportu, zrzuty.
- **2.4 Pomiar.** Na zbiorze wzorcowym: pokrycie punktów, które użytkownik sam zanotował, wobec wariantu bez kotwic.

### Faza 3 — Sprawdzalność i dokładność

- **3.1 Odsłuch przy cytacie.** Odtworzenie ±10 s z zaszyfrowanego spoolu przez `SpoolReader`, tylko w pamięci; niedostępne, gdy audio skasowane. *Test:* brak pliku jawnego na dysku; spotkanie bez audio.
- **3.2 Dokładniejszy transkrypt po spotkaniu** (opcja): drugi przebieg Whisperem ze spoolu w tle, zastąpienie tekstu segmentów z zachowaniem czasów i mówców. *Bramka:* WER lepszy na polskich spotkaniach zbioru wzorcowego; inaczej funkcja nie wchodzi.
- **3.3 Wspólny słownik.** Słownik użytkownika z dyktowania (brief `2026-11-13-context-aware-dictation-A`) + imiona uczestników jako kandydaci do poprawy pisowni w transkrypcie; komponent w `LintelSpeech`. *Bramka:* fałszywe podmiany poniżej progu z tamtego briefu.
- **3.4 Terminy zadań.** Data spotkania w MAP; „do piątku” rozwiązywane w kodzie do daty, tylko gdy fraza jest w cytacie. *Test:* tabela fraz PL/EN.
- **3.5 Modele notatek.** Kandydaci (Gemma 4 12B, Bielik 11B v3.0, Gemma 4 26B-A4B) wyłącznie przez harness; nowy wpis w `LLMModelCatalog` tylko przy zysku ponad szum i po sprawdzeniu licencji i warunków pobierania (repozytorium Bielika jest bramkowane).

### Faza 4 — Zapytaj archiwum i zadania

- **4.1 Tabela zadań** (addytywna migracja: zadanie, właściciel, termin, stan, spotkanie, cytat) wypełniana z notatek; widok „Otwarte zadania”, oznaczanie jako zrobione. *Test:* regeneracja notatek nie gubi stanu.
- **4.2 Wektory.** Wybór modelu osadzeń po teście na polskich pytaniach (PolDense małe, Qwen3-Embedding-0.6B, bge-m3); wektory jako bloby w `meetings.sqlite` (addytywna migracja), pełne przeszukanie. *Bramka:* czas zapytania na 1000 spotkań; licencja modelu.
- **4.3 Wyszukiwanie hybrydowe.** FTS5 + wektory, łączenie przez reciprocal rank fusion. *Test:* zestaw pytań z oczekiwanym spotkaniem.
- **4.4 Odpowiedź z cytatem.** Lokalny LLM na wybranych fragmentach; każda teza z cytatem i czasem, sprawdzana dopasowaniem; bez cytatu odpowiedź „nie znalazłem”. *Test:* pytanie bez pokrycia w archiwum.

### Faza 5 — Otwarte dane i mosty

- **5.1 Automatyczny eksport Markdown** do wskazanego folderu po `ready` i po regeneracji (zmienia decyzję „poza zakresem” ze specu spotkań). *Test:* folder niedostępny, kolizja nazw, lokalizacje chronione przez TCC.
- **5.2 Lokalny MCP (stdio, tylko odczyt)**, poprzedzony ADR (nowy cel wykonywalny, IPC z aplikacją, model zagrożeń). Narzędzia: lista spotkań, wyszukiwanie, notatki, transkrypt z limitem rozmiaru. Domyślnie wyłączone, widoczny wskaźnik użycia, tekst zgody, opcjonalne potwierdzenie w aplikacji przy pierwszym zapytaniu w sesji. Pomocnik stdio nie potrafi uwierzytelnić procesu, który go uruchomił, więc listy dozwolonych klientów nie da się wyegzekwować i brief jej nie obiecuje. Możliwość wyłączenia MCP dla spotkań oznaczonych jako poufne. *Test:* brak dostępu przy wyłączonym; pomocnik bez działającej aplikacji nic nie zwraca; limit rozmiaru; spotkanie poufne niewidoczne.
- **5.3 Dostawca zewnętrzny dla notatek:** Faza 2 specu `2026-11-10-external-ai-providers`, bez zmian w tym briefie.

## 📝 Ryzyka

- **Budowanie funkcji na niezmierzonej podstawie (wysokie).** Dotąd żadna zmiana jakości nie wyszła poza szum. Mitygacja: Faza 0 jest bramką; każda zmiana jakości ma bramkę liczbową na zbiorze wzorcowym.
- **Przechowywanie audio odwraca decyzję Q7 (wysokie, prywatność).** Mitygacja: wyłączone domyślnie, krótki termin, szyfrowanie jak spool, jedno miejsce do skasowania; decyzja właściciela (Q3).
- **Kalendarz to nowe uprawnienie i dane osób trzecich (średnie).** Mitygacja: opt-in, odczyt tylko bieżącego wydarzenia, imiona jako podpowiedzi do potwierdzenia, uczestnicy tylko w zaszyfrowanej bazie.
- **MCP otwiera wyjście danych i wstrzyknięcie poleceń (wysokie).** Tekst transkryptu oddany asystentowi jest dla niego niezaufanym wejściem, a asystent chmurowy wynosi go z Maca. To stoi w napięciu z powodem odrzucenia kierunku A (rozmowy klienckie nie mogą wyjść poza Maca), dlatego funkcja jest wyłączona domyślnie i ma wykluczenie spotkań poufnych. Mitygacja: stdio, tylko odczyt, wyłączone domyślnie, zgoda z jasnym tekstem, limit rozmiaru, wskaźnik; zmiana tekstów prywatności na stronie.
- **Zgoda uczestników (średnie, prawne).** „Bez bota” nie zdejmuje obowiązku poinformowania (pozew przeciw Granoli dotyczy właśnie niewidocznego nagrywania). Mitygacja: istniejące przypomnienie o zgodzie zostaje włączone domyślnie; dodać „Kopiuj komunikat o nagrywaniu”.
- **„Parka” (średnie, rynek).** Lokalny rejestrator w Claude Desktop zniósłby przewagę „bez bota”. Mitygacja: przewagi, które zostają (lokalne przetwarzanie, polski, sprawdzalność, otwarte dane), są w Fazach 1–5; MCP czyni Lintela użytecznym także dla użytkowników Claude.
- **Zakres (wysokie).** Sześć faz to miesiące pracy. Mitygacja: fazy niezależne, każda z własnym specem i kryterium zatrzymania; po Fazie 1 przegląd, czy użytkownik faktycznie nagrywa.
- **Modele i licencje (niskie–średnie).** Nowe modele mowy i diaryzacji w FluidAudio są świeże (wczesne awarie), Bielik jest bramkowany, licencje części modeli osadzeń niezweryfikowane. Mitygacja: wszystko przez harness i sprawdzenie licencji przed wpisem do katalogu.
- **Rollback:** każda funkcja ma wyłącznik; migracje są addytywne, więc starsza wersja czyta bazę; eksport i MCP nie zmieniają danych.

## Non-goals

- Uczestnik lub bot dołączający do rozmowy; artefakty i odpowiedzi w trakcie spotkania.
- Konta, synchronizacja, współdzielenie w zespole, maile z podsumowaniem.
- Automatyczny start nagrywania bez działania użytkownika.
- Odciski głosu i rozpoznawanie osób między spotkaniami.
- Własne prompty użytkownika; wiele szablonów w tym programie (Q5).
- Ponowne próby z weryfikatorem semantycznym i promptem v4 przed powstaniem zbioru wzorcowego.
- Transkrypt na żywo w oknie, import plików audio i wideo (bez zmian wobec specu spotkań).

## ❓ Open Questions (do właściciela; w nawiasie wartość przyjęta w briefie)

- **Q1. Podział.** Brief łączy pięć niezależnych możliwości. Osobny spec na fazę? *(Przyjęto: tak; Faza 0 to proces i drobne PR-y bez specu, pierwszy spec to Faza 1 po bramce 0.4.)*
- **Q2. Definicja „lepsze niż Claude”.** Czy tabela wymiarów i progów oddaje intencję, czy chodziło o jakość samych notatek w porównaniu ślepym z Claude na tym samym transkrypcie? *(Przyjęto: oba; tabela opisuje przewagi strukturalne, a ślepe porównanie z kroku 0.3 mierzy jakość samych notatek.)*
- **Q3. Przechowywanie audio.** Zgoda na `keepAudio` jako opcję (zmiana decyzji Q7 specu spotkań)? Na ile dni? Czy ma wejść **przed** dogfoodem, żeby nagrania dogfoodu mogły zasilić zbiór wzorcowy (to zmiana kodu produktu, której brief dogfood nie przewidywał)? *(Bez wartości przyjętej: brief zakłada kolejność z briefu dogfood, czyli `keepAudio` po bramce 0.4, wyłączone domyślnie, 14 dni.)* ⚠ Decyzja prywatności właściciela.
- **Q4. Zbiór wzorcowy.** Brief dogfood odrzucił ręczny zbiór 3–5 spotkań jako zbyt kosztowny na start. Czy teraz, wobec Claude Meetings, właściciel poświęci 1–2 dni na 3–5 spotkań, czy zbiór ma powstać tylko z par oryginał/edycja? *(Przyjęto: z par dogfood plus poprawiony transkrypt dla 3 spotkań.)*
- **Q5. Szablony.** Notatki hybrydowe częściowo zastępują szablony. Czy dodać 3–4 stałe szablony (ogólne, 1:1, klient, stand-up), co zmienia decyzję Q8? *(Przyjęto: nie w tym programie.)*
- **Q6. Kalendarz.** Spec imion mówców zdecydował „bez kalendarza” (kalendarz dopiero, gdy podpowiedzi z rozmowy nie przejdą bramki 80%), a spec spotkań ma kalendarz poza zakresem. Czy odwrócić tę decyzję wcześniej, bo Granola i inni biorą imiona właśnie z zaproszenia? *(Przyjęto: nie odwracać z góry; kroki 1.4–1.5 tylko po niezaliczonej bramce 1.3 albo wyraźnej decyzji; wtedy opt-in, tylko EventKit.)* ⚠
- **Q7. MCP.** Czy lokalny dostęp dla asystenta chmurowego jest zgodny z obietnicą „domyślnie nic nie opuszcza Maca”? *(Przyjęto: tak, jako jawny wyjątek jak w specu dostawców; wymaga tej samej zmiany tekstów prywatności.)* ⚠ Decyzja właściciela.
- **Q8. Automatyczny eksport do folderu.** Notatki w jawnym Markdownie poza zaszyfrowaną bazą. *(Przyjęto: tak, opt-in, z ostrzeżeniem.)*
- **Q9. Kolejność po Fazie 1.** Notatki hybrydowe przed archiwum? *(Przyjęto: tak, bo to najczęściej chwalony wzorzec i nie wymaga nowego modelu.)*
- **Q10. Nagrania do oceny.** Czy właściciel ma polskie spotkania z zadaniami, na których nagranie i użycie sędziów chmurowych (oraz ślepe porównanie z Claude w 0.3) uczestnicy się zgodzą? *(Przyjęto: nie zakładać zgody; 0.3 na jednym spotkaniu wewnętrznym, panel sędziów lokalny, sędziowie chmurowi dopiero po zgodzie.)*
- **Q11. Spec dostawców zewnętrznych** jest nieśledzonym plikiem lokalnym i nazywa `NotesPipeline` „jeszcze niezbudowanym”, co jest nieaktualne. Zaktualizować go i włączyć do planu, czy odłożyć?
- **Q12. Ścieżka danych notatek hybrydowych.** Notatnik w trakcie spotkania jako własność `MeetingsPlugin` (warstwa tylko do odczytu w Notes), czy nowy port `LintelKit` z Notes do Meetings? Oba warianty zmieniają decyzję N10 albo regułę „bez warstwy podczas `recording`” ze specu `2026-11-04-notes-workspace`. *(Przyjęto: własność `MeetingsPlugin`; do potwierdzenia przed specem Fazy 2.)* ⚠
- **Q13. Jeśli Claude wygra ślepe porównanie (0.3).** Czy wtedy pierwszeństwo dostaje droga „lokalny transkrypt, notatki przez dostawcę za zgodą” (kierunek A′), a przewagi strukturalne idą po niej? *(Przyjęto: tak dla spotkań niepoufnych; Fazy 1–2 zostają, bo poprawiają też wejście dla modelu chmurowego.)*
