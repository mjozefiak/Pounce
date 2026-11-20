# Decyzje właściciela (2026-11-20): makieta v2 W PEŁNI ZAAKCEPTOWANA

Wybory właściciela (opcje opisane niżej, poza D15, gdzie wybór ma własne brzmienie):

- **D5 = A.** **D6 = A** (+ zdanie, że wysłanego nie da się cofnąć). **D7 = C** (po awarii jawne pytanie „Napisać na tym Macu?”; bez cichego fallbacku; w rdzeniu bez UI zostaje „bez fallbacku”, C wchodzi z UI).
- **D8 = B. D9 = A** (+ zdanie, że brak znacznika nie znaczy „nie wysłano”). **D10 = B. D12 = B.**
- **D13:** ton neutralny; zdanie „Wybór tego dostawcy oznacza Twoją zgodę” zostaje; nazwa firmy pogrubiona.
- **D14 = C** (tylko działający + „Dodaj dostawcę…”).
- **D15 = B w brzmieniu właściciela: „Sonnet, Haiku, Opus, Fable; każdy po kanarku/pomiarze”.** Poprawka względem poprzedniej wersji tego pliku: opcja B była tu opisana jako „A + Opus i Fable (każdy po kanarku i bramce G)” z rekomendacją A. Obowiązuje wybór właściciela: cztery aliasy, **każdy widoczny i wybieralny w menu dopiero po przejściu kanarka izolacji/pomiaru; model niezmierzony nie jest w menu, dopóki nie przejdzie.** Niejasność: czy „pomiar” dla Opusa i Fable obejmuje bramkę G (jakość), czy tylko kanarek i budżet wejścia; spec przyjmuje węższe znaczenie (G tylko dla Sonneta).
- Złagodzenia z CO-OSLABIA.md: właściciel nie wybrał żadnego; pozostają opcjami nierozstrzygniętymi.
- Makieta nie jest przerysowywana; poniższe opisy opcji są historyczne (przed wyborem), zachowane do wglądu.

---

# (Historyczne) Decyzje do rozstrzygnięcia przez właściciela (makieta v2)

Nic tu nie jest wybrane. Rekomendacja agenta jest tylko oznaczona. Decyzje właściciela, które obowiązują (2026-11-19/20): brak flagi per spotkanie, brak oznaczeń AI w eksportach, brak logu wysyłek w v1, tekst dla uczestników bez zmian, **brak okna zgody: wybór dostawcy = zgoda**, domyślnie Lokalnie, zmiana modelu u tego samego dostawcy bez pytania, menu zamiast kart. Zawężone listy D1–D4, D11 zostały rozstrzygnięte w v2 i nie wracają.

## D5. „Wypróbuj” (Try it)
- A. Przycisk wysyła stały, krótki przykład Lintela (nie spotkanie), podpisany; dostępny dopiero po wybraniu dostawcy (makieta). + wiadomo przed pierwszym spotkaniem, czy działa; − bez okna nie ma już „przed zgodą”, więc to wysyła tekst do dostawcy tuż po wyborze.
- B. Brak przycisku. + nic nie wychodzi przy teście; − problem widać dopiero po pierwszym spotkaniu.
Rekomendacja: A, z podpisem, że to nie jest spotkanie.

## D6. Notatki już napisane przez dostawcę po powrocie na „Lokalnie”
- A. Zostają bez zmian, znacznik „Wysłano do” zostaje (stan 7 w makiecie, wg specu). + znacznik opisuje tekst, który jest w notatkach.
- B. Zostają, znacznik zmienia się na „Wysłano wcześniej do: Claude”. + bliżej prawdy o historii; − więcej tekstów.
- C. Propozycja „Napisz je od nowa lokalnie”. − zmienia treść, ryzyko utraty lepszych notatek; tylko za zgodą.
Rekomendacja: A, z jednym zdaniem w banerze, że wysłanego nie da się cofnąć.

## D7. Co po błędzie dostawcy (nieinstalowany, niezalogowany, timeout, za długi)
Pokazane OBA stany w C-states.
- A. Brak fallbacku (5a; wcześniejszy wybór właściciela, spec Q7). + zero niespodzianek, kto pisał. − użytkownik bez notatek, dopóki nie zadziała.
- B. Cichy fallback na lokalny z oznaczeniem. + notatki zawsze są; − niespójna jakość, zmiana bez wiedzy użytkownika (spec odrzuca cichy fallback: „nigdy wbudowany → dostawca”, jednokierunkowy).
- C. Pytanie po awarii „Napisać na tym Macu?” (5b). + jedno kliknięcie, jawne, nic więcej nie idzie do dostawcy; − wymaga zainstalowanego modelu wbudowanego.
Rekomendacja: C (przy pozostawieniu A jako stanu domyślnego do czasu decyzji).

## D8. Koszt i limit subskrypcji
- A. Nic (makieta). Błąd limitu pokazywany po fakcie.
- B. Jedna linia w „Szczegółach”: „Zużywa limit Twojej subskrypcji”.
- C. B + własny licznik spotkań w miesiącu (Lintel nie zna limitu konta).
Rekomendacja: B (jedno zdanie w „Szczegółach”, krótka informacja bez zmian). Dla klucza API (faza 2) zamiast tego „rozliczane za użycie”.

## D9. Znacznik „Wysłano do: Claude · model”
- A. Chip w bibliotece + wiersz w Szczegółach (makieta).
- B. Tylko wiersz w Szczegółach.
- C. A + chip w nagłówku notatki w oknie spotkania.
Osobno: brak znacznika nie znaczy „nie wysłano” (nieudane zadanie mogło wysłać transkrypt, brak dziennika wysyłek w v1). Czy mówimy to jednym zdaniem w Szczegółach (makieta ma je pod znacznikiem), czy milczymy.
Osobno (model): znacznik pokazuje **alias** („Sonnet”), bo konkretnej wersji Lintel nie zna (README, założenie 3). Alternatywa: pełna nazwa, jeśli CLI ją zwraca albo przy modelach przypiętych pełną nazwą.
Rekomendacja: A + jedno zdanie o braku znacznika.

## D10. Podpis jakości przy „Lokalnie”
- A. Pokazać teraz („Notatki krótsze i prostsze niż u dostawcy”; makieta). − twierdzenie bez zmierzonego wyniku bramki G.
- B. Pokazać po bramce G, do tego czasu bez podpisu.
Rekomendacja: B w produkcie, A w makiecie do oceny tonu.

## D12. „Użyj Lokalnie” podczas trwającej wysyłki
- A. Zawsze aktywne, bez potwierdzenia (wg specu).
- B. Gdy zadanie trwa, potwierdzenie „Zadanie trwa. To, co już wysłano, zostaje u dostawcy” (stan 9).
Rekomendacja: B tylko podczas trwającego zadania.

## D13. Teksty i ton
Wszystkie teksty robocze. Do rozstrzygnięcia: ton krótkiej informacji (neutralny vs. ostrzegawczy), czy „Wybór tego dostawcy oznacza Twoją zgodę” zostaje jako zdanie 2 (rekomendacja: tak, to jedyny jawny akt zgody), nazwa firmy z deskryptora (Anthropic) obok nazwy narzędzia, nagłówek „Szczegóły” vs „Co dokładnie wychodzi”.
Rekomendacja: ton neutralny, zdanie o zgodzie zostaje, nazwa firmy pogrubiona.

## D14. Dostępność dostawców w menu (nowe, z dopisku)
Pokazane w E-tomorrow.
- A. Wszyscy znani dostawcy widoczni; niezainstalowani/niezalogowani/bez klucza wyszarzeni z powodem i „Skonfiguruj…”. + użytkownik widzi, co istnieje; − dłuższe menu rosnące z każdym dostawcą, pozycje „na niby”.
- B. Tylko skonfigurowani i gotowi; reszta w Ustawieniach → Modele. + krótkie menu; − odkrywalność gorsza.
- C. Tylko działający + zawsze „Dodaj dostawcę…” (jeden wiersz prowadzący do konfiguracji). + skaluje się najlepiej; − dostawca niezainstalowany jest niewidoczny, dopóki ktoś nie kliknie.
- D. A, ale grupa zwija się powyżej N pozycji (np. 5).
Rekomendacja: C dziś (dwóch dostawców), A albo D, gdy będzie ich więcej niż trzech.

## D15. Lista modeli Claude Code (nowe)
- A. Wkompilowane aliasy: Sonnet, Haiku (stan dzisiejszy deskryptora). + sprawdzone kanarkiem; − brak Opusa i Fable, alias „dryfuje”.
- B. A + Opus i Fable (każdy po kanarku i bramce G). + pełny wybór; − koszt limitu, ryzyko jakości, więcej do mierzenia.
- C. A + „Inny identyfikator…” (wpisana pełna nazwa; walidowana przez `isValidModelID`). + elastyczne, przypina wersję; − ryzyko literówek i niemierzonych modeli, spec zakłada „Custom identifier…”.
- D. A + „Domyślny model konta”, jeśli CLI przyjmie `default` (niesprawdzone). 
Rekomendacja agenta (historyczna): A dziś, C jako wyjście dla zaawansowanych (Zaawansowane), B po pomiarze. **Wybór właściciela: B (patrz na górze).**
