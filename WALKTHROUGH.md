# Stress Calibration Walkthrough

This walkthrough guides you through verifying the new week-long stress calibration feature.

## Changes
- **HealthKitManager**: Added ability to fetch HRV at specific timestamps.
- **StressNotOnMyWatchManager**: Added logic to manage calibration state, store readings, and calculate a personalized threshold.
- **StressNotOnMyWatchView**: Added "Calibration Mode" UI with "Report Stress" button.

## Prerequisites for Running in Xcode

Since this is a standalone Swift file, you must set up an Xcode project first:

1.  **Create Project**: Open Xcode -> Create New Project -> watchOS -> App.
2.  **Paste Code**: Copy the contents of `stress_watch.swift` into the main file (usually `ContentView.swift` or `App.swift`).
3.  **Add Capabilities**:
    - Click on the Project target -> "Signing & Capabilities".
    - Click "+ Capability" -> Add **HealthKit**.
4.  **Update Info.plist**:
    - Add `Privacy - Health Share Usage Description` (Value: "We need HRV data to detect stress.")
    - Add `Privacy - Health Update Usage Description` (Value: "We need to save calibration data.")
5.  **Simulator Data**:
    - The Simulator does not have real HRV data.
    - You must open the **Health** app on the simulated iPhone (paired with the watch) and manually add "Heart Rate Variability" data points to test the fetching logic.

## Verification Steps

### 1. Start Calibration & Survey
1.  Launch the app on your Simulator or Apple Watch.
2.  Scroll to the bottom of the main view.
3.  Tap the **"Start Calibration"** button.
4.  **Verify**:
    - A new sheet appears titled "Tell us about you".
    - It contains an "Age" text field and a "Gender" picker.
    - It explicitly states "These fields are optional".

### 2. Complete or Skip Survey
1.  **Option A (Skip)**: Tap the "Skip" button.
    - Verify the sheet closes and "CALIBRATION MODE" starts.
2.  **Option B (Fill)**: Enter an age (e.g., "30") and select a gender. Tap "Start Calibration".
    - Verify the sheet closes and "CALIBRATION MODE" starts.

### 3. Report Stress
1.  Tap the **"I FEEL STRESSED"** button.
2.  **Verify**:
    - The status text momentarily changes to "Recorded".
    - In the debug console (if running from Xcode), you should see a log: `Reported Stress. HRV: ...`.
    - Note: If using the Simulator, you may need to simulate HRV data in the Health app or use a simulator feature to ensure data exists.

### 3. Simulate Week Completion (Optional/Advanced)
To verify the end of calibration without waiting a week:
1.  Stop the app.
2.  In `StressNotOnMyWatchManager.swift`, temporarily modify `checkCalibrationStatus` or manually set the `calibrationStartDate` in `UserDefaults` to 8 days ago.
3.  Relaunch the app.
4.  **Verify**:
    - The "CALIBRATION MODE" section is gone.
    - The console logs "Calibration Complete. New Threshold: ...".
    - The app now uses your personalized threshold for stress detection.

## Next Steps
- Run the app on a physical device for a week to get a real personalized threshold.
