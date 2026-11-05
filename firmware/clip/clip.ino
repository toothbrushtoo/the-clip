#include <Wire.h>
#include <bluefruit.h>
#include "LSM6DS3.h"

LSM6DS3 imu(I2C_MODE, 0x6A);

const uint8_t UUID_SERVICE[16] = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x01, 0x00, 0x1A, 0x7C};
const uint8_t UUID_REP[16]     = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x02, 0x00, 0x1A, 0x7C};
const uint8_t UUID_CMD[16]     = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x03, 0x00, 0x1A, 0x7C};
const uint8_t UUID_BATT[16]    = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x04, 0x00, 0x1A, 0x7C};
const uint8_t UUID_RSSI[16]    = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x05, 0x00, 0x1A, 0x7C};

BLEService        clipService(UUID_SERVICE);
BLECharacteristic repChar(UUID_REP);
BLECharacteristic cmdChar(UUID_CMD);
BLECharacteristic battChar(UUID_BATT);
BLECharacteristic rssiChar(UUID_RSSI);   // signal strength of the phone, as seen from the clip (int8 dBm)

const int   WINDOW = 600;
const float FAST = 0.08f;
const float SLOW = 0.0017f;
const float MIN_AMP = 2.5f;
const float FRAC = 0.3f;
const unsigned long MIN_GAP_MS = 500;

const unsigned long FIND_TIMEOUT_MS = 60000;
const unsigned long RSSI_PERIOD_MS = 200;

float band[WINDOW][3];
int bandHead = 0, bandCount = 0;
float fastAvg[3], slowAvg[3];
float axisV[3] = {1, 0, 0};
float envelope = 0;
bool armed = false;
bool inSet = false;
uint16_t reps = 0;
unsigned long lastRepMs = 0, prevRepMs = 0;
unsigned long samples = 0;

unsigned long lastSampleMs = 0;
unsigned long lastBatteryMs = 0;
unsigned long lastRssiMs = 0;
unsigned long greenUntil = 0;
int blueBlinks = 0;
unsigned long nextBlinkMs = 0;
bool finding = false;
unsigned long findUntilMs = 0;
uint16_t connHandle = BLE_CONN_HANDLE_INVALID;

void led(int pin, bool on) {
  digitalWrite(pin, on ? LOW : HIGH);
}

void resetReps() {
  reps = 0;
  armed = false;
  lastRepMs = 0;
  prevRepMs = 0;
}

void updateAxis() {
  if (bandCount < 50) return;
  float mean[3] = {0, 0, 0};
  for (int i = 0; i < bandCount; i++)
    for (int k = 0; k < 3; k++) mean[k] += band[i][k];
  for (int k = 0; k < 3; k++) mean[k] /= bandCount;

  float c[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
  for (int i = 0; i < bandCount; i++) {
    float d[3];
    for (int k = 0; k < 3; k++) d[k] = band[i][k] - mean[k];
    for (int r = 0; r < 3; r++)
      for (int s = 0; s < 3; s++) c[r][s] += d[r] * d[s];
  }

  float v[3] = {axisV[0], axisV[1], axisV[2]};
  for (int it = 0; it < 10; it++) {
    float w[3];
    for (int r = 0; r < 3; r++) w[r] = c[r][0] * v[0] + c[r][1] * v[1] + c[r][2] * v[2];
    float len = sqrtf(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
    if (len > 0) for (int k = 0; k < 3; k++) v[k] = w[k] / len;
  }
  if (v[0] * axisV[0] + v[1] * axisV[1] + v[2] * axisV[2] < 0)
    for (int k = 0; k < 3; k++) v[k] = -v[k];
  for (int k = 0; k < 3; k++) axisV[k] = v[k];
}

bool pushSample(float ax, float ay, float az, unsigned long now) {
  float a[3] = {ax, ay, az};
  if (samples == 0)
    for (int k = 0; k < 3; k++) { fastAvg[k] = a[k]; slowAvg[k] = a[k]; }

  float b[3];
  for (int k = 0; k < 3; k++) {
    fastAvg[k] += (a[k] - fastAvg[k]) * FAST;
    slowAvg[k] += (a[k] - slowAvg[k]) * SLOW;
    b[k] = fastAvg[k] - slowAvg[k];
    band[bandHead][k] = b[k];
  }
  bandHead = (bandHead + 1) % WINDOW;
  if (bandCount < WINDOW) bandCount++;
  samples++;
  if (samples % 100 == 0) updateAxis();

  float p = b[0] * axisV[0] + b[1] * axisV[1] + b[2] * axisV[2];
  envelope = max(fabsf(p), envelope * 0.998f);
  float thr = max(MIN_AMP, FRAC * envelope);

  if (!inSet) { armed = false; return false; }

  if (p > thr && !armed) {
    armed = true;
  } else if (p < -thr && armed && now - lastRepMs > MIN_GAP_MS) {
    armed = false;
    prevRepMs = lastRepMs;
    lastRepMs = now;
    reps++;
    return true;
  }
  return false;
}

void notifyReps() {
  uint16_t tempo = (prevRepMs > 0) ? (uint16_t)min(lastRepMs - prevRepMs, 65535UL) : 0;
  uint16_t amp = (uint16_t)min(envelope * 100.0f, 65535.0f);
  uint8_t buf[8] = {
    (uint8_t)(reps & 0xFF), (uint8_t)(reps >> 8),
    (uint8_t)(tempo & 0xFF), (uint8_t)(tempo >> 8),
    (uint8_t)(amp & 0xFF), (uint8_t)(amp >> 8),
    0, 0
  };
  repChar.write(buf, 8);
  if (Bluefruit.connected()) repChar.notify(buf, 8);
}

uint8_t readBatteryPercent() {
  int raw = analogRead(PIN_VBAT);
  float v = raw * (3.6f / 4096.0f) * (1510.0f / 510.0f);
  float pct = (v - 3.3f) / (4.2f - 3.3f) * 100.0f;
  return (uint8_t)constrain(pct, 0.0f, 100.0f);
}

// Find mode: all three LEDs strobe white until the phone says stop, or for a minute.
// Separately, whenever the app subscribes to rssiChar, the clip reports how strongly it
// hears the phone five times a second, so the app can average both ends of the link.
void startFind() {
  finding = true;
  findUntilMs = millis() + FIND_TIMEOUT_MS;
  Serial.println("find on");
}

void stopFind() {
  if (finding) Serial.println("find off");
  finding = false;
}

void onCmd(uint16_t conn, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  if (len < 1) return;
  switch (data[0]) {
    case 0x01: inSet = true; resetReps(); notifyReps(); Serial.println("set start"); break;
    case 0x02: inSet = false; Serial.println("set end"); break;
    case 0x03: startFind(); break;
    case 0x04: stopFind(); break;
  }
}

void onConnect(uint16_t conn) {
  Serial.println("connected");
  connHandle = conn;
  blueBlinks = 4;
  nextBlinkMs = millis() + 150;
  BLEConnection* c = Bluefruit.Connection(conn);
  if (c) c->monitorRssi();
}

void onDisconnect(uint16_t conn, uint8_t reason) {
  Serial.println("disconnected");
  connHandle = BLE_CONN_HANDLE_INVALID;
  inSet = false;
  stopFind();
}

void setupBLE() {
  Bluefruit.begin();
  Bluefruit.setTxPower(8);
  Bluefruit.setName("Clip");
  Bluefruit.Periph.setConnectCallback(onConnect);
  Bluefruit.Periph.setDisconnectCallback(onDisconnect);

  clipService.begin();

  repChar.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  repChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  repChar.setFixedLen(8);
  repChar.begin();

  cmdChar.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  cmdChar.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  cmdChar.setFixedLen(1);
  cmdChar.setWriteCallback(onCmd);
  cmdChar.begin();

  battChar.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  battChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  battChar.setFixedLen(1);
  battChar.begin();
  battChar.write8(readBatteryPercent());

  rssiChar.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  rssiChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  rssiChar.setFixedLen(1);
  rssiChar.begin();
  rssiChar.write8(0);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(clipService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void setup() {
  Serial.begin(115200);
  unsigned long t0 = millis();
  while (!Serial && millis() - t0 < 2000) {}

  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  led(LED_RED, false); led(LED_GREEN, false); led(LED_BLUE, false);

  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);
  analogReadResolution(12);

  if (imu.begin() != 0) {
    Serial.println("IMU failed to start");
    while (true) { led(LED_RED, true); delay(200); led(LED_RED, false); delay(200); }
  }

  setupBLE();
  Serial.println("Clip ready");
  lastSampleMs = millis();
}

void loop() {
  unsigned long now = millis();

  if (now - lastSampleMs > 100) lastSampleMs = now;
  if (now - lastSampleMs >= 10) {
    lastSampleMs += 10;
    const float G = 9.81f;
    bool rep = pushSample(imu.readFloatAccelX() * G, imu.readFloatAccelY() * G, imu.readFloatAccelZ() * G, now);
    if (rep) {
      notifyReps();
      greenUntil = now + 80;
      Serial.print("rep ");
      Serial.println(reps);
    }
  }

  if (finding && now >= findUntilMs) stopFind();

  // double white flash every 600 ms while finding
  bool flash = false;
  if (finding) {
    unsigned long phase = now % 600;
    flash = phase < 60 || (phase >= 150 && phase < 210);
  }

  if (blueBlinks > 0 && now >= nextBlinkMs) {
    blueBlinks--;
    nextBlinkMs = now + 150;
  }
  bool blueOn = blueBlinks > 0 && blueBlinks % 2 == 0;

  led(LED_RED, flash);
  led(LED_GREEN, flash || now < greenUntil);
  led(LED_BLUE, flash || blueOn);

  if (connHandle != BLE_CONN_HANDLE_INVALID && rssiChar.notifyEnabled() && now - lastRssiMs >= RSSI_PERIOD_MS) {
    lastRssiMs = now;
    BLEConnection* c = Bluefruit.Connection(connHandle);
    if (c && c->connected()) {
      int8_t r = c->getRssi();
      rssiChar.write8((uint8_t)r);
      rssiChar.notify8((uint8_t)r);
    }
  }

  if (now - lastBatteryMs > 30000) {
    lastBatteryMs = now;
    uint8_t pct = readBatteryPercent();
    battChar.write8(pct);
    if (Bluefruit.connected()) battChar.notify8(pct);
  }
}
