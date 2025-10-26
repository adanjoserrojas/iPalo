##  **Inspiration**

Traditional white canes used by individuals with visual impairments rely on continuous tapping to detect obstacles such as steps, curbs, and drop-offs. While effective, they can be cumbersome and inconvenient to carry in public settings.

We wanted to build something that **feels the world before you touch it** — a modern walking aid powered by **LiDAR sensing** and **haptic force feedback**.

Using an **iPhone’s LiDAR sensor**, an ESP32 microcontroller, and **linear resonance actuator** haptic motors, we created a system that simulates the tactile feel of a cane tap.

---

##  **What It Does**

*iPalo* measures the distance between the phone and the ground or nearby obstacles.

The system continuously scans in the direction the device is pointed and provides directional haptic feedback on either side of the device based on the obstacle’s orientation relative to the user, delivered as firm sequences of “clicks.”

The closer the object, the **stronger and faster** the “tap” feedback, allowing users to feel terrain changes in real time.

To build on top of this, we added voice commands that allows the user to utilize an AI assistant to receive a description of their surroundings.

---

##  **How We Built It**

- **LiDAR Sensing:** Used **ARKit’s SceneDepth API** to get a continuous depth map from the iPhone’s LiDAR sensor.
- **Plane Estimation:** Implemented a multistep plane-fitting pipeline for stable directional haptic feedback. Outlier samples were removed using the RANSAC algorithm, followed by Total Least Squares plane fitting for accurate surface estimation. Exponential smoothing was applied to reduce jitter from rapid plane-direction changes.
- **Calculating Haptic Control:** Determined which haptic motor to activate using the normalized x-component of the plane’s normal vector in camera space, where the x-axis represents the plane's horizontal direction relative to the camera. The distance from the estimated plane was used to modulate the click frequency of the active motors.
- **Bluetooth Communication:** Used a low-power **BLE interface** between the iPhone and an **ESP32 microcontroller** to send haptic control signals.
- **Force Feedback:** Utilized **linear solenoid actuator** by sending waveform-ids to a DRV2506 LRA driver over an **I2C** bus.
- **AI Pipeline:** Developed an end-to-end system and API that allows users to receive spoken descriptions of their surroundings. Integrated Apple Speech-to-Text with a voice-command detection algorithm based on Levenshtein distance to trigger image capture. The captured image was processed through Google Gemini for scene description, and ElevenLabs provided real-time text-to-speech output.

---

##  **Challenges We Ran Into**

- Getting **accurate distance data** on varying surfaces.
- Developing an ergonomic device case.
- Fixed I2C addresses limited device multiplexing, requiring a redesign to use two haptic motors instead of three.
- Synchronizing **real-time BLE communication** with LiDAR frame updates.
- Ensuring stable, smooth plane estimates without jitter or sudden jumps.
- Tuning the **haptic feedback** so it felt like a natural “tap” rather than a buzz or vibration.
- Developing for iOS posed many unexpected challenges. Such as camera accessibility.
- Creating a **fast** pipeline with multiple generative AIs.

---

##  **What We Learned**

- How to stream and process LiDAR data efficiently on iOS.
- BLE communication timing and signal reliability for hardware feedback.
- The importance of **human-centered design** in assistive technology.

---

##  **What’s Next**

- Integrate **AI-based obstacle classification** using CoreML.
- Add **spatial audio cues** for richer feedback.
- Develop a **compact PCB + 3D printed housing** for the controller.
- Submit a prototype to accessibility-focused hackathons or accelerators.

---

##  **Tech Stack**

- **Swift / ARKit / CoreBluetooth** (iPhone app)
- **Arduino (C++)** for actuator control
- **ESP32 microcontroller**
- **Linear solenoid actuator**
- **Python (AI Pipeline)**
- **ElevenLabs API**
- **DigitalOcean Server Hosting**
