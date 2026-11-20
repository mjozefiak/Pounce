# Co osłabia rezygnacja z okna zgody ("wybór dostawcy = zgoda")

Wdrożone zgodnie z decyzją właściciela (2026-11-20). Ten plik jest do przedstawienia właścicielowi: wypisuje, co się zmienia względem specu `.ai/specs/2026-11-10-external-ai-providers.md` i ADR 0011/0013 (stan origin/main). Każde złagodzenie to **opcja do wyboru**, nie wdrożona w makiecie. Odwołania „spec: …” to sekcje specu (Data Model, Architecture, UI, Edge Cases, macierz „0 procesów”, Risks).

## Co zostaje (nie słabnie)
- Dostawca zewnętrzny jest **domyślnie wyłączony**; domyślnie Lokalnie (spec: wartości domyślne, „nic nie jest zapisywane bez kliknięcia użytkownika”).
- `ProviderRunner.run` nadal odmawia startu procesu z treścią, gdy dostawca nie jest wybrany; autoryzacja jest sprawdzana przed **każdym** procesem (ADR 0011, decyzja 3), ustawienia czytane przy każdym pytaniu, nie z pamięci zadania.
- Stała, widoczna informacja przy wyborze i w banerze („Transcripts leave this Mac”), odnośnik „Szczegóły” z pełną listą (co wychodzi, kiedy, ponowienia, „nie da się cofnąć”, uczestnicy).
- Powrót na Lokalnie = natychmiastowy koniec wysyłki, bez pytania (spec, „Powrót na model lokalny”).
- Znacznik „Wysłano do” przy spotkaniu, brak śladu dostawcy w eksportach, lista „Nigdy” (audio, tytuły, `source_bundle_id`, notatnik, słownik spotkań).
- Izolacja procesu (`isolationVerified`, bramka kanarka) i bramka jakości G: bez zmian.

## Co słabnie

### 1. Brak wyraźnego aktu potwierdzenia, jego daty i wersji tekstu
Dziś: `providerConsent = {provider, model, feature, at, textVersion}` zapisywany dopiero po „Turn On” w oknie z listą (spec, Data Model; ADR 0011, decyzja 2). Po zmianie: zgodą jest sam zapis `notesSource/notesProvider/notesProviderModel`; nie ma „kliknąłem Włącz po przeczytaniu listy”, nie ma `at`, nie ma `textVersion`, więc **nie da się później wykazać, co użytkownik widział i kiedy**.
Złagodzenia: (a) zapisywać przy wyborze `at` i wersję tekstu informacji (zachowuje dowód, bez okna); (b) wiersz „Wybrano Claude Code 20 lis 2026” w Szczegółach; (c) nic.

### 2. Zmiana rodzaju wysyłanych danych w przyszłej wersji nie wywoła ponownego pytania
Dziś: podniesienie `textVersion` unieważnia zgodę i okno pojawia się znowu; ADR 0013 wprost: dodanie terminów słownika zmienia wersję, „a consent given earlier is no longer valid”, a użytkownik, który zbudował słownik pod starą obietnicą, „learns of the change from the provider's consent window” (ADR 0013, skutki). Po zmianie: nowy rodzaj danych (np. kolejny z listy (e) „co wychodzi”) wyjdzie **po aktualizacji aplikacji bez żadnego pytania**, jeśli użytkownik wcześniej wybrał dostawcę. To dokładnie przypadek terminów słownika: wszyscy, którzy już wybrali Claude Code, zaczną je wysyłać po aktualizacji.
Złagodzenia: (a) wersja informacji (`infoVersion`) zapisana przy wyborze; po zmianie zakresu danych baner „Zmienił się zakres wysyłanych danych” z „Przejrzyj” i dotychczasowy wybór **zawieszony** (0 procesów) do kliknięcia (to dokładnie dzisiejsza semantyka, tylko bez okna: inline w banerze, stan 4 z v1); (b) baner informacyjny bez zawieszania; (c) nic (zmiana opisana w notach wydania). Uwaga: (a) wymaga zachowania wiersza macierzy 3 („stara wersja tekstu → 0”).

### 3. Przypadkowy wybór w menu od razu uruchamia wysyłkę
Dziś: wybór w menu otwierał okno, „Cancel” był domyślny, poprzedni wybór zostawał w mocy (spec, „Zmiana dostawcy albo modelu = nowa zgoda”). Po zmianie: jedno kliknięcie w menu wystarcza; następne spotkanie (albo automatyczne ponowienie, dokończenie w tle, „Regenerate”) wysyła **cały transkrypt z imionami**. Dochodzi przypadek klawiatury/VoiceOver (strzałka + Return na pozycji menu).
Złagodzenia: (a) „Cofnij” w banerze przez kilkanaście sekund po wyborze (nic nie startuje w tym oknie czasu; kosztem opóźnienia pierwszej wysyłki); (b) pierwszy wybór po instalacji wymaga drugiego kliknięcia w banerze „Potwierdź wybór”, kolejne zmiany nie (to jest krótkie okno zgody w innej formie, więc właściciel może to uznać za sprzeczne z decyzją); (c) przy wyborze pierwszego dostawcy zewnętrznego w historii instalacji menu pokazuje informację nad listą; (d) nic.

### 4. Zmiana modelu u tego samego dostawcy nie pyta, a w trakcie zadania wysyła ponownie
Dziś: każda zmiana modelu = nowe okno (spec: „pojawia się przy każdej zmianie modelu”; macierz wiersze 5, 16, 23). Po zmianie: bez pytania. Konsekwencje: (a) inny model to inne warunki użycia/limit/ewentualnie inna ścieżka u dostawcy, o czym użytkownik nie jest informowany; (b) zmiana modelu **w trakcie zadania** przerywa proces i uruchamia całość od nowa na nowym modelu (spec: „notatki nigdy nie są sklejane z dwóch modeli”), czyli transkrypt wychodzi drugi raz bez wiedzy użytkownika; (c) wiersze macierzy 5, 16, 23 trzeba przepisać (dziś mówią o zgodzie „dla innego modelu”).
Złagodzenia: (a) zmiana modelu w trakcie zadania czeka na koniec zadania (nie restartuje); (b) w Szczegółach linia o zużyciu limitu różnych modeli (D8); (c) nic.

### 5. Użytkownik po aktualizacji, imporcie ustawień albo ręcznej edycji
Dziś: `notesSource = provider` bez ważnej zgody zachowuje się jak `builtIn` + baner (spec, Edge Cases; macierz 1–6: 0 procesów). Po zmianie: `notesSource = provider` **jest** zgodą. Skutki: (a) przywrócenie kopii ustawień, ustawienia skopiowane z innego Maca lub wpisane ręcznie (`defaults write`) wysyła dane bez żadnego aktu użytkownika na tym Macu; (b) nie ma już „zapisu zgody”, więc nie da się odróżnić „wybrał świadomie” od „ustawienie przyszło skądś”; (c) wiersze macierzy 1, 2, 6 tracą sens (nie ma niezgodnego zapisu zgody, który blokowałby start).
Złagodzenia: (a) ustawienia dostawcy zapisywane z oznaczeniem, że powstały z kliknięcia na tej instalacji (wartość `chosenAt` + identyfikator instalacji; zapis spoza UI = 0 procesów, baner „Potwierdź wybór”); (b) nic.

### 6. Uczestnicy spotkań nadal nie są informowani
Bez zmian względem decyzji właściciela z 2026-11-19 (spec: ryzyko przyjęte; ADR 0011, konsekwencje: „Lintel does not tell participants… the consent tells the user”). **Różnica:** dotąd obowiązek informowania był wypowiedziany w oknie, które użytkownik musiał kliknąć; teraz tylko w „Szczegółach”, które może nie otworzyć. Złagodzenie: zdanie o uczestnikach w **krótkiej** informacji (nie tylko w liście), np. „Poinformowanie uczestników spotkań należy do Ciebie.”; albo nic.

### 7. Jedna „zgoda” dla wszystkich spotkań, także poufnych i automatycznych
Bez zmian merytorycznych (spec, Risks: przyjęte), ale bez okna łatwiej o niezauważony wybór. Złagodzenie: baner „Notatki pisze Claude Code. Transkrypty opuszczają tego Maca.” widoczny stale (zostaje) oraz, opcjonalnie, krótka informacja w HUD-zie nagrania, gdy dostawca jest wybrany (spec dziś: „bez nowych elementów przy spotkaniu poza znacznikiem”, więc to zmiana decyzji).

## Co zmienia wielość dostawców i sposobów podłączenia (dopisek)
Dawne okno było per dostawca i per model; wybór = zgoda przenosi to na zwykłą zmianę menu, więc:
1. **Przełączenie z jednego dostawcy zewnętrznego na innego wysyła dane do NOWEJ firmy bez żadnego pytania** (np. z Anthropic na dostawcę innego narzędzia CLI). Dziś spec wymaga nowej zgody („Każdy to nowy deskryptor i nowa zgoda”, Faza 3; macierz wiersz 4). To największa zmiana jakościowa: zgoda na jedną firmę zaczyna być odczytywana jako zgoda na każdą. Złagodzenia: (a) pierwszy wybór **każdej firmy** (nie modelu) pokazuje krótką informację inline z nazwą firmy i wymaga „Potwierdź” (zachowanie „zgody per odbiorca” bez okna); (b) tylko baner po zmianie z „Cofnij”; (c) nic.
2. **Klucz API to inne warunki przetwarzania niż subskrypcja** (warunki API, rozliczenie za użycie; makieta E-tomorrow pokazuje to w „Szczegółach”), a ADR 0013 mówi, że terminy słownika **nie** idą przez klucz API. Wybór „tego samego dostawcy” przez inny kanał (subskrypcja → klucz) zmienia zarówno warunki, jak i zakres danych (bez słownika), bez pytania. Złagodzenie: traktować kanał (CLI / API) jak osobnego dostawcę w sensie punktu 1.
3. **Zakres danych różni się per dostawca/kanał** (słownik tylko Claude Code, ADR 0013): wspólna krótka informacja nie może go obiecać dla wszystkich. Złagodzenie: krótka informacja generowana z deskryptora (lista rodzajów danych per dostawca), a „Szczegóły” pokazują dokładne różnice (tak robi makieta w wariancie klucza API).
4. **Rośnie liczba stanów „niedostępny”** (nieinstalowany, niezalogowany, bez klucza): D14. Wyszarzona pozycja nie jest zgodą; dopiero wybranie pozycji gotowej.
5. **Bramka „0 procesów”**: macierz (28 wierszy) opiera się na „zapisie zgody dla innego dostawcy/modelu”; przy braku zapisu trzeba ją przepisać na „wybór dostawcy”, a test „nigdy wbudowany → dostawca” i „terminy słownika tylko przez Claude Code” zostają jako jedyne twarde bramki zakresu.

## Podsumowanie dla właściciela
Zostaje: domyślnie wyłączone, egzekucja w kodzie przed każdym procesem, stała informacja. Znika: dowód aktu (data, wersja), ponowne pytanie przy zmianie zakresu danych, zmianie modelu i **zmianie firmy**, ochrona przed przypadkowym kliknięciem i przed ustawieniem „z zewnątrz”. Najtańsze złagodzenia o największym efekcie: zapis `at` + `infoVersion` przy wyborze z zawieszeniem wysyłki przy zmianie zakresu (pkt 1–2), „Cofnij” po wyborze (pkt 3), potwierdzenie inline przy pierwszym wyborze nowej **firmy** (wielość dostawców, pkt 1).
