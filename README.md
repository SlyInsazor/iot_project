# Sistem IoT pentru Monitorizarea Inteligentă a Posturii la Birou

Acest proiect reprezintă un sistem inteligent de tip Internet of Things (IoT) conceput pentru a monitoriza, analiza și corecta postura utilizatorului la birou, combătând totodată sedentarismul. Sistemul funcționează complet autonom, măsurând distanța fizică, contorizând timpul petrecut pe scaun și avertizând utilizatorul vizual, acustic și digital prin notificări Bluetooth Low Energy (BLE).

---

## Cuprins
1. [Introducere și Arhitectura Generală](#capitolul-1-introducere-și-arhitectura-generală)
2. [Arhitectura Hardware și Componente](#capitolul-2-arhitectura-hardware-și-componente)
3. [Arhitectura Software (Firmware ESP32)](#capitolul-3-arhitectura-software-firmware-esp32)
4. [Aplicația Mobilă (Flutter / Android)](#capitolul-4-aplicația-mobilă-flutter--android)
5. [Structura Proiectului și Gestiunea Codului Sursă](#capitolul-5-structura-proiectului-și-gestiunea-codului-sursă)

---

## CAPITOLUL 1. Introducere și Arhitectura Generală

### 1.1. Scopul Proiectului
Proiectul are ca scop crearea unui asistent ergonomic digital. Prin intermediul senzorilor ultrasonici, sistemul detectează dacă utilizatorul stă aplecat prea aproape de monitor sau dacă a depășit timpul recomandat de lucru continuu fără pauză, oferind un feedback multi-senzorial.

### 1.2. Arhitectura Sistemului
Sistemul este împărțit în două noduri principale:
1. **Nodul de Achiziție și Procesare (Hardware):** Construit în jurul microcontrolerului ESP32, citește datele de la senzorii ultrasonici, filtrează zgomotul, calculează timpii, afișează informațiile pe un ecran OLED și expune un server Bluetooth BLE.
2. **Nodul de Afișare și Analiză (Software):** O aplicație mobilă dezvoltată în framework-ul Flutter (Android), care se conectează la ESP32, preia datele în timp real, desenează grafice analitice (Line Chart, Pie Chart, Bar Chart) și gestionează alertele de tip „Heads-Up Notification”.

---

## CAPITOLUL 2. Arhitectura Hardware și Componente

### 2.1. Microcontrolerul ESP32 (DOIT DevKit V1)
Platforma centrală este modulul ESP-WROOM-32, ales pentru puterea de calcul superioară și conectivitatea duală.
* **CPU:** Xtensa® Dual-Core 32-bit LX6, tactat la 240 MHz, capabil de 600 MIPS.
* **Memorie:** 520 KB SRAM și 4 MB Flash externă (partiționată custom via `huge_app.csv` pentru a găzdui stiva BLE).
* **Oscilator intern:** Cristal de 40 MHz, asigurând precizia funcțiilor de temporizare.

### 2.2. Senzorii Ultrasonici (HC-SR04)
Sistemul utilizează module HC-SR04 pentru a măsura proximitatea:
* Senzorul emite un tren de 8 impulsuri ultrasonice la frecvența de 40 kHz. Microcontrolerul trimite un semnal HIGH de 10 microsecunde pe pinul TRIG și măsoară timpul de întoarcere pe pinul ECHO.
* Viteza sunetului în aer este de aprox. 343 m/s. Formula utilizată: `Distanța = (Durata * 0.034) / 2`.

### 2.3. Modulul de Afișare OLED (SSD1306)
* **Tip ecran:** OLED, rezoluție 128x64 pixeli (fără backlight, consum redus).
* **Protocol:** I2C (Inter-Integrated Circuit) pe adresa `0x3C`, folosind magistrala SDA/SCL.

### 2.4. Actuatoare Acustice (Buzzer)
Două buzzere active oferă feedback ritmic: un ton rapid pentru postură greșită și un ton lent/calm pentru pauză, controlate non-blocant prin cod.

### 2.5. Maparea Pinilor (Pinout)
Pentru a evita pinii de boot (strapping pins), am utilizat următoarea configurație:

| Componentă | Pin ESP32 (GPIO) | Rol în Circuit |
| :--- | :--- | :--- |
| **Senzor 1 (HC-SR04)** | 18 (TRIG), 19 (ECHO) | Emite și recepționează pulsul pentru detectarea posturii. |
| **Senzor 2 (Secundar)** | 26 (TRIG), 27 (ECHO) | Emite și recepționează pulsul de verificare. |
| **Ecran OLED SSD1306**| 21 (SDA), 22 (SCL) | Magistrala de comunicație I2C (Date și Ceas). |
| **Buzzer 1 (Postură)** | 25 | Semnal ieșire alarmă proximitate incorectă. |
| **Buzzer 2 (Pauză)** | 32 | Semnal ieșire alarmă timp sedentar depășit. |

---

## CAPITOLUL 3. Arhitectura Software (Firmware ESP32)

### 3.1. Procesarea Semnalelor (Filtrul Median)
Pentru a combate impreciziile senzorului ultrasonic (ex: rezultate aberante din cauza reflexiilor pe haine), codul implementează un **Filtru Median cu Fereastră Glisantă (Sliding Window)**.
Se menține un buffer cu ultimele 5 măsurători. La fiecare citire, valoarea nouă înlocuiește valoarea cea mai veche. Buffer-ul este sortat crescător (Bubble Sort), iar algoritmul extrage **valoarea din mijloc**, eliminând instantaneu anomaliile (zgomotul).

### 3.2. Mașina de Stări și Temporizarea Non-Blocantă
Întregul cod evită instrucțiunea `delay()`, bazându-se pe `millis()`.
* **Prag Prezență:** < 80 cm.
* **Prag Postură Proastă:** < 50 cm.
* **Temporizator Postură:** 15 secunde (se resetează instant dacă distanța se corectează).
* **Temporizator Stat Jos (Sedentarism):** 50 secunde.

### 3.3. Stiva Bluetooth Low Energy (BLE)
ESP32 este configurat ca un server GATT:
* **Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
* **Characteristic UUID:** `beb5483e-36e1-4688-b7f5-ea07361b26a8`
Pachetul formatat (ex: `Dist: 45cm | ASEZAT (30s) | ATENTIE!\n`) este trimis automat către aplicația mobilă de 4 ori pe secundă prin sistemul de Notificări BLE.

---

## CAPITOLUL 4. Aplicația Mobilă (Flutter / Android)

### 4.1. Framework și Dependințe
Aplicația este dezvoltată în **Flutter (Dart)** și utilizează pachete specializate: `flutter_blue_plus` (BLE), `fl_chart` (grafice) și `flutter_local_notifications` (alerte sistem).

### 4.2. Procesarea Datelor și Regex
Datele transmise prin Bluetooth sunt parsate live folosind Expresii Regulate (Regex):
* `RegExp(r'Dist: (\d+)cm')` extrage distanța live.
* `RegExp(r'ASEZAT \((\d+)s\)')` extrage secundele continue pentru a calcula timpii și alertele.

### 4.3. Interfața Grafică (Dashboard UI)
1. **Line Chart:** Afișează istoric real-time al proximității utilizatorului (ultimele 20 de eșantioane).
2. **Pie Chart (Analiză Calitativă):** Împarte timpul total așezat în procente: Postură Corectă (Verde) vs. Postură Greșită (Roșu). Convertește secundele în `h m s`.
3. **Bar Chart (Analiză Cantitativă):** Compară dinamic timpul petrecut Așezat vs. Ridicat, afișând secundele transformate plutind direct deasupra barelor.

### 4.4. Mecanismul de Notificare Heads-Up
Sistemul combate limitările de fundal din Android 13+ utilizând un canal de notificări cu parametrul `Importance.max`. Când aplicația detectează un timp de șezut ≥ 50 secunde, se declanșează o alertă prioritară (vibrație + banner pe ecran), care se oprește doar când utilizatorul se ridică efectiv de pe scaun.

---

## CAPITOLUL 5. Structura Proiectului și Gestiunea Codului Sursă

### 5.1. Paradigma Monorepo
Pentru a asigura o sincronizare perfectă între versiunea de firmware (hardware) și aplicația mobilă (software), proiectul folosește o arhitectură **Monorepo**. Ambele module rezidă sub același proiect Git, garantând o integrare continuă.

### 5.2. Arborescența Fișierelor (Directory Tree)

```text
IOT/                                   
│
├── ESP32/                             <-- Nodul Hardware (PlatformIO)
│   ├── src/                           
│   │   └── main.cpp                   <-- Logica principală ESP32 (Filtru, BLE, OLED)
│   ├── platformio.ini                 <-- Configurări memorie (huge_app.csv) și librării
│   └── .gitignore                     
│
└── aplicatie_postura/                 <-- Nodul Software (Flutter)
    ├── android/app/src/main/
    │   ├── AndroidManifest.xml        <-- Permisiuni (BLE, Locație, Notificări)
    │   └── build.gradle.kts           <-- Kotlin DSL, CoreLibraryDesugaring
    ├── lib/
    │   └── main.dart                  <-- Logica UI, Parsare Regex, Bluetooth Client
    ├── pubspec.yaml                   <-- Gestionarul de pachete (Dependencies)
    └── .gitignore
