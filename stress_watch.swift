import SwiftUI // Imports the SwiftUI framework for building the user interface.
import HealthKit // Imports the HealthKit framework for accessing health data like HRV.
import Combine // Imports the Combine framework for handling asynchronous events and data streams.
import WatchKit // Imports the WatchKit framework, required for watchOS-specific features like haptics.

// MARK: - 1. HealthKit & Manager Logic (Adapted for Watch)

/**
 * HealthKitManager: Handles all direct interaction with the Apple HealthKit framework.
 * This class abstracts away the complexity of data querying and authorization.
 */
class HealthKitManager { // Defines the HealthKitManager class to manage HealthKit operations.
    // --------------------------------------------------------------------------------
    // HealthKit Setup
    // --------------------------------------------------------------------------------
    private let healthStore = HKHealthStore() // Creates an instance of HKHealthStore to access the HealthKit database.
    // Defines the specific health data type we are interested in: Heart Rate Variability (SDNN)
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)! // Identifies the HRV (SDNN) quantity type.
    
    /**
     * Request Authorization: Prompts the user for permission to read HRV data.
     */
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) { // Function to request HealthKit authorization with a completion handler.
        guard HKHealthStore.isHealthDataAvailable() else { // Checks if HealthKit data is available on the device.
            completion(false, NSError(domain: "HealthKitError", code: 100, userInfo: [NSLocalizedDescriptionKey: "Health data is not available."])) // Returns an error if HealthKit is not available.
            return // Exits the function.
        }
        let typesToRead: Set<HKQuantityType> = [hrvType] // Creates a set containing the HRV type to request read access for.
        
        healthStore.requestAuthorization(toShare: [], read: typesToRead) { success, error in // Requests authorization to read the specified types.
            DispatchQueue.main.async { // Switches to the main thread to call the completion handler.
                completion(success, error) // Calls the completion handler with the result.
            }
        }
    }
    
    /**
     * Fetch Latest HRV Reading: Reads the single most recent HRV data point.
     */
    func fetchLatestHRV(completion: @escaping (Double?, Error?) -> Void) { // Function to fetch the latest HRV reading.
        let now = Date() // Gets the current date and time.
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)! // Calculates the date and time for 24 hours ago.
        let predicate = HKQuery.predicateForSamples(withStart: oneDayAgo, end: now, options: .strictEndDate) // Creates a predicate to query samples within the last 24 hours.
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false) // Creates a sort descriptor to sort samples by end date in descending order.
        
        let query = HKSampleQuery(sampleType: hrvType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { // Creates a sample query for HRV data.
            (_, samples, error) in // Closure to handle the query results.
            
            DispatchQueue.main.async { // Switches to the main thread to process results.
                guard let sample = samples?.first as? HKQuantitySample, error == nil else { // Checks if a sample was returned and there was no error.
                    completion(nil, error) // Calls completion with nil and the error if the check fails.
                    return // Exits the closure.
                }
                
                let hrvInMS = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli)) // Converts the HRV value to milliseconds.
                completion(hrvInMS, nil) // Calls completion with the HRV value.
            }
        }
        healthStore.execute(query) // Executes the query on the health store.
    }
}

// MARK: - 2. Application Logic and State Management

/**
 * PacerPhase: Enum to define the states of the breathing animation.
 */
enum PacerPhase: String { // Defines an enum for the breathing pacer phases, backed by String.
    case inhale = "IN" // Case for the inhale phase.
    case hold = "HOLD" // Case for the hold phase.
    case exhale = "OUT" // Case for the exhale phase.
    case pause = "READY" // Case for the pause/ready phase.
}

/**
 * PulsePeaceManager: The central state controller (`ObservableObject`).
 * **Modified for Watch Haptics.**
 */
class PulsePeaceManager: ObservableObject { // Defines the PulsePeaceManager class, conforming to ObservableObject for SwiftUI updates.
    
    // --- Constants ---
    private let THRESHOLD: Double = 50.0 // Constant defining the HRV threshold for stress detection.
    private let SESSION_DURATION = 60 // Constant defining the duration of a breathing session in seconds.
    private let healthKitManager = HealthKitManager() // Instance of HealthKitManager to handle HealthKit operations.
    
    // --- Published Properties (These update the SwiftUI View) ---
    @Published var hrvValue: Double? = nil // Published property for the current HRV value, optional.
    @Published var statusText: String = "Initializing..." // Published property for the status text displayed to the user.
    @Published var isStressed: Bool = false // Published property indicating if stress is detected.
    @Published var isIntervening: Bool = false // Published property indicating if a breathing session is active.
    @Published var sessionTimeLeft: Int = 0 // Published property for the remaining time in the breathing session.
    @Published var messageBoxContent: String? = nil // Published property for messages to display (e.g., session results).
    
    // Pacer Animation State 
    @Published var pacerPhase: PacerPhase = .pause // Published property for the current phase of the pacer.
    @Published var pacerScale: CGFloat = 1.0 // Published property for the scale of the pacer animation.
    @Published var pacerColor: Color = Color.purple.opacity(0.6) // Published property for the color of the pacer animation.
    
    // --- Internal Timers and Variables ---
    private var dataFetchTimer: Timer? // Timer for periodically fetching HRV data.
    private var sessionTimer: Timer? // Timer for the breathing session countdown.
    private var preSessionHRV: Double = 0 // Variable to store the HRV value before the session starts.
    private var lowHRVStartTime: Date? = nil // Variable to track when HRV first dropped below threshold.
    private var isAuthorized = false // Boolean to track if HealthKit authorization has been granted.

    init() { // Initializer for the class.
        requestHealthKitAuthorization() // Requests HealthKit authorization upon initialization.
    }
    
    /**
     * Helper function to play a soft, system-level HAPTIC notification (Watch preferred).
     * Replaces the AudioToolbox beep used in the iOS version.
     */
    private func triggerHapticNotification() { // Function to trigger a haptic notification.
        // Use a simple notification haptic to alert the user on the wrist.
        WKInterfaceDevice.current().play(.notification) // Plays a notification haptic on the Apple Watch.
    }

    // MARK: - HealthKit Integration
    
    private func requestHealthKitAuthorization() { // Function to request HealthKit authorization.
        healthKitManager.requestAuthorization { [weak self] success, error in // Calls the manager's request method.
            guard let self = self else { return } // Safely unwraps self.
            if success { // Checks if authorization was successful.
                self.isAuthorized = true // Sets the authorized flag to true.
                self.statusText = "Authorized. Fetching data..." // Updates the status text.
                self.startDataStream() // Starts fetching data.
            } else { // If authorization failed.
                self.statusText = "Denied. Check Settings." // Updates status text to inform the user.
                print("Authorization Error: \(error?.localizedDescription ?? "Unknown")") // Prints the error to the console.
            }
        }
    }
    
    private func startDataStream() { // Function to start the data fetching timer.
        dataFetchTimer?.invalidate() // Invalidates any existing data fetch timer.
        // Schedule new timer
        dataFetchTimer = Timer.scheduledTimer(withInterval: 0.5, repeats: true) { [weak self] _ in // Schedules a new timer to fire every 0.5 seconds.
            self?.fetchLiveHRVData() // Calls the function to fetch live HRV data.
        }
        dataFetchTimer?.fire() // Fires the timer immediately.
    }
    
    private func fetchLiveHRVData() { // Function to fetch the latest HRV data.
        if isIntervening { return } // Returns immediately if a session is currently active.
        
        healthKitManager.fetchLatestHRV { [weak self] hrv, error in // Calls the manager to fetch the latest HRV.
            guard let self = self else { return } // Safely unwraps self.
            if let hrv = hrv { // Checks if an HRV value was returned.
                self.hrvValue = hrv // Updates the HRV value property.
                self.updateDetectionStatus() // Updates the stress detection status based on the new value.
            } else if error != nil { // Checks if an error occurred.
                self.hrvValue = nil // Sets the HRV value to nil.
                self.statusText = "Data Error" // Updates the status text to indicate an error.
            } else { // If no data and no error (e.g., no samples yet).
                self.statusText = "Awaiting HRV Data..." // Updates status text to indicate waiting.
            }
        }
    }
    
    // MARK: - Detection Logic
    
    private func updateDetectionStatus() { // Function to update the stress detection status.
        guard let hrv = hrvValue else { return } // Returns if there is no HRV value.
        
        // **STRESS DETECTION RULE**
        if hrv < THRESHOLD && !isIntervening { // Checks if HRV is below threshold and not intervening.
            if lowHRVStartTime == nil { // Checks if the low HRV timer has not started.
                lowHRVStartTime = Date() // Starts the timer by recording the current time.
            } else if let startTime = lowHRVStartTime, Date().timeIntervalSince(startTime) >= 120 { // Checks if 2 minutes have passed since low HRV started.
                if !isStressed { // Checks if not already in stressed state.
                    // STRESS DETECTED (First time trigger)
                    isStressed = true // Sets the stressed state to true.
                    statusText = "STRESSED" // Updates the status text to "STRESSED".
                    messageBoxContent = nil // Clears any message box content.
                    
                    // NEW: Trigger Haptic Feedback on the Watch
                    self.triggerHapticNotification() // Triggers a haptic notification.
                    
                    print("STRESS DETECTED! HRV: \(hrv)ms") // Prints a log message.
                }
            }
        } else if hrv >= THRESHOLD && !isIntervening { // Checks if HRV is above threshold and not intervening.
            // CALM STATE
            lowHRVStartTime = nil // Resets the low HRV timer.
            isStressed = false // Sets the stressed state to false.
            statusText = "Calm" // Updates the status text to "Calm".
        }
    }
    
    // MARK: - Intervention Logic (4-7-8 Pacer)
    
    func startPeaceSession() { // Function to start the breathing session.
        guard !isIntervening, let hrv = hrvValue else { return } // Checks if not already intervening and HRV value exists.
        
        preSessionHRV = hrv // Stores the current HRV as the pre-session value.
        isIntervening = true // Sets the intervening flag to true.
        isStressed = false // Resets the stressed flag.
        sessionTimeLeft = SESSION_DURATION // Sets the session timer.
        statusText = "Breathing..." // Updates the status text.
        messageBoxContent = nil // Clears the message box.
        
        dataFetchTimer?.invalidate() // Stops the data fetch timer.
        
        startPacer() // Starts the pacer animation.
        
        sessionTimer?.invalidate() // Invalidates any existing session timer.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in // Schedules a timer to decrement the session time every second.
            self?.sessionTimeLeft -= 1 // Decrements the remaining time.
            if self?.sessionTimeLeft ?? 0 <= 0 { // Checks if time has run out.
                self?.endPeaceSession() // Ends the session.
            }
        }
        sessionTimer?.fire() // Fires the timer immediately.
    }
    
    private func startPacer() { // Function to manage the pacer animation phases.
        // Define the phases of the 4-7-8 breathing technique (Duration, Scale, Color, Haptic Type).
        let phases: [(PacerPhase, Double, CGFloat, Color, WKHapticType)] = [ // Array of tuples defining each phase.
            // 4 seconds IN (Grow) - Gentle haptic at the start
            (.inhale, 4.0, 1.5, Color.green, .start), // Inhale phase definition.
            // 7 seconds HOLD (Large) - No haptic
            (.hold,   7.0, 1.5, Color.yellow, .none), // Hold phase definition.
            // 8 seconds OUT (Shrink) - Gentle haptic at the start
            (.exhale, 8.0, 1.0, Color.blue, .start), // Exhale phase definition.
            // 1 second PAUSE (Small) - No haptic
            (.pause,  1.0, 1.0, Color.purple.opacity(0.6), .none) // Pause phase definition.
        ]
        
        var totalElapsed: Double = 0 // Variable to track elapsed time in the cycle.
        var phaseIndex = 0 // Variable to track the current phase index.
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in // Timer to update the pacer every 0.1 seconds.
            guard let self = self, self.isIntervening else { // Checks if self exists and intervention is active.
                timer.invalidate() // Stops the timer if not.
                return // Exits.
            }
            
            let currentPhase = phases[phaseIndex % phases.count] // Gets the current phase based on the index.
            let duration = currentPhase.1 // Gets the duration of the current phase.
            let hapticType = currentPhase.4 // Gets the haptic type for the current phase.
            
            // Trigger haptic at the start of a new phase (Inhale/Exhale)
            if totalElapsed == 0.0 && hapticType != .none { // Checks if it's the start of the phase and haptic is required.
                WKInterfaceDevice.current().play(hapticType) // Plays the haptic.
            }
            
            withAnimation(.easeInOut(duration: duration)) { // Animate the changes.
                self.pacerPhase = currentPhase.0 // Updates the pacer phase.
                self.pacerScale = currentPhase.2 // Updates the pacer scale.
                self.pacerColor = currentPhase.3 // Updates the pacer color.
            }
            
            totalElapsed += 0.1 // Increments the elapsed time.
            
            if totalElapsed >= duration { // Checks if the phase duration has passed.
                totalElapsed = 0 // Resets elapsed time.
                phaseIndex += 1 // Moves to the next phase.
            }
        }
    }
    
    // MARK: - Session End & Efficacy
    
    private func endPeaceSession() { // Function to handle the end of a session.
        sessionTimer?.invalidate() // Stops the session timer.
        isIntervening = false // Sets intervening to false.
        sessionTimeLeft = 0 // Resets session time.
        pacerScale = 1.0 // Resets pacer scale.
        pacerColor = Color.purple.opacity(0.6) // Resets pacer color.
        
        // Trigger a success haptic to indicate session completion
        WKInterfaceDevice.current().play(.success) // Plays a success haptic.
        
        startDataStream() // Restarts the data stream.
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in // Delays the efficacy calculation by 1 second.
            guard let self = self, let postSessionHRV = self.hrvValue else { return } // Safely unwraps self and HRV.
            
            let improvement = self.preSessionHRV > 0 // Checks if pre-session HRV was valid.
                ? ((postSessionHRV - self.preSessionHRV) / self.preSessionHRV) * 100 // Calculates percentage improvement.
                : 0.0 // Default to 0 if invalid.
            
            self.messageBoxContent = String( // Formats the result string.
                format: "Post-HRV: %.0fms. Impr: %.1f%%.", // Format string.
                postSessionHRV, improvement // Values to format.
            )
            self.updateDetectionStatus() // Updates detection status.
        }
    }
}

// MARK: - 3. SwiftUI Views (Watch UI Structure)

/**
 * PulsePeaceWatchView: The simplified SwiftUI view for Apple Watch.
 */
struct PulsePeaceWatchView: View { // Defines the main SwiftUI view for the watch app.
    
    @StateObject var manager = PulsePeaceManager() // Creates a state object for the manager.
    
    var body: some View { // Defines the body of the view.
        // Use a ScrollView as the main container for adaptability on small screens.
        ScrollView { // Wraps content in a ScrollView.
            VStack(spacing: 8) { // Arranges children vertically with spacing.
                
                // MARK: Status (Top of screen)
                statusPill // Displays the status pill view.
                
                // MARK: Pacer or HRV Display
                if manager.isIntervening { // Checks if a session is active.
                    // Pacer View during Intervention
                    pacerView // Displays the pacer view.
                    
                    // Countdown
                    Text("\(manager.sessionTimeLeft)s") // Displays the remaining time.
                        .font(.title3).bold().monospaced() // Sets the font style.
                        .foregroundColor(.purple) // Sets the text color.
                } else { // If not intervening.
                    // HRV Value when monitoring
                    VStack(spacing: 2) { // Vertical stack for HRV display.
                        Text(manager.hrvValue == nil ? "--" : String(format: "%.0f", manager.hrvValue!)) // Displays HRV value or placeholder.
                            .font(.system(size: 40, weight: .heavy, design: .rounded)) // Sets a large font.
                            .foregroundColor(manager.isStressed ? .red : .green) // Sets color based on stress status.
                        Text("HRV (ms)").font(.caption2).foregroundColor(.gray) // Displays the unit label.
                    }
                }
                
                // MARK: Action Button
                // The button spans the width of the screen on Watch.
                Button(action: manager.startPeaceSession) { // Button to start the session.
                    Text(manager.isIntervening ? "Session Running" : "START PEACE") // Sets button text based on state.
                        .font(.headline) // Sets font.
                        .padding(.vertical, 5) // Adds vertical padding.
                }
                .buttonStyle(.borderedProminent) // Sets the button style.
                .tint(manager.isStressed ? .purple : .gray) // Sets the tint color based on stress.
                .disabled(!manager.isStressed || manager.isIntervening) // Disables button if not stressed or already running.
                
                // MARK: Message Box (Efficacy Result)
                if let message = manager.messageBoxContent { // Checks if there is a message to display.
                    // Smaller font for efficacy results on Watch.
                    Text(message) // Displays the message.
                        .font(.caption2) // Sets the font.
                        .padding(5) // Adds padding.
                        .frame(maxWidth: .infinity) // Makes it fill the width.
                        .background(Color.green.opacity(0.2)) // Sets background color.
                        .foregroundColor(.green) // Sets text color.
                        .cornerRadius(8) // Rounds the corners.
                }
            }
            .padding(.vertical) // Adds vertical padding to the VStack.
        }
        // When the view is first displayed.
        .onAppear { // Modifier called when the view appears.
            manager.requestHealthKitAuthorization() // Requests authorization.
        }
    }
    
    // Helper View: The Status Pill (Simplified for Watch)
    private var statusPill: some View { // Defines the status pill subview.
        let bgColor: Color // Variable for background color.
        let textColor: Color // Variable for text color.
        
        if manager.isIntervening { // Checks if intervening.
            bgColor = .purple.opacity(0.5) // Sets background to purple.
            textColor = .white // Sets text to white.
        } else if manager.isStressed { // Checks if stressed.
            bgColor = .red // Sets background to red.
            textColor = .white // Sets text to white.
        } else if manager.hrvValue == nil { // Checks if no data.
            bgColor = .yellow.opacity(0.8) // Sets background to yellow.
            textColor = .black // Sets text to black.
        } else { // Default (Calm).
            bgColor = .green // Sets background to green.
            textColor = .white // Sets text to white.
        }
        
        return Text(manager.statusText) // Returns the text view.
            .font(.caption).bold() // Sets font.
            .padding(.horizontal, 10) // Adds horizontal padding.
            .padding(.vertical, 4) // Adds vertical padding.
            .background(bgColor) // Sets background.
            .foregroundColor(textColor) // Sets text color.
            .cornerRadius(.infinity) // Makes it pill-shaped.
    }
    
    // Helper View: The Animated Pacer Circle (Smaller for Watch)
    private var pacerView: some View { // Defines the pacer view subview.
        ZStack { // Stack for layering.
            Circle() // Draws a circle.
                .fill(manager.pacerColor) // Fills with the current pacer color.
                .frame(width: 80, height: 80) // Smaller frame // Sets the size.
                .scaleEffect(manager.pacerScale) // Applies the scaling animation.
                .shadow(color: manager.pacerColor.opacity(0.5), radius: 5) // Adds a shadow.
            
            Text(manager.pacerPhase.rawValue) // Displays the current phase name.
                .font(.caption).bold() // Sets font.
                .foregroundColor(.white) // Sets text color.
        }
        .animation(.easeInOut(duration: 0.1), value: manager.pacerScale) // Applies animation to the view.
    }
}

// MARK: - 4. App Entry Point for WatchOS

@main // Attribute to designate the entry point of the app.
struct PulsePeaceWatchApp: App { // Defines the main app structure.
    // The main entry point for the watchOS application.
    var body: some Scene { // Defines the body of the app.
        WindowGroup { // Creates a window group.
            PulsePeaceWatchView() // Sets the root view.
        }
    }
}