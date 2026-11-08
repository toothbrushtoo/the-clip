Main clip firmware.

## Sleep

With no phone connected and no USB power, the clip turns itself off (nRF52840 System OFF, a few
µA) after 5 minutes lying still, or after 20 minutes with no phone even if it keeps moving. The
motion sensor stays on in low-power mode (26 Hz, accelerometer only) and wakes the clip when it's
picked up: anything over 0.156 g for two samples, so a breeze or a bump on the table doesn't count.
After a wake on motion it goes back to sleep after 30 s unless it's really moved or a phone
connects, so a false wake costs seconds of battery, not minutes. Before sleeping it checks the
motion sensor's interrupt line is quiet; if not, it stays awake and tries again later instead of
waking straight back up. One short blue blink means it's going to sleep.

To test sleep on USB: open the serial monitor, type `s` and Enter. The port disappears; move the
clip and it comes back, printing `woke up on motion`.
Plugging in USB also wakes it. It never sleeps during a set, while connected, or on USB. The app
can put it to sleep straight away from Settings (command 0x08).
