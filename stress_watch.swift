import SwiftUI // Imports the SwiftUI framework for building the user interface.
import HealthKit // Imports the HealthKit framework for accessing health data like HRV.
import Combine // Imports the Combine framework for handling asynchronous events and data streams.
import WatchKit // Imports the WatchKit framework, required for watchOS-specific features like haptics.

enum WatchAppMode: String, Codable {
    case training = "Training"
    case predicting = "Predicting"
}


// MARK: - LOGIC
// ============================================================================

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
        
        let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: 12, sortDescriptors: [sortDescriptor]) { [weak self] (_, samples, error) in
            guard let self = self else { return }
            
            let allSamples = samples?.compactMap { $0 as? HKQuantitySample } ?? []
            
            // Downsample: Pick every other sample (1st, 3rd, 5th, etc.) to ensure 10-second intervals
            // if the system recorded at 5-second intervals.
            var filteredSamples: [HKQuantitySample] = []
            for (index, sample) in allSamples.enumerated() {
                if index % 2 == 0 {
                    filteredSamples.append(sample)
                }
            }
            
            // Use only the first 6 of our filtered "10-second" samples
            let hrSamples = Array(filteredSamples.prefix(6))
            let count = hrSamples.count
            
            DispatchQueue.main.async {
                if count < 6 {
                    completion(nil, count, nil, error, nil)
                    return
                }
                
                let intervals = hrSamples.map { 60000.0 / max(1.0, $0.quantity.doubleValue(for: HKUnit(from: "count/min"))) }
                
                let sd = self.calculateBPM_SD(from: intervals)
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
    
    // --- Internal Timers and Variables ---
    private var sessionTimer: Timer? // Timer for the breathing session countdown.
    private var isAuthorized = false // Boolean to track if HealthKit authorization has been granted.
    
    // Added property for tracking last 5 predictions in predicting mode
    private var lastFivePredictions: [Bool] = []
    
    // Configurable Sensitivity
    @Published var sensitivityStressedCount: Int = 3
    @Published var sensitivityWindowSize: Int = 5
    
    init() {
        // Init is now lightweight to prevent UI blocking.
    }
    
    func startup() {
        // Run synchronously to ensure data is loaded before View appears
        self.loadTrainingData()
        self.checkTrainingStatus()
        self.requestHealthKitAuthorization()
    }
    
    // --- Mode State ---
    @Published var activeMode: WatchAppMode = .training
    private var predictingTimer: Timer?
    
    // --- Training State ---
    @Published var isTraining: Bool = false // Tracks if the app is in the training mode.
    @Published var trainingHour: Int = 0 // Tracks the current hour of the training (1-24).
    @Published var measurementCount: Int = 0 // Number of successful HRV measurements taken during training.
    private var trainingStartDate: Date? // Stores the start date of the training period.
    private var stressedReadings: [Double] = [] // Stores HRV readings when user says "Yes, Stressed".
    private var calmReadings: [Double] = [] // Stores HRV readings when user says "No, Calm".
    private var customThreshold: Double? // Stores the calculated personalized threshold after training.
    
    // UI Helpers for training progress
    var stressedCount: Int { stressedReadings.count }
    var calmCount: Int { calmReadings.count }
    
    /// Returns the personalized threshold if available, otherwise calculates a tentative threshold from current readings.
    var tentativeThreshold: Double {
        if let custom = customThreshold { return custom }
        
        // If we have at least 3 of each, use the median-of-medians algorithm even if training hasn't "ended"
        if stressedReadings.count >= 3 && calmReadings.count >= 3 {
            let mStressed = calculateMedian(Array(stressedReadings.suffix(3)))
            let mCalm = calculateMedian(Array(calmReadings.suffix(3)))
            return (mStressed + mCalm) / 2.0
        }
        
        // Earlier fallback: use medians of whatever we have
        if !stressedReadings.isEmpty && !calmReadings.isEmpty {
            return (calculateMedian(stressedReadings) + calculateMedian(calmReadings)) / 2.0
        } else if !stressedReadings.isEmpty {
            return calculateMedian(stressedReadings)
        } else if !calmReadings.isEmpty {
            // Fallback: 20% below calm median
            return calculateMedian(calmReadings) * 0.8
        }
        
        return THRESHOLD // Final fallback to system default
    }
    
    private func calculateMedian(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }
    
    // --- Demographics ---
    @Published var userAge: String = "" // Optional user age.
    @Published var userGender: String = "Prefer not to say" // Optional user gender.
    
    /**
     * Load Training Data: Retrieves persistence state from UserDefaults.
     */
    private func loadTrainingData() {
        let defaults = UserDefaults.standard
        isTraining = defaults.bool(forKey: "isTraining")
        trainingStartDate = defaults.object(forKey: "trainingStartDate") as? Date
        stressedReadings = defaults.array(forKey: "stressedReadings") as? [Double] ?? []
        calmReadings = defaults.array(forKey: "calmReadings") as? [Double] ?? []
        customThreshold = defaults.object(forKey: "customThreshold") as? Double
        
        userAge = defaults.string(forKey: "userAge") ?? ""
        userGender = defaults.string(forKey: "userGender") ?? "Prefer not to say"
        
        let loadedStressedCount = defaults.integer(forKey: "sensitivityStressedCount")
        if loadedStressedCount > 0 { sensitivityStressedCount = loadedStressedCount }
        
        let loadedWindowSize = defaults.integer(forKey: "sensitivityWindowSize")
        if loadedWindowSize > 0 { sensitivityWindowSize = loadedWindowSize }
        
        if let modeRaw = defaults.string(forKey: "activeMode"), let mode = WatchAppMode(rawValue: modeRaw) {
            activeMode = mode
        }
    }
    
    /**
     * Save Training Data: Persists state to UserDefaults.
     */
    private func saveTrainingData() {
        let defaults = UserDefaults.standard
        defaults.set(isTraining, forKey: "isTraining")
        defaults.set(trainingStartDate, forKey: "trainingStartDate")
        defaults.set(stressedReadings, forKey: "stressedReadings")
        defaults.set(calmReadings, forKey: "calmReadings")
        defaults.set(customThreshold, forKey: "customThreshold")
        
        defaults.set(userAge, forKey: "userAge")
        defaults.set(userGender, forKey: "userGender")
        
        defaults.set(sensitivityStressedCount, forKey: "sensitivityStressedCount")
        defaults.set(sensitivityWindowSize, forKey: "sensitivityWindowSize")
        
        defaults.set(activeMode.rawValue, forKey: "activeMode")
    }
    
    /**
     * Reset Training: Clears all training data and restarts the process.
     */
    func resetTraining() {
        isTraining = true
        trainingStartDate = Date()
        stressedReadings = []
        calmReadings = []
        customThreshold = nil
        measurementCount = 0
        userAge = "" // Clear demographics as well
        userGender = "Prefer not to say"
        statusText = "Ready"
        hrvValue = nil
        saveTrainingData()
        checkTrainingStatus()
    }

    // Public method used by the UI button
    func resetThreshold() {
        resetTraining()
    }
    
    /**
     * Start Training: Initiates the 7-day training period.
     * Resets any previous training data.
     */
    func startTraining(age: String, gender: String, stressedCount: Int, windowSize: Int) {
        isTraining = true
        trainingStartDate = Date()
        stressedReadings = []
        calmReadings = []
        customThreshold = nil
        userAge = age
        userGender = gender
        sensitivityStressedCount = stressedCount
        sensitivityWindowSize = windowSize
        saveTrainingData()
        checkTrainingStatus()
    }
    
    /**
     * Start "Stay Still" Session: 60 seconds of forced heartbeat recording.
     */
    func startStayStillSession() {
        guard !isMeasuring else { return }
        
        // Stop any pending prediction timer if we start a manual check
        // however, we'll let it stay to keep the half-hour rhythm.
        
        sessionTimer?.invalidate()
        
        isMeasuring = true
        measurementCountdown = 60.0
        statusText = "Wrist Stay Still..."
        currentSessionBPMs = []
        messageBoxContent = nil
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
            let intervals = samples.map { 60000.0 / max(1.0, $0) }
            
            let countD = Double(intervals.count)
            guard countD > 1 else { return } // Safety for N-1
            
            let mean = intervals.reduce(0, +) / countD
            let sumSq = intervals.map { pow($0 - mean, 2.0) }.reduce(0, +)
            let sd = sqrt(sumSq / (countD - 1))
            
            self.lastMeasuredHRV = sd
            self.hrvValue = sd
            
            self.isMeasuring = false
            if self.isTraining {
                self.measurementCount += 1
                self.checkTrainingStatus()
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
                    if self.isTraining {
                        self.measurementCount += 1
                        self.checkTrainingStatus()
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
                    self.statusText = "Poor Signal"
                    self.messageBoxContent = "Bad reading. Please tighten the wristband and keep good contact."
                }
            }
        }
    }
    
    /**
     * Report Stress Result: Used during training to build the threshold.
     */
    func reportStressResult(isStressed: Bool) {
        guard let hrv = lastMeasuredHRV else { return }
        
        if isStressed {
            stressedReadings.append(hrv)
        } else {
            calmReadings.append(hrv)
        }
        
        saveTrainingData()
        showStressQuestionnaire = false
        isMeasuring = false
        
        if isStressed {
            // Even during training, if you're stressed, you should breathe!
            startStressNotOnMyWatchSession()
        } else {
            statusText = "Recorded"
            messageBoxContent = nil
            checkTrainingStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.isIntervening && !self.isMeasuring {
                    self.statusText = self.isTraining ? "Measuring HRV" : "Ready"
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
        messageBoxContent = nil
        statusText = isTraining ? "Measuring HRV" : "Ready"
    }
    
    /**
     * Check Training Status: Checks if the 3+3 requirement is met.
     */
    func checkTrainingStatus() {
        if let _ = customThreshold { return }
        guard isTraining else { return }
        
        // REQUIREMENT: 3 stressed examples AND 3 non-stressed examples
        if stressedReadings.count >= 3 && calmReadings.count >= 3 {
            isTraining = false
            
            // Per USER REQUEST: Use the most recent three for the algorithm
            let recentStressed = Array(stressedReadings.suffix(3))
            let recentCalm = Array(calmReadings.suffix(3))
            
            let medianStressed = calculateMedian(recentStressed)
            let medianCalm = calculateMedian(recentCalm)
            
            // Middle point/average of those two medians
            customThreshold = (medianStressed + medianCalm) / 2.0
            
            // ADD THIS LINE to automatically switch to predicting mode after training completes
            setMode(.predicting)
            
            saveTrainingData()
        }
    }
    
    // Added computed property to indicate if a threshold is restorable
    var hasRestorableThreshold: Bool {
        return customThreshold != nil && !isTraining
    }

    // Added method to restore threshold and switch to predicting mode
    func restoreThresholdAndSwitchToPredicting() {
        isTraining = false
        activeMode = .predicting
        saveTrainingData()
    }
    
    // MARK: - Mode Switching
    
    func setMode(_ mode: WatchAppMode) {
        predictingTimer?.invalidate()
        activeMode = mode
        
        if mode == .predicting {
            startPredictingTimer()
            // Optional: run an immediate check if we just switched
            startStayStillSession()
        }
        
        saveTrainingData() // Persist mode change immediately
    }
    
    private func startPredictingTimer() {
        predictingTimer?.invalidate()
        // 30 minutes = 1800 seconds
        predictingTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.startStayStillSession()
            }
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
        
        if !isTraining && activeMode == .predicting {
            // Track last N predictions
            lastFivePredictions.append(hrv < currentThreshold)
            if lastFivePredictions.count > sensitivityWindowSize {
                lastFivePredictions.removeFirst()
            }

            let stressedCount = lastFivePredictions.filter { $0 }.count
            if stressedCount >= sensitivityStressedCount {
                isStressed = true
                statusText = "STRESSED"
                messageBoxContent = "Your HRV is low (\(Int(hrv))ms). We recommend a breathing session."
                self.triggerHapticNotification()
                // Automatically start intervention session
                self.startStressNotOnMyWatchSession()
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
            return
        }
        
        if hrv < currentThreshold {
            isStressed = true
            statusText = "STRESSED"
            messageBoxContent = "Your HRV is low (\(Int(hrv))ms). We recommend a breathing session."
            self.triggerHapticNotification()
            self.startStressNotOnMyWatchSession()
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
    
    func endStressNotOnMyWatchSession() {
        sessionTimer?.invalidate()
        isIntervening = false
        isStressed = false // Reset stressed state
        statusText = "Ready" // Reset status text
        messageBoxContent = nil // Clear message
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
    
    // Added state for restore threshold prompt
    @State private var showRestorePrompt = false
    
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
                    
                    if manager.isIntervening {
                        ZStack {
                            Color.red.edgesIgnoringSafeArea(.all)
                            
                            VStack(spacing: 15) {
                                Text("You're stressed.\nTime to relax.")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                                
                                Text("Try opening Apple's Mindfulness app for a Breathe session.")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                                    .padding(.horizontal)
                                
                                Spacer()
                                
                                Button(action: manager.endStressNotOnMyWatchSession) {
                                    Text("Done")
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .padding(.bottom, 20)
                            }
                        }
                    } else if manager.isTraining {
                        VStack(spacing: 12) {
                            Text("TRAINING MODE")
                                .font(.caption2).fontWeight(.bold).foregroundColor(.orange)
                            
                            VStack(spacing: 2) {
                                Text("\(manager.stressedCount)/3 stressed")
                                Text("\(manager.calmCount)/3 not stressed")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
                            
                            VStack(spacing: 2) {
                                Text("\(Int(manager.tentativeThreshold))")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundColor(.orange)
                                Text("HRV THRESHOLD").font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            .padding(.vertical, 5)
                            
                            Button(action: manager.startStayStillSession) {
                                Text("Measure HRV").font(.headline)
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                        }
                        .padding().background(Color.orange.opacity(0.1)).cornerRadius(10)
                    } else if manager.activeMode == .predicting {
                        VStack(spacing: 12) {
                            Text("PREDICTING MODE")
                                .font(.caption2).fontWeight(.bold).foregroundColor(.green)
                            VStack(spacing: 2) {
                                Text("Threshold: \(Int(manager.tentativeThreshold)) ms")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.green)
                                Text("Your personalized HRV threshold")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .padding(.vertical, 5)
                            // HRV value display and stress warning, as before
                            VStack(spacing: 2) {
                                Text(manager.hrvString)
                                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                                    .foregroundColor(manager.isStressed ? .red : .green)
                                Text("HRV (ms)").font(.caption2).foregroundColor(.gray)
                            }
                            // Manual Check Button
                            if !manager.isMeasuring {
                                Button(action: manager.startStayStillSession) {
                                    Text("CHECK NOW")
                                        .font(.caption2).fontWeight(.bold)
                                }
                                .buttonStyle(.bordered).tint(.green)
                            }
                            
                        }
                        .padding().background(Color.green.opacity(0.1)).cornerRadius(10)
                    } else {
                        VStack(spacing: 15) {
                            VStack(spacing: 2) {
                                Text(manager.hrvString)
                                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                                    .foregroundColor(manager.isStressed ? .red : .green)
                                Text("HRV (ms)").font(.caption2).foregroundColor(.gray)
                            }
                            
                        }
                    }
                    
                    // MARK: Message Box
                    if let message = manager.messageBoxContent {
                        Text(message).font(.caption2).padding(5).frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(8)
                    }
                    
                    // Mode Switcher - SHOW ONLY if in training mode
                    if manager.isTraining {
                        HStack(spacing: 10) {
                            Button(action: { manager.setMode(.training) }) {
                                Text("Training")
                                    .font(.caption2).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background(manager.activeMode == .training ? Color.orange : Color.gray.opacity(0.2))
                                    .foregroundColor(manager.activeMode == .training ? .white : .gray)
                                    .cornerRadius(8)
                            }.buttonStyle(PlainButtonStyle())
                            
                            Button(action: { manager.setMode(.predicting) }) {
                                Text("Predicting")
                                    .font(.caption2).bold()
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background(manager.activeMode == .predicting ? Color.green : Color.gray.opacity(0.2))
                                    .foregroundColor(manager.activeMode == .predicting ? .white : .gray)
                                    .cornerRadius(8)
                            }.buttonStyle(PlainButtonStyle())
                        }
                        .padding(.top, 10)
                    }
                    
                    if !manager.isTraining {
                        Button("Re-Train") { showDemographics = true }
                            .font(.caption2).padding(.top, 10)
                    }
                    

                    // Reset Threshold Button
                    Button(action: {
                        manager.resetThreshold()
                    }) {
                        Text("Reset Threshold")
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
                        Text("Wrist Stay Still...")
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
                        
                        if manager.isTraining {
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
                                Text("Starting intervention...").onAppear {
                                    manager.dismissQuestionnaire()
                                    manager.startStressNotOnMyWatchSession()
                                }
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
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Sensitivity Settings").font(.headline)
                        Text("To define stress, at least X of Y most recent recordings must be stressed.")
                            .font(.caption2).foregroundColor(.gray)
                        Text("X: \(manager.sensitivityStressedCount) Y: \(manager.sensitivityWindowSize)")
                            .font(.caption2).foregroundColor(.orange)
                            .padding(.bottom, 5)
                            
                        HStack {
                            Picker("Stressed (X)", selection: $manager.sensitivityStressedCount) {
                                ForEach(1...10, id: \.self) { i in
                                    Text("\(i)").tag(i)
                                }
                            }
                            .frame(height: 40)
                            .onChange(of: manager.sensitivityStressedCount) { newVal in
                                if newVal > manager.sensitivityWindowSize {
                                    manager.sensitivityWindowSize = newVal
                                }
                            }
                            
                            Text("of")
                            
                            Picker("Total (Y)", selection: $manager.sensitivityWindowSize) {
                                ForEach(1...10, id: \.self) { i in
                                    Text("\(i)").tag(i)
                                }
                            }
                            .frame(height: 40)
                            .onChange(of: manager.sensitivityWindowSize) { newVal in
                                if newVal < manager.sensitivityStressedCount {
                                    manager.sensitivityStressedCount = newVal
                                }
                            }
                        }
                    }
                    
                    Button(action: {
                        manager.startTraining(age: tempAge, gender: tempGender, stressedCount: manager.sensitivityStressedCount, windowSize: manager.sensitivityWindowSize)
                        showDemographics = false
                    }) {
                        Text("Start Training").bold()
                    }.buttonStyle(.borderedProminent).tint(.green).padding(.top)
                }
                .padding()
            }
        }
        .onAppear {
            manager.startup()
            // Robustness: Delay the check slightly to ensure state is fully settled
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if manager.hasRestorableThreshold {
                    showRestorePrompt = true
                }
            }
        }
        .alert("Restore Threshold?", isPresented: $showRestorePrompt) {
            Button("Restore") {
                manager.restoreThresholdAndSwitchToPredicting()
            }
            Button("Restart", role: .destructive) {
                manager.resetThreshold()
            }
        } message: {
            Text("We found a saved HRV threshold. Would you like to restore your previous threshold and continue in Predicting mode, or restart threshold calculation?")
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

