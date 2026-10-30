import sys, time, serial, os

port = sys.argv[1] if len(sys.argv) > 1 else "COM5"
os.makedirs("hardware/data", exist_ok=True)
name = time.strftime("hardware/data/imu_%Y%m%d_%H%M%S.csv")

with serial.Serial(port, 115200, timeout=1) as ser, open(name, "w") as f:
    print("recording to", name, "- Ctrl+C to stop")
    try:
        while True:
            line = ser.readline().decode(errors="ignore").strip()
            if not line or line.startswith("#"):
                if line: print(line)
                continue
            f.write(line + "\n")
    except KeyboardInterrupt:
        print("saved", name)
