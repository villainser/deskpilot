# Przegląd bezpieczeństwa DeskPilot — aktualizacja 23.09.2026

Przegląd obejmuje kod DeskPilot, galerię biurek, rozpoznawanie profili Chrome, pamięć i przywracanie sesji, komunikację z Hammerspoon i instalator. Nie jest audytem całego komputera ani certyfikacją macOS, Chrome, Hammerspoon lub WebKit.

## Obecne podglądy

Każda karta biurka otrzymuje własny statyczny obraz. Po otwarciu panelu lub zmianie monitora kolejka wykonuje po jednym przechwyceniu co około 150 ms, najwyżej dla 32 kart, i kończy pracę. W bezczynności nie robi kolejnych zrzutów. Ręczne odświeżenie dotyczy wybranego okna. Pojedynczy wynik trafia do odpowiedniej karty; nie wymaga ponownego wysłania obrazów całej listy.

Podglądy wymagają włączenia przez użytkownika, widocznego panelu i zgody macOS na nagrywanie ekranu. W tej instalacji są włączone na prośbę użytkownika. Obraz ma maksymalnie 1280 × 800 pikseli i 1,2 MB w postaci zakodowanej. Cache mieści najwyżej 32 pozycje i 16 MiB zakodowanych obrazów. Usunięcie obrazu z cache usuwa również jego referencje z modelu panelu i DOM. Obrazy nie są zapisywane do plików ani wysyłane przez DeskPilot.

Schowanie panelu, zmiana monitora, wyłączenie podglądów, utrata zgody i blokada Maca przerywają kolejkę i czyszczą obrazy. Kontrola generacji odrzuca spóźnione wyniki. Zmiana wybranej karty zachowuje pozostałe zdjęcia, bez ponownego przechwytywania. Publiczna diagnostyka panelu nie zawiera obrazów.

Przed przechwyceniem kod ponownie sprawdza identyfikator okna, PID, bundle ID, monitor i przynależność do biurka. Cache wiąże obraz z ID okna, PID i bundle ID. Okna standardowe Accessibility mają pierwszeństwo przed pomocniczymi oknami Chrome. Przy braku Accessibility wybierane jest największe dostępne okno, bez wnioskowania o profilu z treści strony.

Bitwarden, Apple Hasła, Dostęp do pęku kluczy i rozpoznani menedżerowie haseł mają podgląd zablokowany. Dla Chrome użytkownik zezwolił na obrazy przed rozpoznaniem profilu: wymagane są warstwa 0 WindowServer oraz PID przypisany do uruchomionej aplikacji com.google.Chrome. Nazwa procesu nie wystarcza. Automatyczne przypisywanie biurka nadal wymaga osobnego rozpoznania profilu. Podglądy Chrome mogą obejmować poufne strony i okna prywatne; kod nie obiecuje wykluczania incognito.

## Komunikacja i operacje na biurkach

Panel ładuje lokalny HTML z CSP blokującym połączenia sieciowe, ramki i zewnętrzne zasoby. Dynamiczne napisy trafiają do textContent. Obrazy dopuszczone przez kod to rastrowe adresy data:. Komunikaty natywne wymagają własnego WebView, kanału deskpilot, głównej ramki i about:blank. Nazwy akcji są ograniczone, a identyfikatory mają limit 128 znaków.

Przycisk Otwórz wskazuje trwały identyfikator swojej karty, rozwiązywany ponownie względem aktualnej listy biurek. Nie opiera się na zaznaczeniu innej karty ani na dawnym numerze biurka. Rozwinięcie podglądu nie przełącza biurka. Podglądy nie zmieniają położenia, rozmiaru ani fokusu okien.

Helper nie ma setuid i jest uruchamiany przez hs.task bez powłoki. Metadane mają jawną listę pól, bez obrazów i tytułów okien. Helper 1.3.2 przesyła ramkę ASCII/base64 o znanej długości i czeka na stałe potwierdzenie odebrania całości. JSON jest dekodowany dopiero po poprawnym zakończeniu procesu. Limit ramki to 8 MiB plus nagłówek; brak potwierdzenia i timeout nie odświeżają zajętości biurek. Eliminuje to potwierdzony wyścig odczytów hs.task, który wcześniej zmieniał kolejność fragmentów JSON.

Manager nie przesuwa okien ani nie sprząta biurek przy zablokowanej sesji. Odblokowanie uruchamia stabilizację i odczyt zastanego układu; pauza pozostaje zachowana. Zwykłe przypisywanie nie rozstawia istniejących okien, ale osobny mechanizm może dokończyć oczekujące przywracanie sesji. Odczyt profili Chrome korzysta z sześciu pól nazw w Local State, bez czytania historii, cookies i plików haseł oraz bez uruchamiania zdalnego debugowania.

Instalator używa umask 077. Katalog konfiguracji i kopii mają tryb 700, konfiguracja i kopie ustawień 600, a helper 700. Kopie zawierają pełny eksport ustawień Hammerspoon, dlatego pozostają prywatne.

## Podążanie za świadomie otwartym oknem

Przejście na docelowe biurko jest dopuszczane po potwierdzonym automatycznym ruchu nowego, zarządzanego okna na pierwszym planie, powiązanego z niedawną interakcją użytkownika. Nie wystarcza zmiana tytułu, samo pojawienie się aplikacji w tle ani ponowne odkrycie zastanego okna. Rozdzielenie Chrome pozostaje oparte na profilu: wszystkie jego standardowe okna korzystają z tego samego biurka.

Kliknięcie, pisanie, wybór innego okna lub biurka podczas oczekiwania anuluje podążanie; anulowanego przejścia nie wykonuje się później. Start systemu, autostart zapisanych programów, przywracanie sesji i układanie istniejących okien nie uruchamiają tej funkcji. Sam reload konfiguracji również nie jest powodem do zmiany fokusu. Osłony dotyczą podążania DeskPilota; aplikacje i macOS mogą niezależnie aktywować własne okna. Natywny pełny ekran, Split View, okna przypisane do wszystkich Spaces oraz nierozpoznane profile zachowują dotychczasowe wyłączenia z automatycznego zarządzania.

Nowe logowanie uruchamia minutę wyciszenia podążania, również dla nowych okien na pierwszym planie. Reload w tej samej sesji zachowuje pierwotny termin osłony i nie odtwarza pominiętych przejść. Poza tą osłoną sprawdzana jest niedawna interakcja oraz dokładna tożsamość nowego aktywnego okna, procesu i grupy. Rejestrowany jest wyłącznie czas wystąpienia interakcji i fakt jej zmiany, bez klawiszy, wpisanego tekstu ani pozycji kliknięcia.

## Pamięć układu i uruchamianie programów

Zapis `deskpilot.sessionLayouts.v1` pozostaje w lokalnych ustawieniach Hammerspoon. Zawiera identyfikatory aplikacji i katalogów rozpoznanych profili Chrome, UUID monitorów i biurek, lokalne indeksy biurek, proporcjonalną geometrię okien, czas zapisu oraz listę ostatnio aktywnych grup. Dopasowanie wielu okien korzysta z SHA-256 ich tytułów. **Zapis sesji nie zawiera pełnych tytułów, URL-i, zrzutów ekranu ani treści dokumentów.** Hash służy do porównania, nie do szyfrowania danych. Nietrwałe PID-y i ID okien są używane tylko przy bieżących operacjach, a nie jako tożsamości zapisanych okien.

Walidacja dopuszcza wyłącznie opisane pola, skończoną geometrię i ograniczone listy: do 8 ekranów, 128 grup i 16 ramek na grupę; przechowywanych jest najwyżej 8 profili zestawów monitorów. Nieobecne aplikacje i pełniejsze listy ramek są zachowywane, żeby częściowy odczyt podczas zamykania nie wymazał pamięci. Do autostartu służy osobna lista `activeKeys`, dzięki czemu cała historia zamkniętych wcześniej aplikacji nie staje się listą uruchamiania.

Przed przywracaniem adapter uzgadnia listę Hammerspoon z rzeczywistymi identyfikatorami ekranów i flagą `builtIn` z CoreGraphics w helperze 1.3.2. Potrzebuje też aktualnych metadanych okien i znanej zajętości biurek. Taki sam licznik monitorów z innymi UUID nie uprawnia do użycia dawnych Spaces. Nowy monitor oznacza usunięcie starego UUID biurka z celu; zastępczy indeks jest używany tylko przy potwierdzonej dostępności. Nieznane okno lub odczyt nadal blokuje zajęcie i usuwanie biurka. Na każdym monitorze pozostaje co najmniej jedno zwykłe biurko.

Źródłem jest najnowsza zapisana sesja, dopasowywana do obecnych monitorów i ról aplikacji. Przywracanie wymaga co najmniej 3 sekund stabilnego odczytu. Automatyczne uruchamianie brakujących zapisanych aplikacji zaczyna się dopiero po 20 sekundach stabilnego rozpoznawania monitorów i nie omija pauzy, blokady ani osłon po zmianie sprzętu. W tym mechanizmie dozwolone są zmiany biurka i proporcjonalnego rozmiaru okien; zwykłe bieżące przypisywanie nadal nie skaluje istniejących okien.

Przed operacją zapisuje się fakt zużycia próby. Przeładowanie konfiguracji w tej samej sesji macOS nie ponawia już obsłużonego przywracania ani startów. Ruch, tworzenie biurka i ustawienie ramki wymagają ponownej kontroli tożsamości i generacji; ręczna ingerencja ma pierwszeństwo. Przy zamykaniu zamrażany jest ostatni prawidłowy zapis, bez skanowania znikających okien. Polecenia ręczne znajdują się w menu **Pamięć układu i start programów**.

Uruchamianie korzysta z `/usr/bin/open` przez `hs.task` z oddzielnymi argumentami, bez powłoki i bez URL-i. Wymagana jest zainstalowana aplikacja. Chrome otrzymuje rozpoznany katalog profilu i `--restore-last-session`; za poprzednie karty odpowiada własny mechanizm Chrome. Uruchomienie innych aplikacji nie gwarantuje przywrócenia dokumentów. Jedna próba startu na grupę w cyklu przywracania ogranicza ponawianie nieudanych operacji.

Niedostępne jeszcze w Accessibility okna nie są odkrywane przez automatyczne przechodzenie po Spaces. Oczekujące przywrócenie może nastąpić dopiero po późniejszym rozpoznaniu aplikacji lub profilu; pozycje już obsłużone pozostają oznaczone jako wykonane. Niepełne przywrócenie i nieudane uruchomienia są sygnalizowane w panelu, a polecenia menu zwracają informację o zapisie lub gotowości do odtwarzania.

## Weryfikacja

Testy projektu obejmują kolejkę galerii, dobór okna standardowego, zachowanie pozostałych zdjęć, bezczynność bez nowych przechwyceń, limity pamięci, wykluczanie aplikacji chronionych, anulowanie i czyszczenie danych. Osobne regresje pamięci sesji sprawdzają uszkodzone zapisy, brak monitorów, zmianę ich UUID, aktywne grupy, ramki, jednokrotność operacji i ręczne anulowanie. Próby z zastępczym API nie są potwierdzeniem restartu ani odłączania sprzętu na żywo.

W rzeczywistym WebView sprawdzono 10 warunków na fikcyjnych danych: osobne obrazy kart, Otwórz z innej karty niż zaznaczona, rozwinięcie tej samej karty, powiększanie bez nowego żądania, aktualizację bez przebudowy listy, czyszczenie obrazów i odrzucenie spóźnionego wyniku. Wygląd sprawdzono na własnych przykładowych obrazach.

Na odblokowanym Macu potwierdzono obrazy trzech głównych okien Chrome z trzech nieaktywnych biurek: 2495 × 1409 pikseli przed zmniejszeniem. Próbkowanie potwierdziło niejednorodną zawartość. Aktywne biurka i fokus pozostały identyczne przed i po przechwyceniu. Zdjęcia prywatnych okien nie zostały zapisane do plików ani umieszczone w raporcie. Osobny test przełączenia biurka i powrotu potwierdził zmianę aktywnego Space na właściwym monitorze.

Wcześniejsza kontrola transportu wykonała 30/30 poprawnych odpowiedzi hs.task oraz 69 odczytów managera bez nowego błędu JSON po wdrożeniu poprawki. Testy argumentów helpera odrzuciły nieprawidłowe identyfikatory i tekst przypominający polecenia powłoki przed wykonaniem ruchu.

Po instalacji panel pokazał 16 kart na wybranym monitorze i 14 prawdziwych obrazów. Jedna karta nie miała dostępnego okna, a jedno pomocnicze okno nie udostępniało obrazu. Wykonano 15 prób przechwycenia, jedno pełne przesłanie modelu i 15 pojedynczych aktualizacji. Liczniki pozostały niezmienione po zakończeniu kolejki (kontrola po 34 sekundach od otwarcia). Podglądy trzech nieaktywnych biurek Chrome były obecne na właściwych kartach.

Kliknięcie prawdziwego przycisku Otwórz na karcie innej niż zaznaczona przeszło przez natywny mostek i przełączyło właściwy monitor z Space 169 na 177; pozostałe monitory zachowały aktywne biurka. Panel schował się bez błędu. Po teście przywrócono pierwotne biurko i usunięto diagnostyczne liczniki. Test nie przesuwał ani nie skalował okien.

## Sprzątanie partiami zamiast powtarzanych animacji

Wcześniejsze sprzątanie usuwało tylko jedno biurko na wywołanie. Każde wywołanie hs.spaces.removeSpace otwierało i zamykało Mission Control, a zmiana układu zerowała czas wykrywania pustki pozostałych biurek. Powodowało to serię animacji co kilkanaście sekund, aż do wyczerpania pustych kandydatów.

Nowa operacja najpierw potwierdza cały stabilny zestaw kandydatów poza Mission Control. Każde biurko musi być puste przez co najmniej 8 sekund. Nowo wykryte puste biurko opóźnia rozpoczęcie całej partii. Dopiero potem otwierana jest jedna własna sesja Mission Control; kolejne usunięcia używają removeSpace(id,false), a sesja jest zamykana na końcu.

Plan zawiera kopie identyfikatorów, UUID i monitorów. Przed każdym usunięciem kod sprawdza świeżą tożsamość, aktywne biurka, zajętość, rezerwacje i pozostawienie co najmniej jednego biurka na monitorze. Niekompletne dane nie potwierdzają pustki ani powodzenia usunięcia. Pauza, blokada, odłączenie monitora i ingerencja użytkownika przerywają operację. Ręczne zamknięcie Mission Control nie powoduje samoczynnego ponawiania tej samej partii. Potwierdzenie usunięcia wymaga zniknięcia UUID z kompletnego odczytu wszystkich monitorów; samo przeniesienie biurka na inny monitor nie wystarcza.

Kontrolowany test na tym Macu utworzył dwa tymczasowe, puste biurka na monitorze z jednym istniejącym biurkiem. Produkcyjny manager najpierw wykrył oba, a następnie usunął je w jednej sesji Mission Control: jedno otwarcie, dwa wywołania usunięcia bez zamykania sesji i jedno zamknięcie. Cała próba wykrywania i sprzątania trwała około 13 sekund. Aktywne biurka na wszystkich trzech monitorach pozostały identyczne. Potwierdzono usunięcie obu testowych biurek i zachowanie wszystkich pięciu zastanych.

Próba ujawniła też systemową nakładkę `com.apple.loginwindow`, która błędnie blokowała sprzątanie pustych biurek. Ignorowana jest wyłącznie powierzchnia tego dokładnego procesu na niezerowej warstwie, bez okna AX. Zwykłe okna, obiekty AX i nieznani właściciele nadal blokują usunięcie.

Dodatkowe regresje sprawdzają dziewięć pustych biurek na trzech monitorach: po partii pozostaje po jednym zwykłym biurku na każdym ekranie, również przy aktywnym pełnym ekranie. Symulacja zewnętrznego usuwania biurek w trakcie partii potwierdza ponowną kontrolę minimum przed każdym usunięciem. Po wdrożeniu wznowiono automat; w ponad 30-sekundowej obserwacji bezczynności nie wywołał Mission Control, a wszystkie zastane aktywne biurka pozostały bez zmian.

## Nowe programy i powiadomienia Docka — 22.09.2026

Rzeczywista próba z własnym pustym programem Cocoa potwierdziła, że pojawienie się jego ikony w Docku zmieniało dostępną szerokość ekranu o jeden piksel. Pełna geometria i tożsamość wszystkich monitorów pozostawały identyczne. Bezwarunkowa obsługa powiadomienia hs.screen.watcher resetowała wtedy wykrywanie nowych okien i gubiła przydział. Poprawka porównuje posortowane UUID i pełne prostokąty ekranów; zmiana samego obszaru roboczego nie kasuje kolejki. Rzeczywista zmiana monitorów lub ich geometrii, wybudzenie i odblokowanie nadal uruchamiają stabilizację. Odczyt okresowy i powiadomienie ekranu współdzielą aktualny opis geometrii, więc ta sama zmiana nie resetuje przydziału dwukrotnie, niezależnie od kolejności powiadomień.

Informacja o nowym oknie pozostaje też oczekująca, jeżeli macOS chwilowo nie podaje jego Space. Regresje obejmują odzyskanie lokalizacji po trzech odczytach, dokładnie jedno przeniesienie, zmiany Docka i rzeczywiste zmiany monitorów. Przed poprawką odtworzono błąd na ekranie. Po poprawce przeszły testy kodu; ponowna próba na ekranie oczekuje na odblokowanie Maca.

## Przywracanie sesji — 23.09.2026

Przeszło 375 testów w 14 zestawach, sprawdzenie składni Lua/JavaScript oraz kompilacja helpera z ostrzeżeniami traktowanymi jako błędy. Kontrolowana próba na trzech ekranach użyła pustej aplikacji Cocoa oraz osobnego zapisu w pamięci. Sprawdzono prawdziwy autostart, utworzenie testowego biurka, przeniesienie między monitorami i proporcjonalną geometrię. Końcowa próba wykonała dokładnie jedno uruchomienie i jeden ruch, zachowując fokus oraz aktywne biurka wszystkich monitorów. Ponowne utworzenie koordynatora z tym samym identyfikatorem sesji nie ponowiło operacji. Nie restartowano Maca ani nie odłączano monitorów.

Próba wykryła dwa wyścigi: nowo utworzone biurko może jeszcze mieć nieaktualne dane CG, a przeniesienie na niewidoczne biurko może usunąć okno z aktualnej listy AX. Pierwszy przypadek wymaga ponownej stabilizacji przez co najmniej 3 sekundy. W drugim zajętość korzysta z wcześniejszego przypisania wyłącznie po świeżym potwierdzeniu zgodnych ID okna i dodatniego PID; bieżące AX i powiązanie profilu Chrome mają pierwszeństwo. To pominięcie dotyczy tylko uczestników przywracania — takie okno nadal blokuje usunięcie biurka. Nieudane przywrócenie jest liczone w `sessionRestoreFailed` i widoczne w panelu.

## Podążanie za nowym oknem — 23.09.2026

Po dodaniu podążania przeszło 430 testów w 15 zestawach. Próba na żywo użyła własnej pustej aplikacji i oddzielnego managera z wyłączonym sprzątaniem. Otwarcie w tle wykonało ruch bez podążania. Następnie jawna testowa aktywacja nowego okna, z kontrolowaną intencją otwarcia, doprowadziła do jednego ruchu i jednego przejścia na własne testowe biurko. Weryfikacja potwierdziła fokus dokładnego okna, właściwy Space, niezmieniony rozmiar i zachowanie aktywnych biurek pozostałych monitorów. Na tym Macu konieczny był pojedynczy fallback `gotoSpace` po próbie `window:focus()`.

Osobne regresje blokują podążanie podczas startu i przywracania sesji, po zmianie intencji/fokusu/biurka oraz po utracie uprawnienia do obserwacji wejścia. Tryb Secure Input anuluje podążanie, ponieważ uniemożliwia pełne wykrywanie ingerencji klawiaturą. Nie przeprowadzano restartu systemu ani nowego testu rzeczywistych profili Chrome; rozdzielenie profili ze wspólnym PID jest objęte regresją managera.

## Granice ochrony

Nie każde ukryte, zminimalizowane lub chronione okno udostępnia obraz. Brak podglądu nie oznacza pustego biurka. Obraz jest datowanym zdjęciem, nie transmisją na żywo. System może ograniczać odświeżanie treści aplikacji w tle.

Brak zapisu obrazów przez DeskPilot nie gwarantuje wymazania pamięci lub systemowego swapu. Ochrona menedżerów haseł nie rozpoznaje wszystkich poufnych treści w przeglądarce. Hammerspoon ma uprawnienia do sterowania interfejsem; program z dostępem do konfiguracji na tym samym koncie może podmienić jej kod. Prywatne API Spaces zależy od wersji macOS. Przegląd nie obejmuje pełnego testu odłączania monitorów ani testu penetracyjnego całego systemu.
