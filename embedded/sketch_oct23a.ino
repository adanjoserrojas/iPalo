#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <string>
#include <math.h>
#include <Adafruit_DRV2605.h>

#define SERVICE_UUID "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcdefab-1234-1234-1234-abcdefabcdef"

TwoWire I2C_1 = TwoWire(0);
TwoWire I2C_2 = TwoWire(1);

Adafruit_DRV2605 drv1;
Adafruit_DRV2605 drv2;

BLECharacteristic *pCharacteristic;

const unsigned long DELAY_UNIT = 50;

volatile float MAX_DELAYS = 10.0f;

volatile unsigned char l1_on = 0;
volatile unsigned char l2_on = 0;
volatile unsigned long tot_delay = 0;

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    Serial.println("Client connected");
  }
  void onDisconnect(BLEServer* s) override {
    Serial.println("Client disconnected, restarting advertising...");
    delay(50);                      // small pause helps on some stacks
    s->startAdvertising();          // or: BLEDevice::startAdvertising();
    l1_on = l2_on = 0;
  }
};

class MyCallbacks : public BLECharacteristicCallbacks {

  void onWrite(BLECharacteristic *pChar) override {

    String raw = pChar->getValue();
    if (raw.length() != sizeof(float) * 2)
      return;

    float scalars[2];
    memcpy(&scalars[0], raw.c_str(), sizeof(float) * 2);

    float angle = scalars[0];
    float dist = scalars[1];

    // no haptic if out of range
    if (dist > 1) {
      l1_on = 0;
      l2_on = 0;
      return;
    }

    // turn on LRAs that fall within angle range
    float third = 1.0f / 3.0f;
    l1_on = angle < third * 2;
    l2_on = angle >= third;
    
    // compute click speed based on distance
    tot_delay = ((unsigned long)(MAX_DELAYS * dist) + 1) * DELAY_UNIT;
  }

};

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Init bluetooth
  BLEDevice::init("ESP32_FloatReceiver");

  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCB());  
  BLEService *pService = pServer->createService(SERVICE_UUID);    
  
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID, 
    BLECharacteristic::PROPERTY_WRITE
  );

  pCharacteristic->setCallbacks(new MyCallbacks());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();

  // Init i2c
  I2C_1.begin(21, 22);
  I2C_2.begin(25, 26);
  
  if (!drv1.begin(&I2C_1)) {
    Serial.println("Driver 1 not found on I2C_1");
    while (1);
  }
  
  if (!drv2.begin(&I2C_2)) {
    Serial.println("Driver #2 not found on I2C_2");
    while (1);
  }

  drv1.useLRA();
  drv2.useLRA();

  // strong click
  drv1.setWaveform(0, 2);
  drv1.setWaveform(1, 0);
  drv2.setWaveform(0, 2);
  drv2.setWaveform(1, 0);

  // l1_on = 1; l2_on = 1;
  // l1_delay = 20;
  // l2_delay = 20;
  
  Serial.println("Both DRV2605L initialized!");
}

void loop() {

  if (l1_on) 
    drv1.go();

  if (l2_on) 
    drv2.go();

  delay(tot_delay);
}
