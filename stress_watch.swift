// TODO: suspicious stuff: i think the app still is checking for  hrv data on app instead of hr
import SwiftUI // Imports the SwiftUI framework for building the user interface.
import HealthKit // Imports the HealthKit framework for accessing health data like HRV.
import Combine // Imports the Combine framework for handling asynchronous events and data streams.
import WatchKit // Imports the WatchKit framework, required for watchOS-specific features like haptics.

// MARK: - LOGIC
// ============================================================================

enum PacerPhase: String {
    case inhale = "Inhale"
    case hold = "Hold"
    case exhale = "Exhale"
}

// MARK: 1. HealthKit Manager

/**
 * HealthKitManager: Handles all direct interaction with the Apple HealthKit framework.
 * This class abstracts away the complexity of data querying and authorization.
 */
class HealthKitManager: NSObject { // Defines the HealthKitManager class to manage HealthKit operations.
    override init() {
        super.init()
    }
    private lazy var healthStore = HKHealthStore()
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)
    
    // session management
    private var currentSession: HKWorkoutSession?
    private var currentBuilder: HKLiveWorkoutBuilder?
    
    /**
     * Request Authorization: Prompts the user for permission to read HRV data.
     */
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) { // Function to request HealthKit authorization with a completion handler.
        guard let hrvType = hrvType, HKHealthStore.isHealthDataAvailable() else { 
            completion(false, NSError(domain: "HealthKitError", code: 100, userInfo: [NSLocalizedDescriptionKey: "Health data is not available."])) 
            return 
        }
        
        // Use HKObjectType for the set to allow mixed types (Quantity and Series)
        var typesToRead: Set<HKObjectType> = [hrvType]
        if let hrType = heartRateType {
            typesToRead.insert(hrType)
        }
        
        let heartbeatType = HKSeriesType.heartbeat()
        let workoutType = HKWorkoutType.workoutType()
        typesToRead.insert(heartbeatType)
        typesToRead.insert(workoutType)
        
        // Share hrvType AND heartbeatType. Apple requires SDNN sharing permission 
        // to be requested alongside Heartbeat Series sharing.
        let shareList = [workoutType, heartbeatType, hrvType].compactMap { $0 as? HKSampleType }
        let shareSet = Set(shareList)
        
        healthStore.requestAuthorization(toShare: shareSet, read: typesToRead) { success, error in 
            DispatchQueue.main.async { 
                completion(success, error) 
            }
        }
    }
    


    
    /**
     * Diagnostic Control Fetch: Tries to fetch Heart Rate to see if HealthKit is working at all.
     */
    func fetchControlHeartRate(since: Date?, completion: @escaping (Double?, Date?, Error?) -> Void) {
        guard let heartRateType = heartRateType else {
            completion(nil, nil, nil)
            return
        }
        let now = Date()
        // Use either the provided session start time OR fall back to 24 hours ago
        let startPoint = since ?? now.addingTimeInterval(-86400)
        let predicate = HKQuery.predicateForSamples(withStart: startPoint, end: nil, options: [])
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: heartRateType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) {
            (_, samples, error) in
            DispatchQueue.main.async {
                if let error = error {
                    completion(nil, nil, error)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    completion(nil, nil, nil)
                    return
                }
                let bpm = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                completion(bpm, sample.endDate, nil)
            }
        }
        healthStore.execute(query)
    }
    

    
    /**
     * Manual HRV Calculation: Fetches raw heartbeats and calculates SDNN.
     * Used for users under 18 where system HRV is restricted.
     */
    func fetchManualBPMSeries(since: Date?, statusUpdate: ((String) -> Void)? = nil, completion: @escaping (Double?, Int, Date?, Error?, Double?) -> Void) {
        guard let hrType = heartRateType else {
            completion(nil, 0, nil, nil, nil)
            return
        }
        
        let now = Date()
        let startPoint = since ?? now.addingTimeInterval(-65)
        let predicate = HKQuery.predicateForSamples(withStart: startPoint, end: nil, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        
        let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: 6, sortDescriptors: [sortDescriptor]) { [weak self] (_, samples, error) in
            guard let self = self else { return }
            
            let hrSamples = samples?.compactMap { $0 as? HKQuantitySample } ?? []
            let count = hrSamples.count
            
            DispatchQueue.main.async {
                if count < 6 {
                    completion(nil, count, nil, error, nil)
                    return
                }
                
                // Consistency: Use the same rounding logic for DB fetches
                let intervals = hrSamples.prefix(6).map { round(60000.0 / max(1.0, $0.quantity.doubleValue(for: HKUnit(from: "count/min")))) }
                
                let sd = self.calculateBPM_SD(from: Array(intervals))
                let lastBpm = hrSamples.last?.quantity.doubleValue(for: HKUnit(from: "count/min"))
                completion(sd, count, hrSamples.last?.endDate, nil, lastBpm)
            }
        }
        healthStore.execute(query)
    }
    
    private func calculateBPM_SD(from intervals: [Double]) -> Double {
        let count = Double(intervals.count)
        guard count > 1 else { return 0 } // Safety for N-1
        let mean = intervals.reduce(0, +) / count
        let sumOfSquaredDiffs = intervals.map { pow($0 - mean, 2.0) }.reduce(0, +)
        return sqrt(sumOfSquaredDiffs / (count - 1))
    }
    
    // Simplified Math Logic: BPM-based SD calculation
    
    // MARK: - Measurement Session (Forcing Beat-to-Beat Data)
    
    func startMeasurementSession() {
        // V12.2: Check Auth Status
        let authStatus = healthStore.authorizationStatus(for: HKSeriesType.heartbeat())

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody // prioritized for high-resolution heart pulse data
        configuration.locationType = .indoor
        
        do {
            currentSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            currentBuilder = currentSession?.associatedWorkoutBuilder()
            
            let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            // Explicitly enable Heart Rate for the builder
            if let hrType = heartRateType {
                dataSource.enableCollection(for: hrType, predicate: nil)
            }
            currentBuilder?.dataSource = dataSource
            
            let startDate = Date()
            currentSession?.startActivity(with: startDate)
            currentBuilder?.beginCollection(withStart: startDate) { success, error in
                // Handled silently
            }
        } catch {
            // Handled silently
        }
    }
    
    // Delegates removed for stability
    
    func stopMeasurementSession(completion: @escaping (Bool) -> Void) {
        guard let session = currentSession, let builder = currentBuilder else {
            completion(false)
            return
        }
        
        session.end()
        builder.endCollection(withEnd: Date()) { (success, error) in
            if success {
                builder.finishWorkout { (workout, error) in
                    DispatchQueue.main.async {
                        completion(workout != nil)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        
        currentSession = nil
        currentBuilder = nil
    }
}


// MARK: 2. App Logic (ViewModel)



/**
 * StressNotOnMyWatchManager: The central state controller (`ObservableObject`).
 * **Modified for Watch Haptics.**
 */
class StressNotOnMyWatchManager: ObservableObject { // Defines the StressNotOnMyWatchManager class, conforming to ObservableObject for SwiftUI updates.
    
    // --- Constants ---
    private let THRESHOLD: Double = 50.0 // Constant defining the HRV threshold for stress detection.
    private let SESSION_DURATION = 60 // Constant defining the duration of a breathing session in seconds.
    
    // Lazy initialization to prevent crashes in Previews
    private lazy var healthKitManager: HealthKitManager = HealthKitManager()
    
    // --- Published Properties (These update the SwiftUI View) ---
    @Published var hrvValue: Double? = nil
    @Published var statusText: String = "Initializing..."
    @Published var isStressed: Bool = false
    @Published var isIntervening: Bool = false
    @Published var messageBoxContent: String? = nil
    
    // --- Session & Measurement State ---
    @Published var isMeasuring: Bool = false
    @Published var measurementCountdown: Double = 60.0
    @Published var showStressQuestionnaire: Bool = false
    @Published var currentSessionBPMs: [Double] = []   // V17: Live capture during session
    private var lastCapturedSecond: Int = -1
    private var lastCapturedBPMDate: Date? = nil      // V18: Prevent duplicates
    @Published var lastSessionStartDate: Date? = nil // Fix: Track session start for strict fetching
    private var lastMeasuredHRV: Double? = nil
    
    // Safety Getters for UI
    var hrvString: String {
        guard let val = hrvValue else { return "--" }
        return String(format: "%.0f", val)
    }
    
    // --- Pacer State ---
    @Published var pacerPhase: PacerPhase = .inhale
    @Published var countdown: Int = 4
    
    // --- Internal Timers and Variables ---
    private var sessionTimer: Timer? // Timer for the breathing session countdown.
    private var preSessionHRV: Double = 0 // Variable to store the HRV value before the session starts.
    private var isAuthorized = false // Boolean to track if HealthKit authorization has been granted.
    
    init() {
        // Init is now lightweight to prevent UI blocking.
    }
    
    func startup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.loadCalibrationData()
            
            // USER REQUEST: Reset baseline data every time the app runs
            self.stressedReadings = []
            self.calmReadings = []
            self.customThreshold = nil
            self.hrvValue = nil
            self.calibrationStartDate = Date() // Restart the 24-hour clock
            self.isCalibrating = true // Ensure we are in calibration mode
            
            self.saveCalibrationData() // Persist the reset
            self.checkCalibrationStatus()
            self.requestHealthKitAuthorization()
        }
    }
    
    // --- Calibration State ---
    @Published var isCalibrating: Bool = false // Tracks if the app is in the 1-day calibration mode.
    @Published var calibrationHour: Int = 0 // Tracks the current hour of the calibration (1-24).
    @Published var measurementCount: Int = 0 // Number of successful HRV measurements taken during calibration.
    private var calibrationStartDate: Date? // Stores the start date of the calibration period.
    private var stressedReadings: [Double] = [] // Stores HRV readings when user says "Yes, Stressed".
    private var calmReadings: [Double] = [] // Stores HRV readings when user says "No, Calm".
    private var customThreshold: Double? // Stores the calculated personalized threshold after calibration.
    
    /// Returns the personalized threshold if available, otherwise calculates a tentative baseline from current readings.
    var tentativeBaseline: Double {
        if let custom = customThreshold { return custom }
        
        if !stressedReadings.isEmpty {
            return stressedReadings.reduce(0, +) / Double(stressedReadings.count)
        } else if !calmReadings.isEmpty {
            // Fallback: 20% below calm average
            let avgCalm = calmReadings.reduce(0, +) / Double(calmReadings.count)
            return avgCalm * 0.8
        }
        
        return THRESHOLD // Final fallback to system default
    }
    
    // --- Demographics ---
    @Published var userAge: String = "" // Optional user age.
    @Published var userGender: String = "Prefer not to say" // Optional user gender.
    
    /**
     * Load Calibration Data: Retrieves persistence state from UserDefaults.
     */
    private func loadCalibrationData() {
        let defaults = UserDefaults.standard
        isCalibrating = defaults.bool(forKey: "isCalibrating")
        calibrationStartDate = defaults.object(forKey: "calibrationStartDate") as? Date
        stressedReadings = defaults.array(forKey: "stressedReadings") as? [Double] ?? []
        calmReadings = defaults.array(forKey: "calmReadings") as? [Double] ?? []
        customThreshold = defaults.object(forKey: "customThreshold") as? Double
        
        userAge = defaults.string(forKey: "userAge") ?? ""
        userGender = defaults.string(forKey: "userGender") ?? "Prefer not to say"
    }
    
    /**
     * Save Calibration Data: Persists state to UserDefaults.
     */
    private func saveCalibrationData() {
        let defaults = UserDefaults.standard
        defaults.set(isCalibrating, forKey: "isCalibrating")
        defaults.set(calibrationStartDate, forKey: "calibrationStartDate")
        defaults.set(stressedReadings, forKey: "stressedReadings")
        defaults.set(calmReadings, forKey: "calmReadings")
        defaults.set(customThreshold, forKey: "customThreshold")
        
        defaults.set(userAge, forKey: "userAge")
        defaults.set(userGender, forKey: "userGender")
    }
    
    /**
     * Reset Calibration: Clears all calibration data and restarts the process.
     */
    func resetCalibration() {
        isCalibrating = true
        calibrationStartDate = Date()
        stressedReadings = []
        calmReadings = []
        customThreshold = nil
        measurementCount = 0
        userAge = "" // Clear demographics as well
        userGender = "Prefer not to say"
        saveCalibrationData()
        checkCalibrationStatus()
        statusText = "Ready"
    }

    // Public method used by the UI button
    func resetBaseline() {
        resetCalibration()
    }
    
    /**
     * Start Calibration: Initiates the 7-day calibration period.
     * Resets any previous calibration data.
     */
    func startCalibration(age: String, gender: String) {
        isCalibrating = true
        calibrationStartDate = Date()
        stressedReadings = []
        calmReadings = []
        customThreshold = nil
        userAge = age
        userGender = gender
        saveCalibrationData()
        checkCalibrationStatus()
    }
    
    /**
     * Start "Stay Still" Session: 90 seconds of forced heartbeat recording.
     */
    func startStayStillSession() {
        guard !isMeasuring else { return }
        
        sessionTimer?.invalidate()
        
        isMeasuring = true
        measurementCountdown = 60.0
        statusText = "Stay Still..."
        currentSessionBPMs = []
        lastCapturedSecond = -1
        lastCapturedBPMDate = nil
        lastSessionStartDate = Date()
        
        healthKitManager.startMeasurementSession()
        
        let startTime = Date()
        let totalDuration: Double = 60.0
        
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, totalDuration - elapsed)
            let currentSecond = Int(elapsed)
            
            self.measurementCountdown = remaining
            
            // Capture every 10 seconds (10, 20, 30, 40, 50, 60)
            if currentSecond > 0 && currentSecond % 10 == 0 && currentSecond != self.lastCapturedSecond {
                self.lastCapturedSecond = currentSecond
                self.captureSnapshotBPM()
            }
            
            if remaining <= 0 {
                timer.invalidate()
                self.finishStayStillSession()
            }
        }
    }
    
    private func captureSnapshotBPM() {
        let startTime = lastSessionStartDate ?? Date()
        let queryStart = startTime.addingTimeInterval(-15)
        
        healthKitManager.fetchControlHeartRate(since: queryStart) { [weak self] bpm, date, _ in
            guard let self = self, let bpm = bpm, let date = date else { return }
            
            DispatchQueue.main.async {
                // Restore Deduplication: Only count if this is a newer reading than the last one we stole
                if self.lastCapturedBPMDate == nil || date > self.lastCapturedBPMDate! {
                    self.lastCapturedBPMDate = date
                    self.currentSessionBPMs.append(bpm)
                }
            }
        }
    }
    
    private func finishStayStillSession() {
        self.healthKitManager.stopMeasurementSession { [weak self] success in
            guard let self = self else { return }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.fetchAndDisplayResults(retryCount: 10) 
            }
        }
    }
    
    private func fetchAndDisplayResults(retryCount: Int) {
        if currentSessionBPMs.count >= 6 {
            // Enforce strict limit: only use first 6 samples
            let samples = Array(currentSessionBPMs.prefix(6))
            let count = samples.count
            
            // Round to nearest integer millisecond to match standard HRV data
            let intervals = samples.map { round(60000.0 / max(1.0, $0)) }
            
            let countD = Double(intervals.count)
            guard countD > 1 else { return } // Safety for N-1
            
            let mean = intervals.reduce(0, +) / countD
            let sumSq = intervals.map { pow($0 - mean, 2.0) }.reduce(0, +)
            let sd = sqrt(sumSq / (countD - 1))
            
            self.lastMeasuredHRV = sd
            self.hrvValue = sd
            
            self.isMeasuring = false
            if self.isCalibrating {
                self.measurementCount += 1
                self.checkCalibrationStatus()
            } else {
                self.updateDetectionStatus()
            }
            self.showStressQuestionnaire = true
            self.statusText = "Done"
            return
        }
        
        self.healthKitManager.fetchManualBPMSeries(since: self.lastSessionStartDate, statusUpdate: { _ in }) { [weak self] hrv, count, date, error, bpm in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let hrv = hrv {
                    self.lastMeasuredHRV = hrv
                    self.hrvValue = hrv
                    self.isMeasuring = false
                    if self.isCalibrating {
                        self.measurementCount += 1
                        self.checkCalibrationStatus()
                    } else {
                        self.updateDetectionStatus()
                    }
                    self.showStressQuestionnaire = true
                    self.statusText = "Done"
                } else if retryCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.fetchAndDisplayResults(retryCount: retryCount - 1)
                    }
                } else {
                    self.isMeasuring = false
                    self.statusText = "Try Again"
                }
            }
        }
    }
    
    /**
     * Report Stress Result: Used during calibration to build the baseline.
     */
    func reportStressResult(isStressed: Bool) {
        guard let hrv = lastMeasuredHRV else { return }
        
        if isStressed {
            stressedReadings.append(hrv)
        } else {
            calmReadings.append(hrv)
        }
        
        saveCalibrationData()
        showStressQuestionnaire = false
        isMeasuring = false
        
        if isStressed {
            // Even during calibration, if you're stressed, you should breathe!
            startStressNotOnMyWatchSession()
        } else {
            statusText = "Recorded"
            checkCalibrationStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.isIntervening && !self.isMeasuring {
                    self.statusText = self.isCalibrating ? "Hourly Check" : "Ready"
                }
            }
        }
    }
    
    func dismissQuestionnaire() {
        if isMeasuring && !showStressQuestionnaire {
            healthKitManager.stopMeasurementSession { _ in }
        }
        showStressQuestionnaire = false
        isMeasuring = false
        statusText = isCalibrating ? "Hourly Check" : "Ready"
    }
    
    /**
     * Check Calibration Status: Checks if the 1-day period is over.
     */
    func checkCalibrationStatus() {
        if let _ = customThreshold { return }
        guard isCalibrating, let startDate = calibrationStartDate else { return }
        let hoursElapsed = Int(Date().timeIntervalSince(startDate) / 3600)
        calibrationHour = hoursElapsed + 1
        
        if measurementCount >= 6 && hoursElapsed >= 1 {
            isCalibrating = false
            if !stressedReadings.isEmpty {
                customThreshold = stressedReadings.reduce(0, +) / Double(stressedReadings.count)
            } else if !calmReadings.isEmpty {
                let avgCalm = calmReadings.reduce(0, +) / Double(calmReadings.count)
                customThreshold = avgCalm * 0.8
            }
            saveCalibrationData()
        }
    }
    
    /**
     * Helper function to play a soft, system-level HAPTIC notification (Watch preferred).
     * Replaces the AudioToolbox beep used in the iOS version.
     */
    private func triggerHapticNotification() { // Function to trigger a haptic notification.
        // Use a simple notification haptic to alert the user on the wrist.
#if os(watchOS)
        WKInterfaceDevice.current().play(.notification) // Plays a notification haptic on the Apple Watch.
#endif
    }
    
    // MARK: - HealthKit Integration
    
    func requestHealthKitAuthorization() {
        healthKitManager.requestAuthorization { [weak self] success, _ in
            guard let self = self else { return }
            if success {
                self.isAuthorized = true
            } else {
                self.statusText = "Denied"
            }
        }
    }
    
    func refreshData() {
        guard isAuthorized && !isIntervening && !isMeasuring else { return }
        self.startStayStillSession()
    }
    
    // MARK: - Detection Logic
    
    private func updateDetectionStatus() {
        guard let hrv = hrvValue else { return }
        let currentThreshold = customThreshold ?? THRESHOLD
        
        if hrv < currentThreshold {
            isStressed = true
            statusText = "STRESSED"
            messageBoxContent = "Your HRV is low (\(Int(hrv))ms). We recommend a breathing session."
            self.triggerHapticNotification()
        } else {
            isStressed = false
            statusText = "Calm"
            messageBoxContent = "Your HRV is healthy (\(Int(hrv))ms). Keep it up!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !self.isIntervening && !self.isMeasuring {
                    self.messageBoxContent = nil
                }
            }
        }
    }
    
    // MARK: - Intervention Logic (4-7-8 Pacer)
    
    func startStressNotOnMyWatchSession() {
        guard !isIntervening, let _ = hrvValue else { return }
        
        isIntervening = true
        statusText = "Breathing..."
        messageBoxContent = "Please open the Mindfulness app and start a 1-minute Breathe session."
        
        // Internal pacer logic is bypassed in favor of Mindfulness redirection as requested.
    }
    
    private func startPacerTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.countdown > 1 {
                self.countdown -= 1
            } else {
                // Phase Transition
                switch self.pacerPhase {
                case .inhale:
                    self.pacerPhase = .hold
                    self.countdown = 7
                case .hold:
                    self.pacerPhase = .exhale
                    self.countdown = 8
                case .exhale:
                    self.pacerPhase = .inhale
                    self.countdown = 4
                }
                
                // Haptic feedback at phase change
                self.triggerHapticNotification()
            }
        }
    }
    
    func endStressNotOnMyWatchSession() {
        sessionTimer?.invalidate()
        isIntervening = false
        statusText = "Calm"
    }
}

// ============================================================================
// MARK: - SCREEN (ContentView)
// ============================================================================

/**
 * ContentView: The simplified SwiftUI view for Apple Watch.
 */
struct ContentView: View { // Defines the main SwiftUI view for the watch app.
    
    @StateObject var manager = StressNotOnMyWatchManager() // Creates a state object for the manager.
    
    // --- Survey State ---
    @State private var showDemographics = false // Controls visibility of the demographic survey.
    @State private var tempAge = "" // Temporary storage for age input.
    @State private var tempGender = "Prefer not to say" // Temporary storage for gender input.
    let genderOptions = ["Male", "Female", "Non-binary", "Other", "Prefer not to say"] // Options for gender picker.
    
    var body: some View { // Defines the body of the view.
        ZStack {
            ScrollView {
                VStack(spacing: 8) {
                    // MARK: App Title
                    Text("Stress? Not on my Watch!")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 2)
                    
                    // MARK: Status (Top of screen)
                    statusPill
                    
                    if manager.isCalibrating {
                        VStack(spacing: 10) {
                            Text("CALIBRATION MODE")
                                .font(.caption2).fontWeight(.bold).foregroundColor(.orange)
                            Text("Sessions: \(manager.measurementCount)/6") // User requested session count focus
                                .font(.caption2).foregroundColor(.gray)
                            
                            VStack(spacing: 2) {
                                Text("\(Int(manager.tentativeBaseline))")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundColor(.orange)
                                Text("TARGET BASELINE").font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            .padding(.vertical, 5)
                            
                            Button(action: manager.startStayStillSession) {
                                Text("HOURLY CHECK").font(.headline)
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        }
                        .padding().background(Color.orange.opacity(0.1)).cornerRadius(10)
                    } else if manager.isIntervening {
                        VStack(spacing: 15) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 40))
                                .foregroundColor(.purple)
                            
                            Text("Mindfulness Session")
                                .font(.headline)
                                .foregroundColor(.purple)
                                .multilineTextAlignment(.center)
                            
                            Text("Use the system Mindfulness app for your session.")
                                .font(.caption2).foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                            
                            Button(action: manager.endStressNotOnMyWatchSession) {
                                Text("I'M DONE BREATHING").font(.headline)
                            }
                            .buttonStyle(.borderedProminent).tint(.green)
                        }
                    } else {
                        VStack(spacing: 15) {
                            VStack(spacing: 2) {
                                Text(manager.hrvString)
                                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                                    .foregroundColor(manager.isStressed ? .red : .green)
                                Text("HRV (ms)").font(.caption2).foregroundColor(.gray)
                            }
                            
                            Button(action: manager.startStayStillSession) {
                                Text("CHECK FOR STRESS").font(.headline)
                            }
                            .buttonStyle(.borderedProminent).tint(.blue)
                            
                            if manager.isStressed {
                                Button(action: manager.startStressNotOnMyWatchSession) {
                                    Text("START BREATHING").font(.headline)
                                }
                                .buttonStyle(.borderedProminent).tint(.purple)
                            }
                        }
                    }
                    
                    // MARK: Message Box
                    if let message = manager.messageBoxContent {
                        Text(message).font(.caption2).padding(5).frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(8)
                    }
                    
                    if !manager.isCalibrating {
                        Button("Re-Calibrate") { showDemographics = true }
                            .font(.caption2).padding(.top, 10)
                    }
                    

                    // Reset Baseline Button
                    Button(action: {
                        manager.resetBaseline()
                    }) {
                        Text("Reset Baseline")
                            .font(.caption2)
                            .padding(4)
                            .background(Color.red.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical)
            }
            
            // MARK: Stay Still Overlay
            if manager.isMeasuring && !manager.showStressQuestionnaire {
                Color.black.ignoresSafeArea()
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 20) {
                        Text("Stay Still...")
                            .font(.headline)
                        
                        ZStack {
                            Circle()
                                .stroke(lineWidth: 10)
                                .opacity(0.3)
                                .foregroundColor(.blue)
                            
                            Circle()
                                .trim(from: 0.0, to: CGFloat(manager.measurementCountdown) / 60.0)
                                .stroke(style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                                .foregroundColor(.blue)
                                .rotationEffect(Angle(degrees: 270.0))
                                .animation(.linear(duration: 0.1), value: manager.measurementCountdown)
                            
                            Text("\(Int(ceil(manager.measurementCountdown)))")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                        }
                        .frame(width: 80, height: 80)
                        
                        Text(manager.statusText)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Button(action: manager.dismissQuestionnaire) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
            }
            
            // MARK: Stress Questionnaire
            if manager.showStressQuestionnaire {
                Color.black.ignoresSafeArea()
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 15) {
                        Text("Measurement Done")
                            .font(.headline)
                        
                        if let hrv = manager.hrvValue {
                            VStack(spacing: 2) {
                                Text("\(Int(hrv))")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundColor(.blue)
                                Text("ms")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        if manager.isCalibrating {
                            Text("Were you feeling stressed during this session?")
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            
                            HStack {
                                Button("Yes") {
                                    manager.reportStressResult(isStressed: true)
                                }
                                .buttonStyle(.borderedProminent).tint(.red)
                                
                                Button("No") {
                                    manager.reportStressResult(isStressed: false)
                                }
                                .buttonStyle(.borderedProminent).tint(.green)
                            }
                        } else {
                            Text(manager.isStressed ? "You appear stressed." : "You appear calm.")
                                .font(.caption2)
                                .foregroundColor(manager.isStressed ? .red : .green)
                            
                            if manager.isStressed {
                                Button("Breathe") {
                                    manager.dismissQuestionnaire()
                                    manager.startStressNotOnMyWatchSession()
                                }
                                .buttonStyle(.borderedProminent).tint(.purple)
                            } else {
                                Button("Dismiss") {
                                    manager.dismissQuestionnaire()
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 5)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    Button(action: manager.dismissQuestionnaire) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showDemographics) {
            ScrollView {
                VStack(spacing: 10) {
                    Text("Tell us about you").font(.headline)
                    Text("These fields are optional.").font(.caption2).foregroundColor(.gray)
                    
                    VStack(alignment: .leading) {
                        Text("Age").font(.caption)
                        TextField("Optional", text: $tempAge)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Gender").font(.caption)
                        Picker("Gender", selection: $tempGender) {
                            ForEach(genderOptions, id: \.self) { Text($0).tag($0) }
                        }.frame(height: 50)
                    }
                    
                    Button(action: {
                        manager.startCalibration(age: tempAge, gender: tempGender)
                        showDemographics = false
                    }) {
                        Text("Start Calibration").bold()
                    }.buttonStyle(.borderedProminent).tint(.green).padding(.top)
                }
                .padding()
            }
        }
        .onAppear {
            manager.startup()
        }
    }
    
    // Helper View: The Status Pill (Simplified for Watch)
    private var statusPill: some View {
        let bgColor: Color 
        let textColor: Color 
        
        if manager.isIntervening {
            bgColor = .purple.opacity(0.5)
            textColor = .white
        } else if manager.isStressed {
            bgColor = .red
            textColor = .white
        } else if manager.hrvValue == nil {
            bgColor = .yellow.opacity(0.8)
            textColor = .black
        } else {
            bgColor = .green
            textColor = .white
        }
        
        return Text(manager.statusText)
            .font(.caption).bold()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bgColor)
            .foregroundColor(textColor)
            .cornerRadius(.infinity)
    }
}

// ============================================================================
// MARK: - APP ENTRY POINT
// ============================================================================

@main
struct StressNotOnMyWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#Preview {
    ContentView()
}
