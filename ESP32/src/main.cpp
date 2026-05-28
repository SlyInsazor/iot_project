#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// --- LIBRARII PENTRU BLUETOOTH BLE ---
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

// --- PINI ---
const int trigPin1 = 18; 
const int echoPin1 = 19;
const int trigPin2 = 26; 
const int echoPin2 = 27;

const int buzzerPostura = 25; 
const int buzzerPauza = 32;   

// --- SETARI SI PRAGURI ---
const int DIST_PREZENTA = 80; 
const int DIST_POSTURA = 50;  

const unsigned long TIMP_POSTURA_PROASTA = 15000; // 15s postura
const unsigned long TIMP_MAX_STAT = 50000;        // 50s asezat
const unsigned long TIMP_MAX_PAUZA = 10000;       // 10s pauza

// --- VARIABILE DE STARE ---
unsigned long timpInceputStat = 0;
unsigned long timpInceputPauza = 0;
unsigned long timpPosturaProasta = 0;

bool estePeScaun = false;
int distS1 = 0;
int distS2 = 0;
unsigned long ultimaCitireSenzori = 0;

bool alarmaPostura = false;
bool alarmaRidicare = false;
bool alarmaAsezare = false;

// --- VARIABILE PENTRU FILTRU MEDIAN ---
const int NR_MASURATORI = 5; 
int istoricS1[NR_MASURATORI] = {999, 999, 999, 999, 999}; 
int indexS1 = 0;

// --- VARIABILE BLE ---
BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// UUID-uri care se potrivesc EXACT cu aplicatia Flutter
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
    };
    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
    }
};

// --- FUNCTIE DE MASURARE ---
int masoaraDistanta(int trigPin, int echoPin) {
  digitalWrite(trigPin, LOW); delayMicroseconds(2);
  digitalWrite(trigPin, HIGH); delayMicroseconds(10);
  digitalWrite(trigPin, LOW);
  
  long durata = pulseIn(echoPin, HIGH, 30000); 
  int dist = durata * 0.034 / 2;
  
  if(dist == 0 || dist > 400) return 999; 
  return dist;
}

// --- FUNCTIE PENTRU FILTRUL MEDIAN ---
int filtreazaZgomotS1(int valoareNoua) {
  istoricS1[indexS1] = valoareNoua;
  indexS1 = (indexS1 + 1) % NR_MASURATORI;

  int copie[NR_MASURATORI];
  for(int i = 0; i < NR_MASURATORI; i++) copie[i] = istoricS1[i];

  for(int i = 0; i < NR_MASURATORI - 1; i++) {
    for(int j = 0; j < NR_MASURATORI - i - 1; j++) {
      if(copie[j] > copie[j+1]) {
        int temp = copie[j];
        copie[j] = copie[j+1];
        copie[j+1] = temp;
      }
    }
  }
  return copie[NR_MASURATORI / 2];
}

void setup() {
  Serial.begin(115200);
  
  pinMode(trigPin1, OUTPUT); pinMode(echoPin1, INPUT);
  pinMode(trigPin2, OUTPUT); pinMode(echoPin2, INPUT);
  pinMode(buzzerPostura, OUTPUT); pinMode(buzzerPauza, OUTPUT);
  digitalWrite(buzzerPostura, LOW); digitalWrite(buzzerPauza, LOW);

  // --- INITIALIZARE ECRAN ---
  if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println(F("EROARE OLED"));
  } else {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(10, 20);
    display.println(F("Sistem Initializat"));
    display.setCursor(10, 40);
    display.println(F("Pornire Bluetooth..."));
    display.display();
  }

  // --- INITIALIZARE BLUETOOTH BLE ---
  BLEDevice::init("ESP32_Postura"); 
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_NOTIFY 
                    );

  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);
  BLEDevice::startAdvertising();
  
  Serial.println("Bluetooth pornit! Cauta 'ESP32_Postura' in aplicatie.");
}

void loop() {
  unsigned long timpCurent = millis();

  // CITIM SENZORII DE 4 ORI PE SECUNDA
  if (timpCurent - ultimaCitireSenzori > 250) {
    ultimaCitireSenzori = timpCurent;
    
    int distS1_brut = masoaraDistanta(trigPin1, echoPin1);
    distS1 = filtreazaZgomotS1(distS1_brut);
    
    // --- LOGICA DE PREZENTA ---
    if (distS1 < DIST_PREZENTA) {
      if (!estePeScaun) {
        estePeScaun = true;
        timpInceputStat = timpCurent; 
      }
      timpInceputPauza = 0; 
    } else {
      if (estePeScaun) {
        estePeScaun = false;
        timpInceputPauza = timpCurent; 
      }
      timpInceputStat = 0; 
    }

    // --- LOGICA DE POSTURA ---
    bool conditiePostura = false;
    if (distS1 < DIST_POSTURA) conditiePostura = true;

    if (conditiePostura && estePeScaun) {
      if (timpPosturaProasta == 0) timpPosturaProasta = timpCurent;
      if (timpCurent - timpPosturaProasta > TIMP_POSTURA_PROASTA) {
        alarmaPostura = true;
      }
    } else {
      timpPosturaProasta = 0;
      alarmaPostura = false;
    }

    // --- LOGICA ALARME TIMP ---
    if (estePeScaun && (timpCurent - timpInceputStat > TIMP_MAX_STAT)) alarmaRidicare = true;
    else alarmaRidicare = false;

    if (!estePeScaun && timpInceputPauza > 0 && (timpCurent - timpInceputPauza > TIMP_MAX_PAUZA)) alarmaAsezare = true;
    else alarmaAsezare = false;

    // --- ACTUALIZARE ECRAN OLED ---
    display.clearDisplay();
    display.setCursor(0, 0);
    display.print(F("BLE: "));
    if (deviceConnected) display.println(F("Conectat Telefon")); else display.println(F("Asteptare..."));

    display.setCursor(0, 15);
    display.print(F("Postura: "));
    if(alarmaPostura) display.println(F("GRESITA!"));
    else if (conditiePostura) display.println(F("Atentie..."));
    else display.println(F("Corecta"));
    
    display.setCursor(0, 35);
    if (estePeScaun) {
      display.print(F("Stat: ")); display.print((timpCurent - timpInceputStat)/1000); display.println(F(" s"));
      if (alarmaRidicare) { display.setCursor(0, 50); display.println(F("RIDICA-TE!")); }
    } else {
      display.print(F("Pauza: ")); display.print((timpCurent - timpInceputPauza)/1000); display.println(F(" s"));
      if (alarmaAsezare) { display.setCursor(0, 50); display.println(F("LA BIROU!")); }
    }
    display.display();

    // ==========================================
    // --- TRANSMITERE DATE CATRE FLUTTER ---
    // ==========================================
    if (deviceConnected) {
      // Trebuie sa respectam formatul pentru Regex-ul din Flutter:
      // r'Dist: (\d+)cm'   si   r'ASEZAT \((\d+)s\)'
      
      String mesajBLE = "Dist: " + String(distS1) + "cm | ";
      
      if (estePeScaun) {
        mesajBLE += "ASEZAT (" + String((timpCurent - timpInceputStat)/1000) + "s) | ";
      } else {
        mesajBLE += "PLECAT (" + String((timpCurent - timpInceputPauza)/1000) + "s) | ";
      }

      if (alarmaPostura || alarmaRidicare) {
        mesajBLE += "POSTURA PROASTA!";
      } 
      else if (conditiePostura) {
        mesajBLE += "ATENTIE!";
      } 
      else {
        mesajBLE += "OK";
      }

      mesajBLE += "\n"; 

      pCharacteristic->setValue(mesajBLE.c_str());
      pCharacteristic->notify();
    }
  }

  // --- RECONECTARE BLUETOOTH (Auto-Healing) ---
  if (!deviceConnected && oldDeviceConnected) {
      delay(500); 
      pServer->startAdvertising(); 
      Serial.println("Bluetooth restartat. Astept conexiuni...");
      oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
      oldDeviceConnected = deviceConnected;
      Serial.println("Telefon conectat!");
  }

  // --- LOGICA BUZZERELOR ---
  if (alarmaPostura) {
    if ((timpCurent / 100) % 2 == 0) digitalWrite(buzzerPostura, HIGH);
    else digitalWrite(buzzerPostura, LOW);
  } else {
    digitalWrite(buzzerPostura, LOW);
  }

  if (alarmaRidicare) {
    if (timpCurent % 2000 < 500) digitalWrite(buzzerPauza, HIGH);
    else digitalWrite(buzzerPauza, LOW);
  } else if (alarmaAsezare) {
    int ciclu = timpCurent % 1500;
    if (ciclu < 150 || (ciclu > 300 && ciclu < 450)) digitalWrite(buzzerPauza, HIGH);
    else digitalWrite(buzzerPauza, LOW);
  } else {
    digitalWrite(buzzerPauza, LOW);
  }
}