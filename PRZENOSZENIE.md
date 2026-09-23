# DeskPilot na nowym Macu

DeskPilot działa wewnątrz **Hammerspoon**. Przenosisz jego kod, a opcjonalnie także pamięć układu. Ta instrukcja nie wymaga DMG ani osobnej aplikacji DeskPilot.

Najprostsza ścieżka to świeża instalacja i ponowne rozpoznanie aplikacji oraz profili Chrome. Dotychczasowy Mac może dalej działać bez zmian.

## 1. Przygotuj nowy Mac

1. Pobierz Hammerspoon z [oficjalnej instrukcji instalacji](https://www.hammerspoon.org/go/) i umieść go w **Aplikacjach**. Jeśli na nowym Macu Hammerspoon już działa, zakończ go przed instalowaniem plików.
2. Pobierz kod z tego repozytorium, np. **Code → Download ZIP**, i rozpakuj. Prywatne repozytorium wymaga zalogowania na uprawnione konto GitHub. Zachowaj cały katalog projektu; nie kopiuj katalogu `backups/` ze starej instalacji.
3. Zainstaluj używane aplikacje i przygotuj profile Chrome. Dane Chrome przenosisz oddzielnie, jego własnymi mechanizmami lub migracją macOS. Repozytorium DeskPilot nie zawiera kart, historii, haseł ani danych kont.
4. W ustawieniach **Biurko i Dock → Mission Control** włącz **Monitory mają osobne przestrzenie** i wyłącz **Automatycznie porządkuj przestrzenie według ostatniego użycia**. Jeśli macOS wymaga ponownego logowania, wykonaj je przed dalszymi krokami.

Skrypt kompiluje helper z minimalną wersją **macOS 13**. To dolna granica kompilacji, nie gwarancja działania na każdym późniejszym systemie. Obecną wersję sprawdzano na **macOS 26.6.2 i Hammerspoon 1.1.1**. Mechanizmy Spaces zależą od wersji macOS; inny system i Mac wymagają krótkiego sprawdzenia po instalacji.

## 2. Zbuduj helper i zainstaluj kod

Otwórz Terminal. Jeśli nie masz Apple Command Line Tools, uruchom poniższe polecenie i poczekaj na zakończenie instalacji. [Dokumentacja Apple](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/)

```sh
xcode-select --install
```

Przejdź do rozpakowanego katalogu zawierającego `install.sh` oraz `native/build.sh`. W poniższym poleceniu zastąp przykładową ścieżkę własną:

```sh
cd "/ścieżka/do/katalogu/DeskPilot"
sh native/build.sh
native/bin/deskpilot-space-move --check
```

`--check` nie przesuwa okien; sprawdza dostępność potrzebnych mechanizmów. Oczekiwany wynik JSON zawiera `"ok": true` oraz `"status": "available"`. To nie jest jeszcze potwierdzenie rzeczywistego ruchu okien. Jeśli kompilacja się nie uda albo helper zwróci błąd, np. `"status": "unavailable"`, zatrzymaj instalację i sprawdź zgodność systemu.

Budowanie na nowym Macu tworzy helper dla jego środowiska. Dotychczasowy lokalny binarny helper był **arm64**, więc nie należy kopiować go na Maca z Intelem. Projekt nie dostarcza obecnie jednego przetestowanego pliku universal dla obu architektur. Do uruchomienia już zbudowanego helpera Command Line Tools nie są potrzebne.

**Instalator zastępuje `~/.hammerspoon/init.lua`.** Jeżeli masz w nim inne automatyzacje, zachowaj je i po instalacji połącz dotychczasową konfigurację z wpisami `require("hs.ipc")` i `require("deskpilot")` z nowego pliku. Nie nadpisuj własnego kodu bez sprawdzenia kopii.

Przy zamkniętym Hammerspoon uruchom:

```sh
/usr/bin/defaults write org.hammerspoon.Hammerspoon deskpilot.paused.v2 -bool true
bash install.sh
```

Pierwsze polecenie wymusza **start w pauzie**, również jeśli Asystent migracji przeniósł stare ustawienia. Instalator kopiuje kod i zbudowany helper do `~/.hammerspoon`; tworzy też prywatną kopię poprzednich plików i ustawień w `~/.hammerspoon/backups/deskpilot-DATA-PID`. Nie przenoś tej kopii do GitHuba.

## 3. Nadaj zgody i sprawdź panel

Uruchom Hammerspoon. W **Ustawienia systemowe → Prywatność i ochrona** nadaj mu dostęp do **Dostępności**. Włączając podglądy w panelu, zezwól również na **Nagrywanie ekranu**; nazwa tej sekcji może obejmować też dźwięk systemowy. Jeśli macOS poprosi o zgodę na **Monitorowanie wprowadzania**, nadaj ją Hammerspoon, aby mógł wykrywać interakcję użytkownika. Po zmianach zastosuj żądane przez system ponowne uruchomienie aplikacji. Uprawnień nie przenosi się samym kopiowaniem plików.

1. Kliknij **Desk:** albo naciśnij **Ctrl+Alt+Space**. Sprawdź widoczne monitory i biurka; automatyka powinna być w pauzie.
2. Jeśli chcesz przenieść poprzednią pamięć układu, wykonaj teraz opcjonalny krok 4.
3. Kliknij **Wznów**. Otwórz zwykłe okno aplikacji i sprawdź przydzielenie biurka. Następnie sprawdź po jednym oknie każdego profilu Chrome. Jedna aplikacja ma jedno biurko; Chrome ma jedno biurko na profil.
4. Ręczne przypisanie poprawisz przez **Ctrl+Shift+numer** albo panel. Awaryjna pauza to **Ctrl+Alt+Cmd+P**.

Po sprawdzeniu włącz **Launch Hammerspoon at login** w jego ustawieniach, jeśli ma startować wraz z macOS. Wznowienie automatyki pozwala także uruchamiać aplikacje zapisane jako aktywne w przeniesionym układzie. Podczas stabilizacji oraz pierwszej minuty po nowym logowaniu podążanie za nowymi oknami może być wyciszone.

## 4. Opcjonalnie: przenieś samą pamięć układu

Ten krok jest zbędny przy świeżej konfiguracji. Samo `~/.hammerspoon` zawiera kod; pamięć sesji jest osobno w [ustawieniach Hammerspoon](https://www.hammerspoon.org/docs/hs.settings.html), pod kluczem `deskpilot.sessionLayouts.v1`. Nie importuj całego `org.hammerspoon.Hammerspoon.plist`, bo zastąpiłby też ustawienia innych automatyzacji.

**Domyślnie import pomija Chrome.** `Default` i `Profile N` oznaczają lokalne katalogi. Po ręcznym założeniu profili na drugim Macu ten sam numer może należeć do innego profilu. Jeśli chcesz także przenieść jego przypisania, w każdym profilu sprawdź **Ścieżkę profilu** na stronie `chrome://version`; porównaj końcowy katalog oraz faktyczną tożsamość profilu na obu Macach. Sama zgodna nazwa wyświetlana nie wystarcza. Przy niepewnym mapowaniu pozostaw domyślne pomijanie Chrome i skonfiguruj jego przypisania na nowo. DeskPilot nie ma obecnie kreatora mapowania profili między komputerami.

Poniżej jest ręczna procedura przez konsolę Hammerspoon, nie przycisk eksportu w DeskPilot. Przenosi ostatni zapisany układ i listę aktywnych aplikacji. Nie przenosi samych programów, dokumentów, danych aplikacji ani kart Chrome, a także dawnych reguł według tytułów, własnych nazw biurek i ustawień innych funkcji Hammerspoon.

**Na starym Macu:** wybierz **Pamięć układu i start programów → Zapisz układ teraz** i zaczekaj na potwierdzenie. Zapis wymaga włączonej automatyki i stabilnego układu. Następnie wybierz **Wstrzymaj automatykę**. Otwórz **Hammerspoon → Console** i wklej cały poniższy blok jako jedno polecenie, od `do` do `end`:

```lua
do
  local s = hs.settings.get("deskpilot.sessionLayouts.v1")
  assert(type(s) == "table" and s.version == 1 and type(s.layouts) == "table",
    "Brak zapisanego układu")
  local path = os.getenv("HOME") .. "/Desktop/DeskPilot-settings-layout.json"
  local data = {version = 1, layouts = s.layouts, runs = {}}
  assert(hs.json.write(data, path, true, false),
    "Nie zapisano pliku: sprawdź, czy już istnieje")
end
```

Plik `DeskPilot-settings-layout.json` pojawi się na Biurku, poza repozytorium. W Terminalu ogranicz dostęp do swojego konta:

```sh
chmod 600 "$HOME/Desktop/DeskPilot-settings-layout.json"
```

Zawiera prywatne informacje o aplikacjach, profilach i układzie oraz hashe tytułów okien. Przenieś go prywatnie na Biurko nowego Maca, np. AirDropem, i tam również wykonaj powyższe `chmod 600`. **Nie dodawaj go do repozytorium.** Dane Chrome, `Local State`, cookies i historia pozostają poza tym plikiem. Możesz wznowić automatykę starego Maca po eksporcie.

**Na nowym Macu:** upewnij się, że panel DeskPilot jest w pauzie. Import zastąpi dotychczasową pamięć sesji nowej instalacji. W konsoli Hammerspoon wklej cały blok jako jedno polecenie. Pozostaw `includeChrome = false`; zmień je na `true` tylko po potwierdzeniu zgodności katalogów i tożsamości wszystkich przenoszonych profili:

```lua
do
  local includeChrome = false
  DeskPilot.pause()
  local path = os.getenv("HOME") .. "/Desktop/DeskPilot-settings-layout.json"
  local s = assert(hs.json.read(path), "Nie można odczytać pliku")
  assert(type(s) == "table" and s.version == 1 and type(s.layouts) == "table",
    "Niepoprawny format")
  local layouts = {}
  for signature, layout in pairs(s.layouts) do
    local valid = require("deskpilot_layout").validateLayout(layout)
    assert(valid and valid.signature == signature, "Niepoprawny układ")
    if not includeChrome then
      for key, group in pairs(valid.groups) do
        if group.bundleID == "com.google.Chrome" then valid.groups[key] = nil end
      end
      for i = #valid.activeKeys, 1, -1 do
        if not valid.groups[valid.activeKeys[i]] then table.remove(valid.activeKeys, i) end
      end
    end
    layouts[signature] = valid
  end
  hs.settings.set("deskpilot.sessionLayouts.v1",
    {version = 1, layouts = layouts, runs = {}})
end
```

Wybierz **Reload Config** w menu Hammerspoon. Panel pozostanie w pauzie. Sprawdź monitory i dopiero wtedy kliknij **Wznów**. Nie przenosimy identyfikatorów poprzedniego uruchomienia: nowy Mac rozpoczyna własny cykl przywracania.

UUID biurek i ekranu laptopa na nowym Macu mogą być inne. DeskPilot dobierze aktualne monitory według ról aplikacji i dostępnych biurek; nie odtworzy dosłownie dawnych identyfikatorów ani pustych luk. Układ oraz rozmiary mogą wymagać korekty. Chrome odpowiada za przywrócenie własnych kart, a pozostałe aplikacje za swoje dokumenty.

Po sprawdzeniu importu usuń prywatny plik JSON z obu Biurek albo zachowaj go w swoim bezpiecznym archiwum.

## Gdy coś nie działa

- **Brak Desk:** sprawdź, czy Hammerspoon działa, wykonaj **Reload Config** i odczytaj pierwszy błąd w jego konsoli.
- **Brak ruchu:** sprawdź pauzę, Dostępność, ustawienie osobnych Spaces oraz wynik `~/.hammerspoon/deskpilot-move --check` w Terminalu. Nieznany lub niepełny odczyt celowo zatrzymuje operacje.
- **Brak podglądów:** włącz je w panelu i sprawdź zgodę na nagrywanie ekranu. Niektóre okna nie udostępniają obrazu.
- **Brak profilu Chrome:** otwórz jego zwykłe okno i sprawdź unikalną nazwę profilu; okna incognito, gościa i nierozpoznane nie są automatycznie przypisywane.

Dalsze zasady i ograniczenia: [README](README.md), [instrukcja HTML](Instrukcja-DeskPilot.html), [bezpieczeństwo](BEZPIECZENSTWO.md).
