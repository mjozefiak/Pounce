# Nazwy mówców w notatkach ze spotkań

Powiązany spec: `2026-11-06-meeting-speaker-quality.md` (jakość etykiet; ma być zrobiony **pierwszy**). Ten spec opisuje wyłącznie *nazwy*. Nazwy w kodzie i kontraktach: produkt to Lintel (`LintelKit`, klucze `plugins.meetings.*`); w tekście bywa nazywany Pounce, bo tak nazywa się repozytorium.

## 📝 TLDR
Osoba, która nagrywa spotkanie, dostaje dziś notatki, w których zadania i decyzje nie mają właściciela: na nagraniu ovn-kubernetes 0 z 12–18 zadań miało osobę, a etykiety to „Mówca N”. Proponowane przyszłe zachowanie: Lintel podpowiada imiona mówców z samej rozmowy (samoprezentacja, zwrot po imieniu), użytkownik je potwierdza jednym kliknięciem, a imię właściciela nagrania pochodzi z jednego pola w Ustawieniach. Notatki używają imienia dopiero po potwierdzeniu. Powód: „kto komu co zlecił” jest najcenniejszą informacją, której notatkom dziś brakuje.

## 📝 Problem Statement
- Zmierzone (archiwum `Pounce-eval-archive/PLAN-meeting-notes-quality.md`): owners 0 z 12–18 na ovn we wszystkich ocenach sędziów; zadanie w pierwszej osobie („I’ll do it”) nie dostaje osoby, bo `NotesGuard.checkedPerson` przyjmuje osobę tylko, gdy cytat jest w pierwszej osobie **i** etykieta mówcy jest prawdziwym imieniem (`isGenericLabel` odrzuca „Mówca N”, „Ja”, „Inni”).
- Użytkownik wskazał to jako problem produktowy: z „Mówca 1 / Mówca 2” nie wiadomo, kto komu co zlecił.
- Nie wiemy jeszcze, jak często imię pada w rozmowie w takiej formie, żeby dało się je wykryć (to pierwszy pomiar w kroku 2.1).

## 📝 Proposed Solution
Trzy małe elementy, każdy działa bez następnego:
1. **Imię właściciela nagrania.** Ustawienie `plugins.meetings.selfName`, wstępnie z imienia konta macOS. Mówca z `is_self` jest w tekście dla modelu i w notatkach podpisany tym imieniem (zamiast „Ja”), więc „I’ll do it” daje zadanie z jego imieniem.
2. **Podpowiedzi imion z transkryptu.** Czysta logika `SpeakerNameSuggester` wyszukuje w wypowiedziach samoprezentacje („tu Marek”, „I’m Anna”, „mówi Marek”) i przypisuje imię mówcy tej wypowiedzi. Zwrot po imieniu („Marek, zrobisz to?”) jest tylko słabszą wskazówką: wskazuje mówcę następnej wypowiedzi, więc potrzebuje potwierdzenia.
3. **Potwierdzenie w oknie spotkania.** W liście „Mówcy” obok pola nazwy pojawia się podpowiedź „Marek?” z akcjami Przyjmij / Odrzuć. Przyjęcie to dzisiejsze `renameSpeaker`. Do potwierdzenia notatki używają „Mówca N”.

Rozważone i odrzucone:
- *Nadawanie imion automatycznie bez potwierdzenia* — pomyłka przypisuje zadanie niewłaściwej osobie (decyzja użytkownika).
- *Kalendarz (EventKit)* — nowe uprawnienie i wyjście poza zakres specu notatek („poza zakresem” w `2026-11-03-meeting-notes.md`); osobny spec, jeśli podpowiedzi z rozmowy okażą się za rzadkie.
- *Rozpoznawanie głosu między spotkaniami (profile głosowe)* — dane biometryczne, poza zakresem.

## 📝 Research (rynek)
Pełne wyniki z oznaczeniem siły dowodu: `Pounce-eval-archive/research-speaker-names.md` (9 produktów; strony pomocy Otter i Read.ai niedostępne, część wniosków ze snippetów).
- **Pole „Twoje imię” jest zgodne z rynkiem:** Granola przypisuje „Me” z kanału mikrofonu, Fathom (iOS) ma opcjonalny voiceprint tylko właściciela konta [dokumentacja]. U nas to samo wynika z toru mikrofonu bez biometrii.
- **Żaden z badanych produktów nie dokumentuje wnioskowania imion z samoprezentacji;** źródła to lista uczestników platformy lub kalendarz, voiceprint, ręczne wpisanie. Naszą sugestię z transkryptu wspierają tylko prace naukowe (imię przy jawnym dowodzie, inaczej „Unknown”) [abstrakty]. Zasada „sugestia plus potwierdzenie” jest z tym zgodna.
- **Jeden mikrofon w sali zawodzi u wszystkich** (Granola, Fathom, Zoom, Teams przyznają to); Fireflies i Read.ai dają korektę w zakresie „ta linia” albo „wszyscy Speaker X”. Spec 2026-11-03 trzyma ręczne scalanie i dzielenie mówców poza zakresem; ten spec tego nie zmienia, ale zapisuje, że to najczęstsza luka konkurentów (decyzja do osobnego specu).
- **Po zmianie imienia notatki trzeba wygenerować ponownie** (Fireflies: „Regenerate”); to nasz `stale`.
- **Voiceprinty niosą ryzyko prawne** (zarzuty BIPA wobec Otter, Fireflies, Teams; doniesienia prasowe, strona trzecia). Lokalne przetwarzanie bez profili głosowych je omija; nadal poza zakresem.
- **Luki:** brak oficjalnego opisu właściciela action items i rozwiązywania „I’ll do it” u konkurentów; brak liczb dokładności atrybucji imion; brak źródeł o polskim wołaczu.

## 📝 Architecture
- **Istniejące, używane bez zmian:** `MeetingWindowModel.renameSpeaker` / `markSelf`, `MeetingsStore.renameSpeaker` (po zmianie nazwy `notes_status = stale`, `NotesService` pisze notatki ponownie, `storedStale`), `NotesUtterance.make(from:)` i `TranscriptChunker` (etykieta mówcy z `document.speakers` trafia do linii `[mm:ss] Imię: tekst`), `NotesGuard.checkedPerson`.
- **Nowe:**
  - `MeetingsSettings.selfName` (`plugins.meetings.selfName`, additive, kontrakt kluczy ustawień jest chroniony).
  - `SpeakerNameSuggester` (czysta logika w `Sources/MeetingsPlugin/Diarization/`, bez I/O): wejście `[MeetingDocument.Segment]` i lista mówców, wyjście `[SpeakerNameSuggestion]` (`speakerID`, `name`, `evidence` = `introduction` / `addressed`, `segmentIDs`). Nie zapisuje niczego; liczone przy otwarciu okna spotkania.
  - Zmiana w `NotesUtterance.make(from:selfName:)` (`Notes/TranscriptChunker.swift`, parametr `selfName: String?` z domyślnym `nil`, przekazywany z `NotesService.process`, który ma `deps.settings`): etykieta mówcy `is_self` to `selfName`, gdy jest niepusty, spotkanie ma `speaker_mode = diarized` i etykieta mówcy to nadal domyślne `SpeakerLabels.me` („Ja”, czyli użytkownik jej nie zmienił). `TranscriptChunker` sam nie widzi mówców, więc nie zmienia się. Imię przechodzi przez to samo `sanitized` co etykiety (usuwa `|` i znaczniki promptu, bo pole ustawień to wolny tekst, czyli droga prompt injection).
- **Brak migracji bazy:** podpowiedzi nie są przechowywane (liczone na żądanie), a potwierdzone imię trafia do istniejącego `meeting_speaker.label`.
- **Granica:** logika w `MeetingsPlugin`, bez nowych zależności i bez zmian w `PounceKit`.

## 📝 Data Model
Bez zmian schematu. Jedyne nowe pole to ustawienie `plugins.meetings.selfName` (tekst, **domyślnie puste**, nic nie jest zapisywane po cichu). Pole w Ustawieniach pokazuje imię z konta macOS (`NSFullUserName()`, pierwszy wyraz) jako przycisk „Użyj: Marek”; dopiero kliknięcie zapisuje wartość. Do czasu zapisu `selfName` jest puste i zachowanie notatek się nie zmienia. Wartość pasująca do `isGenericLabel` („On”, „Ona”, „My”…) jest odrzucana przy zapisie z komunikatem, bo `NotesGuard.checkedPerson` i tak nie przyjmie jej jako osoby. Imiona mówców to dane o osobach: zostają tylko w zaszyfrowanym `meeting_speaker.label` i w tekście dla lokalnego modelu.

## 📝 UI/UX
- Ustawienia → Spotkania: pole „Twoje imię” z podpowiedzią z konta macOS i opisem „Używane w notatkach, żeby zadania miały właściciela.”.
- Okno spotkania, lista „Mówcy”: pod polem nazwy podpowiedź („Marek? — usłyszane w 12:03”) z Przyjmij / Odrzuć; kliknięcie czasu przewija transkrypt do dowodu. Dostępność: etykiety VoiceOver na akcjach, fokus klawiaturą; podpowiedź nie zmienia niczego bez akcji.
- Notatki z `stale` po przyjęciu imienia (istniejące zachowanie), z podpowiedzią „zmieni nazwy też w notatkach po regeneracji”.

## 📝 Edge Cases & Failure Scenarios
- **Polska fleksja:** „Marek” (mianownik) w samoprezentacji, „Marku” (wołacz) w zwrocie. Samoprezentacje stosujemy tylko w mianowniku po wzorcach; zwrot po imieniu dopasowujemy do znanych imion po rdzeniu i zawsze jako słabszą wskazówkę. Pomyłka kończy się odrzuceniem podpowiedzi, nie błędnym zadaniem (Q3).
- **Dwie osoby o tym samym imieniu:** podpowiedź nie zmienia etykiety, jeśli imię jest już przypisane innemu mówcy tego spotkania; pokazujemy konflikt, nie zgadujemy.
- **Imię w cytacie ≠ mówca:** „Marek powiedział, że…” to nie samoprezentacja; wzorce wymagają pierwszej osoby.
- **Obce imiona i nazwy produktów** (np. „Kubernetes”, „Docker” z wielkiej litery): wzorce wymagają frazy samoprezentacji, nie samej wielkiej litery.
- **Brak diaryzacji (`speaker_mode = channels` lub `none`):** podpowiedzi i `selfName` wyłączone. Tor „Ja” to cały mikrofon (może w nim mówić kilka osób w pokoju), a `markSelf` jest tam zablokowany (`MeetingsStore+Diarization.swift`), więc podstawienie imienia byłoby przypisaniem niepotwierdzonym przez nikogo (Q3).
- **Błędna diaryzacja (zbyt wielu mówców, scalone osoby):** imię trafia do klastra, nie osoby; patrz spec jakości etykiet. Przed nim żadnych automatycznych działań.
- **Wyciek:** `NotesTrace` nie zawiera imion (zasada: żaden tekst); test to sprawdza.

## 📝 Risks & Impact Review
- Najpoważniejsze ryzyko to zadanie przypisane złej osobie przez zły klaster diaryzacji; stąd potwierdzenie przez użytkownika i kolejność „najpierw jakość etykiet”.
- Nowy klucz ustawień jest nieodwracalnym kontraktem po v0.1 (`BACKWARD_COMPATIBILITY.md`): nazwa `plugins.meetings.selfName` musi być ostateczna przed implementacją.
- Wzorce samoprezentacji są heurystyką językową; dokładność nieznana do pomiaru w kroku 2.1. To decyzja produktowa (czy wystarczy rzadka podpowiedź), nie naruszenie reguł repozytorium.

## 📋 Phasing
1. **Faza 1 — „Twoje imię”** (niezależna od specu jakości, wdrażalna sama): ustawienie, podpis mówcy `is_self` w notatkach.
2. **Faza 2 — podpowiedzi z potwierdzeniem** (jedna dostarczalna całość: `SpeakerNameSuggester` plus UI w oknie spotkania). Zaczyna się po kroku 1.4 specu jakości etykiet (raport z pomiaru), cokolwiek ten raport zdecyduje. Bramka pomiarowa na początku: krok 2.1 mierzy, ile podpowiedzi daje się wykryć i ile jest poprawnych; jeśli podpowiedzi są rzadsze niż 1 na 3 spotkania lub trafność poniżej 80% (próg ustalony przed pomiarem), faza kończy się tu, bez UI, a wniosek idzie do osobnego specu (np. kalendarz).

## 📋 Implementation Plan

### Faza 1 — Twoje imię
- **1.1** `MeetingsSettings.Key.selfName` + pole i przycisk „Użyj: …” w `MeetingsSettingsPane` (en/pl w `Localizable.xcstrings`, `StringCatalogTests`); wpis w `paneTokens` w `SettingsKeyCoverageTests`. Test: odczyt/zapis przez `InMemorySettingsStore`, domyślnie puste, odrzucenie wartości generycznej.
- **1.2** `NotesUtterance.make(from:selfName:)` (domyślnie `nil`) i przekazanie z `NotesService.process`. Warunek: `selfName` niepusty, `speaker_mode = diarized`, etykieta mówcy `is_self` równa `SpeakerLabels.me`. Test: linia `[mm:ss] Marek: …`; bez `selfName` zachowanie bez zmian (istniejący test `TranscriptChunkerTests` bez edycji); mówca z nazwą nadaną przez użytkownika zachowuje ją; imię z `|` i znacznikiem promptu jest oczyszczone; `channels` nie podstawia imienia.
- **1.3** Zmiana `selfName` oznacza notatki jako `stale` w spotkaniach, które mają notatki i mówcę `is_self` z etykietą `SpeakerLabels.me` (nowa operacja zbiorcza w `MeetingsStore`, jedna transakcja). Stare notatki nie są przepisywane po cichu; stają się `stale` i użytkownik regeneruje je sam. Test: tylko pasujące spotkania dostają `stale`, pozostałe nie.
- **1.4** Pomiar na ovn (eval-harness) po ustawieniu `selfName`: odsetek zadań z osobą przed/po. Wynik w PR bez deklaracji „poprawy jakości” ponad zmierzone.

### Faza 2 — podpowiedzi z potwierdzeniem (po kroku 1.4 specu jakości)
- **2.1** `SpeakerNameSuggester`: wzorce samoprezentacji PL/EN, zwrot po imieniu jako wskazówka, wykrywanie konfliktów. Testy na fixtures (wołacz, imię w cudzej wypowiedzi, nazwy produktów, dwa takie same imiona). Pomiar na polskim i ovn (ocena ręczna) i **bramka** z sekcji Phasing. Research rynku jest wykonany (sekcja Research).
- **2.2** Test prywatności: `NotesTrace` i logi bez imion.
- **2.3** UI w liście „Mówcy”: Przyjmij / Odrzuć, przewinięcie do dowodu, dostępność. Test modelu okna (przyjęcie wywołuje `renameSpeaker`, odrzucenie nic nie zmienia i nie wraca w tej sesji).
- **2.4** QA natywnego UI ze zrzutami (jasny i ciemny tryb), zgodnie z `docs/qa.md`.

## Decyzje użytkownika (bramka zamknięta)
Q1 dwa specy, najpierw jakość etykiet · Q2 samoprezentacja i zwroty po imieniu plus ręczne nadanie, bez kalendarza · Q3 imię w notatkach dopiero po potwierdzeniu · Q4 pole w Ustawieniach wstępnie z konta macOS · Q7 imiona tylko w bazie i dla lokalnego modelu, nigdy w śladzie.

## Wynik pomiaru z powiązanego specu (2026-11-06)
Na ovn 9 klastrów odpowiada 9–10 osobom nazwanym w tekście, a ziarnistość etykiet (segmenty mieszające osoby 15–20%) jest problemem. Dla tego specu: podpowiedź imienia przypisuje imię **klastrowi**, więc w segmencie mieszającym imię trafi do obu osób. Faza 2 powinna więc czekać także na spec podziału segmentów albo przynajmniej pokazywać dowód z konkretnej wypowiedzi (już w UI) i wymagać potwierdzenia (decyzja Q3).
