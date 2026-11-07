Main clip firmware.

## Sleep

With no phone connected and no USB power, the clip turns itself off (nRF52840 System OFF, a few
µA) after 5 minutes lying still, or after 20 minutes with no phone even if it keeps moving. The
motion sensor stays on in low-power mode (26 Hz, accelerometer only) and wakes the clip when it's
picked up: anything over 0.125 g for two samples, so a breeze or a bump on the table doesn't count.
Plugging in USB also wakes it. It never sleeps during a set, while connected, or on USB. The app
can put it to sleep straight away from Settings (command 0x08).
