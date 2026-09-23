# DeskPilot 2 — biurka dla aplikacji i profili Chrome

Konfiguracja Hammerspoon dla macOS: domyślnie **jedna aplikacja = jedno zwykłe biurko**, wszystkie jej standardowe okna razem. Dla Google Chrome obowiązuje **jeden profil = jedno biurko**: wszystkie jego okna i karty razem. DeskPilot pamięta układ ostatniej sesji, może uruchomić zapisane aktywne aplikacje i dopasowuje ich biurka do rzeczywiście podłączonych monitorów. Gdy na wybranym monitorze brakuje wolnego biurka, tworzy nowe.

## Zasady działania

W zwykłej pracy automatyczne przypisywanie nowych okien zachowuje ich rozmiar. Gdy świadomie otwierasz nowe okno na pierwszym planie, DeskPilot po potwierdzonym przeniesieniu może przejść za nim na docelowe biurko. Istniejące okna nie są stale rozstawiane od nowa. Osobny mechanizm **przywracania sesji** może odtworzyć zapisane położenie i rozmiar po nowym logowaniu, zmianie zestawu monitorów lub jawnym poleceniu przywrócenia, bez podążania za odtwarzanymi oknami. Przeładowanie Hammerspoon w tej samej sesji macOS nie ponawia już obsłużonych pozycji. Ręczne przeniesienie aplikacji lub profilu nadal obejmuje pozostałe jego okna i ma pierwszeństwo przed oczekującym automatycznym ruchem.

- Przypisanie pamięta UUID monitora i UUID biurka. Numer biurka służy do wyświetlania i skrótów; zmiana numeracji nie zmienia przypisania.
- Ręczne przestawienie całych biurek w Mission Control odświeża kolejność w panelu i skrótach. Aplikacje pozostają przypisane do swoich biurek; DeskPilot nie odwraca Twojego porządku.
- Wolne biurka są wybierane lokalnie na wskazanym monitorze. Nie ma przerzucania na inny ekran tylko dlatego, że jest tam wolne miejsce.
- Przeniesienie przez `Ctrl+Shift+numer` zapamiętuje nowy cel aplikacji. Ruch przez Mission Control jest rozpoznawany po ustabilizowaniu położenia przez około 2–3 sekundy. Pozostałe okna aplikacji dostają ten sam cel.
- Ręczne umieszczenie kilku aplikacji na jednym biurku jest zapamiętywanym wyjątkiem od rozdzielania aplikacji.
- Zmiana tytułu, przywrócenie z Docka i fokus nie wymuszają powrotu do starego biurka.
- Na każdym monitorze zawsze zostaje co najmniej jedno zwykłe biurko — również gdy wszystkie biurka są puste.
- Sprzątanie ma dwa etapy: najpierw wykrycie całego zestawu pustych, nieaktywnych biurek i potwierdzenie pustki przez co najmniej 8 sekund, potem usunięcie całej partii przy jednym otwarciu Mission Control. Przed każdym usunięciem ponownie sprawdzana jest zajętość i tożsamość biurka. Następne biurka zachowują tożsamość; zmieniają się jedynie ich numery.
- Zawsze pozostaje przynajmniej jedno zwykłe biurko na każdy ekran. Aktualnie wyświetlane puste biurko zostaje do momentu przełączenia na inne. DeskPilot nie przełącza użytkownikowi biurka tylko po to, żeby je skasować.
- Nieznane okno, brak metadanych albo błąd odczytu blokują kasowanie. Uwzględniane są nieaktywne biurka, okna zminimalizowane i aplikacje ukryte.
- Blokada Maca chowa podglądy i zatrzymuje ruchy okien, uczenie przypisań oraz sprzątanie. Po odblokowaniu automat czeka 8 sekund i odczytuje zastany układ, zachowując zapisany stan pauzy.
- Po zmianie monitorów/wybudzeniu obowiązuje 8 sekund stabilizacji. Przywracanie sesji dodatkowo wymaga kompletnego, stabilnego odczytu monitorów, biurek i okien. Jeżeli poprzedniego monitora nie ma, układ jest świadomie dopasowywany według opisanych niżej ról aplikacji.
- Tworzenie i ruch okien są wykonywane kolejno. Zapis celu następuje dopiero po odczycie potwierdzającym faktyczne położenie okna. Niepotwierdzony ruch wstrzymuje automatykę.

## Instalacja

Instalujesz na drugim komputerze? Zobacz [instrukcję przeniesienia DeskPilot na nowy Mac](PRZENOSZENIE.md), z bezpiecznym startem i opcjonalnym transferem pamięci układu.

Wymagania: Hammerspoon z uprawnieniem Dostępność oraz Apple Command Line Tools do kompilacji helpera. Ustawienia macOS: „Monitory mają osobne przestrzenie” włączone; „Automatycznie porządkuj przestrzenie według ostatniego użycia” wyłączone.

Z katalogu projektu:

```sh
sh native/build.sh
./install.sh
```

Instalator kopiuje pliki do `~/.hammerspoon`, a poprzednie pliki i ustawienia do `~/.hammerspoon/backups/deskpilot-DATA-PID`. Zastępuje `init.lua` wersją z tego projektu, dlatego najpierw tworzy jego kopię. Nie zmienia ustawień Mission Control ani ochrony SIP.

Pierwsze uruchomienie wersji 2 jest wstrzymane. Kliknij **Desk:**, sprawdź monitory i wybierz **Wznów** na dole panelu. To samo polecenie w menu ustawień ma etykietę `Wznow automatyke`. Kolejne przeładowania zachowują ostatni stan pauzy. Zwykłe automatyczne przypisywanie dotyczy nowych okien potwierdzonych w globalnej liście WindowServer; samo odkrycie starego okna na innym biurku nie jest powodem jego przeniesienia. Włączona automatyka pozwala również dokończyć oczekujące przywracanie zapisanej sesji.

Na komputerze testowym włączono start Hammerspoon przy logowaniu. Uprawnienie Dostępność było nadane, osobne Spaces były włączone, a automatyczne przestawianie wyłączone.

## Obsługa

| Skrót / menu | Działanie |
| --- | --- |
| Kliknięcie `Desk:` lub `Ctrl+Alt+Space` | Pokaż/ukryj wysuwany panel biurek. |
| `Option` + kliknięcie `Desk:` | Otwórz dotychczasowe menu ustawień i przypisań. |
| Ikona suwaków na dole panelu | Otwórz to samo menu ustawień. |
| `Ctrl+1…9`, `Ctrl+0`, `Ctrl+-` | Przełącz na biurko 1…11. |
| `Ctrl+Shift+1…9/0/-` | Przenieś aktywne okno i zapamiętaj cel aplikacji. |
| `Ctrl+Esc` | Pokaż/ukryj tę samą listę biurek z podglądami. |
| `Ctrl+Alt+Cmd+P` | Natychmiast wstrzymaj automatykę. |
| Menu → `Wstrzymaj automatyke` / `Wznow automatyke` | Pauza / wznowienie. |
| Menu → `Przypisz aplikacje do...` | Jawne przypisanie, także do wspólnego biurka. |
| Menu → `Przypisz to okno/profil...` | Opcjonalny wyjątek według tytułu. |
| Menu → `Usun puste, nieaktywne biurka` | Usunięcie wykrytej partii w jednej sesji Mission Control, z tymi samymi zabezpieczeniami. Działa przy włączonej automatyce. |
| Menu → `Pamięć układu i start programów` → `Zapisz układ teraz` | Zapisz aktualny układ po uzyskaniu stabilnego odczytu. |
| Menu → `Pamięć układu i start programów` → `Przywróć zapisany układ` | Jawnie rozpocznij przywracanie zapisanego układu. |

W tabeli „Menu” oznacza menu ustawień otwierane przez `Option` + kliknięcie `Desk:` albo ikonę suwaków w panelu. Numery pokazują bieżącą kolejność zwykłych Spaces. Nazwy i monitory są widoczne w panelu oraz ustawieniach. Apple nie pozwala tym mechanizmem podmienić nazw w samym Mission Control — nakładka z nazwami należy do DeskPilot.

### Podążanie za nowym oknem

Otwierasz program albo nowe okno profilu Chrome i pozostajesz w tym oknie: po automatycznym przydzieleniu do biurka DeskPilot przechodzi za nim, aby można było od razu pracować. Wymaga to potwierdzenia, że okno jest nowe, trafiło na pierwszym planie po niedawnej interakcji użytkownika i zostało poprawnie przeniesione. Chrome nadal ma **jedno biurko na profil**; kolejne okno trafia na biurko swojego profilu, a karty pozostają razem.

Kliknięcie, pisanie, wybór innego okna lub zmiana biurka w trakcie oczekiwania anuluje podążanie. Nie jest ono odkładane do późniejszego wykonania. Program otwarty w tle, zastane okna po reloadzie, przywracanie sesji i autostart zapisanych aplikacji nie wywołują takiego przejścia. Podczas uruchamiania systemu podążanie jest wyciszone, żeby odtwarzany układ nie przełączał kolejno biurek.

Po nowym logowaniu **pierwsza minuta jest bez podążania**, również za oknami na pierwszym planie. Zwykły reload nie rozpoczyna tej minuty od nowa i nie przywraca pominiętych przejść. Potem nadal wymagane jest dokładnie to nowe, aktywne okno i niedawna interakcja użytkownika.

Ta funkcja obejmuje zarządzane zwykłe okna. Natywny pełny ekran, Split View, okna na wszystkich Spaces i nierozpoznany profil Chrome pozostają objęte dotychczasowymi wyjątkami; nie ma gwarancji przejęcia fokusu w każdym trybie macOS.

### Pamięć ostatniej sesji i start programów

DeskPilot zapisuje aplikacje i odrębne profile Chrome, UUID monitorów i biurek, lokalne pozycje biurek oraz położenie i rozmiar okien jako proporcje obszaru roboczego monitora. Dzięki temu może odtworzyć układ na ekranie o innej rozdzielczości. Ramka jest ograniczana do dostępnego obszaru. Przy kilku oknach dopasowanie geometrii wymaga jednoznacznego skrótu tytułu; program nie zgaduje kolejności okien. Jedno zapisane i jedno bieżące okno nie wymaga takiego dopasowania.

Punktem wyjścia jest **najnowsza zapisana sesja**, również gdy pracowałeś ostatnio tylko na laptopie, a teraz podłączasz dwa monitory. Dawny zapis dla identycznego zestawu ekranów nie zastępuje nowszej pracy. DeskPilot sprawdza rzeczywistą liczbę i UUID monitorów w macOS; sama taka sama liczba ekranów nie oznacza tych samych urządzeń. Rozróżnienie ekranu wbudowanego i zewnętrznego pochodzi z systemu.

| Aplikacje | Domyślny monitor przy odtwarzaniu i nowym przypisaniu |
| --- | --- |
| Teams, Wiadomości, Messenger, Bitwarden, Ustawienia systemowe, Terminal/iTerm i obsługiwane terminale | Ekran laptopa, jeśli jest dostępny. |
| Chrome i jego profile, Chrome Canary, Edge, Brave, Firefox, Safari, Arc, Vivaldi, Opera | Monitor zewnętrzny, gdy jest dostępny. Poprawne istniejące przypisanie do zewnętrznego ekranu zostaje; grupy wymagające nowego celu są rozdzielane z uwzględnieniem powierzchni ekranów. |
| Pozostałe aplikacje | Zapisany monitor, jeśli nadal jest obecny; w przeciwnym razie laptop albo pierwszy dostępny ekran. |

Bez ekranu laptopa wykorzystywane są dostępne monitory. Bez ekranów zewnętrznych przeglądarki działają na laptopie. Zmiana docelowego monitora usuwa stare UUID biurka z odtwarzanego celu. Zastępcza pozycja musi wskazywać potwierdzone wolne biurko; program może też wybrać inne wolne albo utworzyć nowe. Nie odtwarza pustych luk i zawsze zachowuje minimum jedno zwykłe biurko na monitor.

Po uzyskaniu kompletnych danych przywracanie czeka co najmniej **3 sekundy niezmiennego odczytu**. Próby uruchomienia brakujących programów zaczynają się dopiero po **20 sekundach stabilnie rozpoznawanego zestawu monitorów**; do tego dochodzą obowiązujące osłony po wybudzeniu, zmianie ekranów i interakcji użytkownika. Pauza, blokada Maca lub niepełny odczyt wstrzymują operacje.

Do automatycznego uruchamiania służy lista aplikacji i profili potwierdzonych jako aktywne w ostatnim zapisie (`activeKeys`). Historia nieobecnych aplikacji pozostaje dostępna do zapamiętania układu, lecz nie uruchamia wszystkich dawniej używanych programów. Pusty lub częściowy odczyt podczas zamykania nie kasuje pełniejszego zapisu geometrii. Każda zapisana aplikacja/profil ma jedną próbę uruchomienia w danym cyklu przywracania; zwykły reload nie powtarza już wykonanych operacji.

Chrome uruchamiany jest z zapisanym katalogiem profilu i własnym mechanizmem `--restore-last-session`. To Chrome odpowiada za dostępność poprzednich kart i okien. DeskPilot nie zapisuje ich adresów. Dla pozostałych aplikacji uruchomienie programu **nie gwarantuje otwarcia poprzednich dokumentów** — zależy to od jego obsługi przywracania stanu w macOS.

Układ jest zapisywany automatycznie po stabilizacji. Oba polecenia menu pamięci działają przy włączonej automatyce; **Zapisz układ teraz** również wymaga stabilnego odczytu. Ręczny ruch lub zmiana okna podczas przywracania mają pierwszeństwo. Zapis sesji zawiera identyfikatory, geometrię i hashe tytułów do dopasowania okien, bez zrzutów ekranu, pełnych tytułów, URL-i czy treści dokumentów.

Okna na wcześniej nieodwiedzonych biurkach mogą być jeszcze niedostępne w Accessibility. Oczekujące przywracanie aplikacji lub profilu może wtedy dokończyć się po jego rozpoznaniu, na przykład po Twoim wejściu na to biurko. DeskPilot nie przełącza sam kolejnych Spaces w celu ich odkrycia i nie powtarza przywracania pozycji już obsłużonych.

Polecenia zapisu i przywrócenia pokazują potwierdzenie albo informację, że zapis nie jest jeszcze gotowy. Panel sygnalizuje nieudane uruchomienie części programów lub niepełne przywrócenie układu. Możesz wtedy sprawdzić okna, otworzyć brakujący program ręcznie i w razie potrzeby ponownie wybrać **Przywróć zapisany układ**.

### Sprzątanie bez serii animacji

Automat najpierw zbiera cały zestaw kandydatów. Jeśli kolejne biurko właśnie opustoszało, czeka na potwierdzenie jego pustki zamiast rozpoczynać kolejną małą partię. Po wykryciu zestawu usuwa biurka w jednej sesji Mission Control, weryfikując każde usunięcie. Pozostałe aplikacje zachowują swoje okna i biurka. Pojawienie się okna, utrata wiarygodnego odczytu, blokada, pauza lub zmiana monitorów przerywa albo ogranicza operację.

Mission Control nadal pojawi się raz na partię — jest potrzebne używanemu mechanizmowi macOS. Panel podglądów sam go nie wywołuje.

Jeśli ręcznie przerwiesz sprzątanie, jego automatyczne ponawianie zostanie wstrzymane. W ustawieniach wybierz **Wznów automatyczne sprzątanie**, aby je przywrócić; jeśli cała automatyka jest w pauzie, użyj **Wznow automatyke**.

### Jedna lista biurek z podglądami

Kliknij **Desk:** na pasku macOS albo naciśnij `Ctrl+Alt+Space` lub `Ctrl+Esc`. Wszystkie te wejścia otwierają ten sam panel. Wybierz monitor: każda karta biurka pokazuje własny podgląd reprezentującego je okna, także gdy biurko jest w tle. **Otwórz** na konkretnej karcie przechodzi bezpośrednio na jej biurko. Numer karty odpowiada aktualnej kolejności w Mission Control.

Kliknięcie obrazu rozwija tę samą kartę i daje większy podgląd, wybór okna oraz **Powiększ / Dopasuj**. Powiększanie używa już pobranego obrazu. Nie ma osobnej listy służącej tylko do przełączania biurek.

Po otwarciu panelu lub wybraniu monitora obrazy jego kart są pobierane kolejno, jeden raz. Potem pozostają statyczne; bezczynność i najazd myszą nie wywołują nowych zrzutów. **Odśwież podgląd** pobiera nowy obraz wybranego okna. Odczyt metadanych potrzebny do przypisywania nowych aplikacji działa osobno.

**Włącz podglądy** wymaga zgody macOS na nagrywanie ekranu. Nie każde zminimalizowane lub chronione okno udostępnia obraz. Brak podglądu nie oznacza pustego biurka i nie powoduje przełączenia na inne okno. Panel pokazuje stan niedostępności przy właściwej karcie.

Obrazy pozostają w pamięci; DeskPilot nie zapisuje ich do plików ani ich nie wysyła. Schowanie panelu, zmiana monitora, wyłączenie podglądów i blokada Maca usuwają obrazy. Bitwarden, Apple Hasła, Dostęp do pęku kluczy i inne rozpoznane menedżery haseł mają treść ukrytą. Chrome może pokazywać poufne strony i okna prywatne. Szczegóły: [BEZPIECZENSTWO.md](BEZPIECZENSTWO.md).

Aby przenieść aplikację, najpierw kliknij jej okno, a potem otwórz panel. Rozwiń kartę docelowego biurka i wybierz **Przenieś „nazwa” tutaj**. Panel zapamiętuje okno aktywne przed otwarciem. W Chrome działa to na profil tego okna. Ołówek zmienia nazwę biurka. `Esc` lub kliknięcie poza panelem chowa panel.

### Ręczna kolejność: Bitwarden po lewej stronie Chrome

Domyślnie Bitwarden trafia na laptop, a Chrome na monitor zewnętrzny. Jeśli chcesz mieć ich biurka obok siebie, najpierw ręcznie przypisz oba programy do tego samego monitora.

1. W panelu kliknij **Zmień kolejność**, aby otworzyć Mission Control.
2. Na właściwym monitorze przeciągnij miniaturę całego biurka Bitwardena na lewo od biurka wybranego profilu Chrome.
3. Zamknij Mission Control i odczekaj około 1–3 sekund. Panel oraz numery skrótów przyjmą kolejność macOS.

Przestawiasz całe biurka, więc Bitwarden i profil Chrome zachowują tożsamość swoich Spaces oraz przypisania. DeskPilot wykrywa zmianę kolejności także bez przełączania na inne biurko. Podczas pracy w Mission Control wstrzymuje automatyczne porządki.

Jeśli sam macOS pozwoli Ci przenieść całe biurko na inny monitor, DeskPilot aktualizuje monitor jego przypisań po potwierdzeniu stabilnego układu, gdy zestaw podłączonych monitorów i biurek pozostaje ten sam. Odłączenie monitora nadal uruchamia oddzielną ochronę i nie jest traktowane jako świadome przeniesienie biurka.

To zapamiętanie bieżącej kolejności, nie stała reguła sąsiedztwa. Po zamknięciu aplikacji i usunięciu jej pustego biurka kolejne uruchomienie może utworzyć nowe biurko w innym miejscu listy na zapamiętanym monitorze.

### Profile Google Chrome

Chrome jest automatycznie rozdzielany po profilach. Pierwsze nowe okno innego profilu dostaje osobne biurko; następne okna tego samego profilu trafiają na jego biurko. W menu `Profile Chrome — osobne biurka` widać rozpoznane profile i ich przypisania. `Ctrl+Shift+numer` oraz menu przypisania działają na profil aktywnego okna Chrome. Inne profile nie są przenoszone razem z nim. Kolejne karty pozostają w swoim oknie; nie są odrywane do nowych okien.

Profil jest identyfikowany przez pełną nazwę dostępną w tytule Accessibility Chrome i lokalną listę nazw profili. Trwałym kluczem jest katalog profilu, np. `Default` lub `Profile 1`, a nie tytuł strony ani sam proces Chrome. Odtwarzana jest nazwa wyświetlana według [reguł Chromium](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/profiles/profile_attributes_entry.cc). DeskPilot odczytuje plik JSON Chrome `Local State`, a do rozpoznawania zachowuje wyłącznie sześć pól nazw profili. Nie używa historii, cookies, haseł ani adresów email. Nie wymaga rozszerzenia ani włączania remote debugging.

Zmiana strony nie zmienia tożsamości profilu. Rozpoznanie jest pamiętane przez czas życia okna, także gdy dialog chwilowo zastąpi jego tytuł. Zmiana nazwy profilu nie zmienia zapisanego katalogu profilu. Po zmianie listy profili odczyt nazw odświeża się co około 10 sekund.

**Niejednoznaczne nazwy pozostają nierozpoznane.** Dwa profile o tej samej wyświetlanej nazwie wymagają odróżnienia nazw w Chrome. Nowe okna incognito, gościa lub inne bez jednoznacznej nazwy profilu pozostają na miejscu. Program nie przypisuje ich automatycznie do wspólnego biurka całego Chrome.

Po przeładowaniu Hammerspoon okna na niewidocznych biurkach mogą zostać wykryte dopiero przy odwiedzeniu tych biurek. Odświeżanie listy okien przy przełączeniu Space jest włączone; nierozpoznane okna nadal chronią biurka przed usunięciem.

Stare reguły całego Chrome i reguły Chrome oparte wyłącznie na tytule strony są zachowane w ustawieniach/kopii, ale nie wymuszają wspólnego celu. Nowe reguły zawierają `profileDirectory`. Dla Firefoxa i pozostałych przeglądarek dotychczasowa obsługa aplikacji oraz opcjonalnych wyjątków tytułowych pozostaje bez zmian.

## Migracja

Stare automatyczne przypisania `deskpilot.dockedRules.v1` były oparte na zmiennych numerach i pozostają w kopii ustawień; nie są automatycznie odtwarzane. Jawne reguły aplikacji/profili są zachowane, ale stary numer nie jest używany jako cel. Aktualne położenie okien pozwala utworzyć nowe przypisanie. Wersja 2 zapisuje własne klucze `*.v2`.

Gdy puste biurko przypisanej aplikacji zostanie usunięte, program pamięta jej monitor. Przy następnym uruchomieniu wykorzystuje wolne biurko na wybranym ekranie albo tworzy nowe, uwzględniając dostępne monitory i opisane wyżej role aplikacji. Nie rezerwuje pustej dziury na stałe dla zamkniętej aplikacji.

## macOS Tahoe i ograniczenia

Hammerspoon 1.1.1 potrafi zwrócić powodzenie `moveWindowToSpace` bez faktycznego ruchu na Tahoe. Dołączony `deskpilot-move` korzysta z mechanizmu opisanego w [Hammerspoon PR #3889](https://github.com/Hammerspoon/hammerspoon/pull/3889). Wywoływany jest dopiero po niepotwierdzonym ruchu standardowym API. Nie wymaga zmiany Hammerspoon ani wyłączania SIP. Zobacz [native/README.md](native/README.md).

`hs.spaces` jest eksperymentalnym API opartym na prywatnych mechanizmach Apple. Dodawanie/usuwanie biurek i przełączanie może na chwilę otwierać Mission Control. Aktualizacja macOS może wymagać ponownego sprawdzenia helpera. [Dokumentacja Hammerspoon](https://www.hammerspoon.org/docs/hs.spaces.html)

Natywny fullscreen, Split View, okna przypisane do wszystkich Spaces i pomocnicze okna systemowe nie są automatycznie przenoszone. Finder jest wyłączony z automatycznego przypisywania, ale jego rzeczywiste okna chronią zajęte biurka przed usunięciem. Odłączenie monitora fizycznie wymusza reakcję macOS; DeskPilot po stabilizacji dopasowuje zapisaną sesję do dostępnych ekranów, lecz nie może zagwarantować, że sam system nigdy nie przemieści okien.

## Diagnostyka i testy

```sh
lua tests/policy_test.lua
lua tests/manager_test.lua
lua tests/chrome_profiles_test.lua
lua tests/chrome_adapter_test.lua
lua tests/panel_model_test.lua
lua tests/births_test.lua
lua tests/follow_test.lua
lua tests/previews_test.lua
lua tests/panel_guard_test.lua
lua tests/panel_snapshot_test.lua
lua tests/wire_test.lua
lua tests/layout_test.lua
lua tests/display_policy_test.lua
lua tests/session_test.lua
lua tests/session_adapter_test.lua
native/bin/deskpilot-space-move --check
hs -c 'print(hs.inspect(DeskPilot.status()))'
hs -c 'print(hs.inspect(DeskPilot.workspaces()))'
hs -c 'print(hs.inspect(DeskPilot.rules()))'
hs -c 'print(hs.inspect(DeskPilot.chromeProfiles()))'
hs -c 'print(hs.inspect(DeskPilot.occupancy()))'
hs -c 'print(hs.inspect(DeskPilot.panelStatus()))'
hs -c 'print(hs.inspect(DeskPilot.sessionStatus()))'
```

DeskPilot działa tylko wtedy, gdy uruchomiony jest Hammerspoon. Zapisany stan „automat włączony” nie uruchamia zamkniętego Hammerspoon; w takim przypadku otwórz go z Aplikacji lub Spotlight. Start przy logowaniu można sprawdzić w ustawieniach Hammerspoon. Nowa sesja macOS może uruchomić przywracanie układu; ponowny reload w tej samej sesji nie rozstawia ponownie już obsłużonych aplikacji.

Poprawka z 22.09.2026 odróżnia zmianę rozmiaru Docka od zmiany monitorów. Dodanie ikony uruchamianego programu nie zeruje już wykrywania nowych okien. Stabilizacja układu jest potrzebna po zmianie zestawu monitorów lub ich pełnej geometrii. Poprawka zachowuje też informację o nowym oknie, kiedy macOS chwilowo nie podaje jego biurka. Przydział czeka na poprawny odczyt lokalizacji; pauza i ręczne przeniesienie nadal mają pierwszeństwo.

Odczyt wewnętrzny `--windows-stream` w helperze 1.3.2 przenosi JSON jako ASCII base64 z dokładną długością odpowiedzi. DeskPilot potwierdza odebranie całej odpowiedzi; dopiero wtedy helper kończy proces, a po potwierdzeniu powodzenia dekodowany jest JSON. Pozwala to uniknąć wyścigu odczytów Hammerspoon, który potrafił zwrócić fragmenty w innej kolejności. Kompletność danych wynika z długości wiadomości, a nie z umownego opóźnienia. Przerwana lub błędna odpowiedź nie odświeża zajętości biurek; po utracie aktualnych danych ruchy zależne od zajętości i sprzątanie czekają na poprawny odczyt. `DeskPilot.status()` pokazuje `metadataReads` i ewentualny `metadataError`.

`--check` nie przenosi okien; potwierdza tylko dostępność symboli. `--windows` od wersji 1.2.0 zwraca metadane i prostokąty okien, także spoza aktywnego biurka, bez tytułów i obrazów. Wersja 1.3.2 dodaje rzeczywiste identyfikatory ekranów i flagę `builtIn` do weryfikacji monitorów przed przywracaniem sesji. Diagnostyka zajętości ma znaczenie: `false` = potwierdzona pustka, `true` = okno lub nierozpoznany obiekt, brak wartości = brak wiarygodnego odczytu.

Zakres testów oraz dotychczasowa weryfikacja na macOS 26.6.2, Hammerspoon 1.1.1, dwóch zewnętrznych Dellach i ekranie laptopa (próby rzeczywiste 21–23.09.2026):

- **430 testów w 15 zestawach przechodzi poprawnie.** Regresje obejmują nowe okna, profile Chrome, ręczną kolejność, podglądy, protokół danych, sprzątanie oraz rozróżnienie pustki od niepełnego odczytu.
- Pamięć sesji ma osobne testy walidacji zapisu, doboru monitorów, listy aktywnych aplikacji, zachowania geometrii, jednokrotnego przywracania i pierwszeństwa ręcznych zmian. Testy adaptera używają kontrolowanych zastępników API; nie zastępują próby restartu na rzeczywistych monitorach.
- Kompilacja Objective-C z `-Wall -Wextra -Werror` i sprawdzenie składni Lua przeszły.
- Tymczasowe okno TextEdit rzeczywiście przeniesiono między Spaces/monitorami i z powrotem; sprawdzono docelowe ID zarówno w helperze, jak i w Hammerspoon.
- Przeniesienie przez manager potwierdziło się i zapisało UUID celu.
- Testowe biurko utworzono, potwierdzono jego pustkę, usunięto i potwierdzono zniknięcie.
- Dokumenty testowe zamknięto bez zapisu, testowe przypisanie usunięto.
- Po włączeniu automatyki kolejka zakończyła się bez błędów, żadne dwie automatyczne reguły różnych aplikacji nie wskazywały tego samego biurka.
- Próba pamięci sesji 23.09.2026 użyła własnej pustej aplikacji Cocoa i osobnego zapisu testowego: autostart raz, przeniesienie na ekran wbudowany, proporcjonalna ramka i brak ponowień po odtworzeniu koordynatora w tej samej sesji. Tworzenie nowego biurka sprawdzono osobno w tym samym przebiegu testów. Fokus i aktywne biurka na trzech ekranach pozostały identyczne.
- Fizyczne odłączanie monitorów, restart systemu i wszystkie możliwe aplikacje nie były testowane.

## Cofnięcie instalacji

Wstrzymaj DeskPilot. Przywróć pliki Lua, `deskpilot_panel.html` i helper `deskpilot-move` z jednej wybranej kopii do `~/.hammerspoon`, następnie wybierz Reload Config. Nie mieszaj plików z różnych wersji. Stary DeskPilot korzysta z zachowanych ustawień v1. Przed importem całego `settings.plist` zamknij Hammerspoon; import całej kopii cofa także inne jego ustawienia.

Przywrócenie kodu nie odtwarza usuniętych pustych Spaces ani wcześniejszego układu okien. Zajęte biurka nie są usuwane przez sprzątanie.
