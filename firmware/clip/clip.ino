#include <Wire.h>
#include <bluefruit.h>
#include "LSM6DS3.h"

LSM6DS3 imu(I2C_MODE, 0x6A);

const uint8_t UUID_SERVICE[16] = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x01, 0x00, 0x1A, 0x7C};
const uint8_t UUID_REP[16]     = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x02, 0x00, 0x1A, 0x7C};
const uint8_t UUID_CMD[16]     = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x03, 0x00, 0x1A, 0x7C};
const uint8_t UUID_BATT[16]    = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x04, 0x00, 0x1A, 0x7C};
const uint8_t UUID_RSSI[16]    = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x05, 0x00, 0x1A, 0x7C};
const uint8_t UUID_STREAM[16]  = {0x10, 0x4A, 0x0D, 0x1C, 0x8E, 0x2B, 0x3F, 0x9A, 0x2C, 0x4D, 0x6B, 0x5E, 0x06, 0x00, 0x1A, 0x7C};

BLEService        clipService(UUID_SERVICE);
BLECharacteristic repChar(UUID_REP);
BLECharacteristic cmdChar(UUID_CMD);
BLECharacteristic battChar(UUID_BATT);
BLECharacteristic rssiChar(UUID_RSSI);   // signal strength of the phone, as seen from the clip (int8 dBm)
BLECharacteristic streamChar(UUID_STREAM); // raw motion, 6 samples per packet, while the app subscribes

// Stream packet: [seq][count] then count x (ax, ay, az in cm/s^2, gx, gy, gz in 0.1 deg/s) as int16 LE.
const int STREAM_SAMPLES = 6;
uint8_t streamPkt[2 + STREAM_SAMPLES * 12];
uint8_t streamCount = 0;
uint8_t streamSeq = 0;

const int   WINDOW = 600;
const float FAST = 0.08f;
const float SLOW = 0.0017f;
const float MIN_AMP = 2.5f;
const float FRAC = 0.3f;
const unsigned long MIN_GAP_MS = 500;

const unsigned long FIND_TIMEOUT_MS = 60000;

// Sleep: with no phone connected and no USB power, the clip goes into System OFF (a few µA) after
// lying still for IDLE_STILL_MS, or after NO_PHONE_MS with no phone even if it keeps moving (in a
// bag). The motion sensor stays on in low-power mode and wakes it when it's picked up. Plugging in
// USB wakes it too. Small wobbles (a breeze, a bump on the table) are below both thresholds.
const unsigned long IDLE_STILL_MS = 5UL * 60UL * 1000UL;
const unsigned long NO_PHONE_MS = 20UL * 60UL * 1000UL;
const float STILL_ACCEL = 0.6f;     // m/s^2: short-term change in acceleration that counts as moving
const uint8_t WAKE_THS = 4;         // wake threshold in 31.25 mg steps (4 = 0.125 g)
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

float idleFast[3], idleSlow[3];
bool idleInit = false;
unsigned long lastMotionMs = 0;
unsigned long lastPhoneMs = 0;
bool sleepRequested = false;

// One burst read gets gyro then accel (registers 0x22..0x2D) so both are from the same instant.
void readIMU(float* a, float* g) {
  uint8_t raw[12];
  imu.readRegisterRegion(raw, LSM6DS3_ACC_GYRO_OUTX_L_G, 12);
  for (int k = 0; k < 3; k++) {
    int16_t gr = (int16_t)(raw[2 * k] | (raw[2 * k + 1] << 8));
    int16_t ar = (int16_t)(raw[6 + 2 * k] | (raw[7 + 2 * k] << 8));
    g[k] = imu.calcGyro(gr);
    a[k] = imu.calcAccel(ar) * 9.81f;
  }
}

void streamSample(const float* a, const float* g) {
  int16_t* p = (int16_t*)(streamPkt + 2 + streamCount * 12);
  for (int k = 0; k < 3; k++) {
    p[k] = (int16_t)constrain(a[k] * 100.0f, -32767.0f, 32767.0f);
    p[3 + k] = (int16_t)constrain(g[k] * 10.0f, -32767.0f, 32767.0f);
  }
  streamCount++;
  if (streamCount == STREAM_SAMPLES) {
    streamPkt[0] = streamSeq++;
    streamPkt[1] = streamCount;
    streamChar.notify(streamPkt, 2 + streamCount * 12);
    streamCount = 0;
  }
}

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
    case 0x07: greenUntil = millis() + 80; break;   // the app counted a rep: flash green
    case 0x08: sleepRequested = true; break;         // the app asked the clip to sleep
  }
}

bool usbPowered() {
  uint32_t status = 0;
  sd_power_usbregstatus_get(&status);
  return status & POWER_USBREGSTATUS_VBUSDETECT_Msk;
}

// Tracks whether the clip is being moved. A 0.1 s average against a 2 s average of acceleration:
// gentle drift or a tiny wobble keeps them together, a real movement pulls them apart.
void trackMotion(const float* a, unsigned long now) {
  if (!idleInit) {
    for (int k = 0; k < 3; k++) { idleFast[k] = a[k]; idleSlow[k] = a[k]; }
    idleInit = true;
    lastMotionMs = now;
    return;
  }
  float d2 = 0;
  for (int k = 0; k < 3; k++) {
    idleFast[k] += (a[k] - idleFast[k]) * 0.1f;
    idleSlow[k] += (a[k] - idleSlow[k]) * 0.005f;
    float d = idleFast[k] - idleSlow[k];
    d2 += d * d;
  }
  if (d2 > STILL_ACCEL * STILL_ACCEL) lastMotionMs = now;
}

// Motion sensor into low-power wake-up mode: accel only at 26 Hz, gyro off, a latched interrupt on
// INT1 when the high-pass filtered acceleration goes over WAKE_THS for 2 samples in a row.
void armWakeOnMotion() {
  imu.writeRegister(LSM6DS3_ACC_GYRO_CTRL2_G, 0x00);
  imu.writeRegister(LSM6DS3_ACC_GYRO_CTRL1_XL, 0x20);
  imu.writeRegister(LSM6DS3_ACC_GYRO_CTRL6_G, 0x10);
  imu.writeRegister(LSM6DS3_ACC_GYRO_WAKE_UP_THS, WAKE_THS & 0x3F);
  imu.writeRegister(LSM6DS3_ACC_GYRO_WAKE_UP_DUR, 0x20);
  imu.writeRegister(LSM6DS3_ACC_GYRO_TAP_CFG1, 0x91);
  imu.writeRegister(LSM6DS3_ACC_GYRO_MD1_CFG, 0x20);
  delay(100);
  uint8_t src;
  imu.readRegister(&src, LSM6DS3_ACC_GYRO_WAKE_UP_SRC);
}

// Undo armWakeOnMotion after waking (the motion sensor kept its settings while the chip was off).
void disarmWakeOnMotion() {
  imu.writeRegister(LSM6DS3_ACC_GYRO_MD1_CFG, 0x00);
  imu.writeRegister(LSM6DS3_ACC_GYRO_TAP_CFG1, 0x00);
  imu.writeRegister(LSM6DS3_ACC_GYRO_WAKE_UP_THS, 0x00);
  imu.writeRegister(LSM6DS3_ACC_GYRO_WAKE_UP_DUR, 0x00);
  imu.writeRegister(LSM6DS3_ACC_GYRO_CTRL6_G, 0x00);
  uint8_t src;
  imu.readRegister(&src, LSM6DS3_ACC_GYRO_WAKE_UP_SRC);
}

void goToSleep() {
  Serial.println("sleeping");
  Serial.flush();
  finding = false;
  for (int i = 0; i < 2; i++) {
    led(LED_BLUE, true); delay(60);
    led(LED_BLUE, false); delay(120);
  }
  led(LED_RED, false); led(LED_GREEN, false); led(LED_BLUE, false);
  digitalWrite(VBAT_ENABLE, HIGH);   // stop the battery divider leaking while off
  armWakeOnMotion();
  systemOff(PIN_LSM6DS3TR_C_INT1, HIGH);
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
  lastPhoneMs = millis();
  connHandle = BLE_CONN_HANDLE_INVALID;
  inSet = false;
  stopFind();
}

void setupBLE() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
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

  streamChar.setProperties(CHR_PROPS_NOTIFY);
  streamChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  streamChar.setMaxLen(sizeof(streamPkt));
  streamChar.begin();

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

  imu.settings.accelRange = 4;
  imu.settings.gyroRange = 1000;
  if (imu.begin() != 0) {
    Serial.println("IMU failed to start");
    while (true) { led(LED_RED, true); delay(200); led(LED_RED, false); delay(200); }
  }
  disarmWakeOnMotion();
  if (NRF_POWER->RESETREAS & POWER_RESETREAS_OFF_Msk) Serial.println("woke up on motion");
  if (NRF_POWER->RESETREAS & POWER_RESETREAS_VBUS_Msk) Serial.println("woke up on USB");
  NRF_POWER->RESETREAS = 0xFFFFFFFF;

  setupBLE();
  Serial.println("Clip ready");
  lastSampleMs = millis();
  lastMotionMs = lastSampleMs;
  lastPhoneMs = lastSampleMs;
}

void loop() {
  unsigned long now = millis();

  if (now - lastSampleMs > 100) lastSampleMs = now;
  if (now - lastSampleMs >= 10) {
    lastSampleMs += 10;
    float a[3], g[3];
    readIMU(a, g);
    trackMotion(a, now);
    bool streaming = connHandle != BLE_CONN_HANDLE_INVALID && streamChar.notifyEnabled();
    if (streaming) streamSample(a, g); else streamCount = 0;
    bool rep = pushSample(a[0], a[1], a[2], now);
    if (rep) {
      notifyReps();
      if (!streaming) greenUntil = now + 80;   // while streaming, the app decides when a rep happened
      Serial.print("rep ");
      Serial.println(reps);
    }
  }

  if (finding && now >= findUntilMs) stopFind();

  bool phone = connHandle != BLE_CONN_HANDLE_INVALID;
  if (phone) lastPhoneMs = now;
  if (sleepRequested) {
    sleepRequested = false;
    if (phone) Bluefruit.disconnect(connHandle);
    delay(200);
    goToSleep();
  }
  if (!phone && !inSet && !usbPowered() &&
      (now - lastMotionMs > IDLE_STILL_MS || now - lastPhoneMs > NO_PHONE_MS)) {
    goToSleep();
  }

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
