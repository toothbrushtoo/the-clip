#include <Wire.h>
#include "LSM6DS3.h"

LSM6DS3 imu(I2C_MODE, 0x6A);

void setup() {
  Serial.begin(115200);
  unsigned long start = millis();
  while (!Serial && millis() - start < 3000) {}

  if (imu.begin() != 0) {
    Serial.println("# IMU failed to start");
    while (true) {}
  }
  Serial.println("# IMU ok");
  Serial.println("ms,ax,ay,az,gx,gy,gz");
}

void loop() {
  Serial.print(millis());                 Serial.print(',');
  Serial.print(imu.readFloatAccelX(), 3); Serial.print(',');
  Serial.print(imu.readFloatAccelY(), 3); Serial.print(',');
  Serial.print(imu.readFloatAccelZ(), 3); Serial.print(',');
  Serial.print(imu.readFloatGyroX(), 1);  Serial.print(',');
  Serial.print(imu.readFloatGyroY(), 1);  Serial.print(',');
  Serial.println(imu.readFloatGyroZ(), 1);
  delay(10);
}
