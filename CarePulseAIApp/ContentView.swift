import Charts
import CoreMotion
import Foundation
import SwiftUI

private let defaultBackendURL = "http://10.104.40.61:8765"

struct ContentView: View {
    @EnvironmentObject private var session: AppSession
    @State private var route: AuthRoute = .onboarding

    var body: some View {
        if session.isAuthenticated {
            MainTabView()
        } else if route == .onboarding {
            OnboardingView {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    route = .register
                }
            } onSignIn: {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    route = .signIn
                }
            }
        } else {
            AuthenticationView(mode: route) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    route = .onboarding
                }
            }
        }
    }
}

final class AppSession: ObservableObject {
    @Published var isAuthenticated = false
    @Published var backendURL: String {
        didSet {
            UserDefaults.standard.set(backendURL, forKey: "backendURL")
        }
    }
    @Published var userName = ""
    @Published var userEmail = ""
    @Published var authError: String?

    var token: String? {
        UserDefaults.standard.string(forKey: "authToken")
    }

    init() {
        let savedBackendURL = UserDefaults.standard.string(forKey: "backendURL") ?? defaultBackendURL
        if savedBackendURL.contains("localhost") || savedBackendURL.contains("127.0.0.1") {
            backendURL = defaultBackendURL
            UserDefaults.standard.set(defaultBackendURL, forKey: "backendURL")
        } else {
            backendURL = savedBackendURL
        }
        userName = UserDefaults.standard.string(forKey: "userName") ?? ""
        userEmail = UserDefaults.standard.string(forKey: "userEmail") ?? ""
        isAuthenticated = UserDefaults.standard.string(forKey: "authToken") != nil
    }

    @MainActor
    func authenticate(mode: AuthRoute, name: String, email: String, password: String) async -> Bool {
        authError = nil

        do {
            let response = try await BackendClient(baseURLString: backendURL).authenticate(
                mode: mode,
                name: name,
                email: email,
                password: password
            )
            UserDefaults.standard.set(response.token, forKey: "authToken")
            UserDefaults.standard.set(response.user.name, forKey: "userName")
            UserDefaults.standard.set(response.user.email, forKey: "userEmail")
            userName = response.user.name
            userEmail = response.user.email
            isAuthenticated = true
            return true
        } catch {
            authError = error.localizedDescription
            isAuthenticated = false
            return false
        }
    }

    @MainActor
    func validateSavedSession() async {
        guard let token else { return }

        do {
            let user = try await BackendClient(baseURLString: backendURL).fetchCurrentUser(token: token)
            UserDefaults.standard.set(user.name, forKey: "userName")
            UserDefaults.standard.set(user.email, forKey: "userEmail")
            userName = user.name
            userEmail = user.email
            isAuthenticated = true
        } catch {
            authError = "Please sign in again."
            signOut()
        }
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: "authToken")
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: "userEmail")
        userName = ""
        userEmail = ""
        isAuthenticated = false
    }
}

struct BackendClient {
    let baseURLString: String

    private var baseURL: URL {
        guard
            let enteredURL = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = enteredURL.scheme,
            let host = enteredURL.host
        else {
            return URL(string: defaultBackendURL)!
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = enteredURL.port
        return components.url ?? URL(string: defaultBackendURL)!
    }

    func authenticate(mode: AuthRoute, name: String, email: String, password: String) async throws -> AuthResponse {
        let path = mode == .register ? "/auth/register" : "/auth/login"
        var payload: [String: String] = [
            "email": email,
            "password": password
        ]
        if mode == .register {
            payload["name"] = name
        }

        return try await post(path: path, payload: payload, token: nil)
    }

    func recordSensorWindow(token: String, record: SensorRecordPayload) async throws {
        let _: SaveRecordResponse = try await post(path: "/sensor-records", payload: record, token: token)
    }

    func fetchSensorRecords(token: String, limit: Int = 200) async throws -> [SensorRecord] {
        let response: SensorRecordsResponse = try await get(path: "/sensor-records?limit=\(limit)", token: token)
        return response.records
    }

    func fetchCurrentUser(token: String) async throws -> BackendUser {
        let response: CurrentUserResponse = try await get(path: "/auth/me", token: token)
        return response.user
    }

    func fetchHealth() async throws -> HealthResponse {
        try await get(path: "/health", token: nil)
    }

    private func get<ResponseBody: Decodable>(path: String, token: String?) async throws -> ResponseBody {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        components?.path = parts[0].hasPrefix("/") ? parts[0] : "/" + parts[0]
        if parts.count > 1 {
            components?.query = parts[1]
        }

        guard let url = components?.url else {
            throw BackendError.requestFailed("Unable to reach CarePulse.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.requestFailed("No response from CarePulse.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorResponse.self, from: data).error) ?? "CarePulse request failed."
            throw BackendError.requestFailed(message)
        }

        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        payload: RequestBody,
        token: String?
    ) async throws -> ResponseBody {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.requestFailed("No response from CarePulse.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorResponse.self, from: data).error) ?? "CarePulse request failed."
            throw BackendError.requestFailed(message)
        }

        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }
}

enum BackendError: LocalizedError {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message): message
        }
    }
}

struct BackendErrorResponse: Decodable {
    let error: String
}

struct AuthResponse: Decodable {
    let token: String
    let user: BackendUser
}

struct BackendUser: Decodable {
    let id: String
    let name: String
    let email: String
}

struct SaveRecordResponse: Decodable {
    let ok: Bool
    let recordId: String
}

struct SensorRecordsResponse: Decodable {
    let records: [SensorRecord]
}

struct CurrentUserResponse: Decodable {
    let user: BackendUser
}

struct HealthResponse: Decodable {
    let ok: Bool
    let service: String
    let users: Int
    let sensorRecords: Int
}

struct SensorRecord: Decodable, Identifiable {
    let id: String
    let recordedAt: TimeInterval
    let activity: String
    let confidence: Double
    let features: SensorFeaturePayload
    let samples: [SensorSamplePayload]

    var recordedDate: Date {
        Date(timeIntervalSince1970: recordedAt)
    }

    var activityKind: ActivityKind {
        ActivityKind(rawValue: activity) ?? .inactivity
    }
}

extension SensorFeaturePayload: Decodable {}
extension SensorSamplePayload: Decodable {}

enum AuthRoute {
    case onboarding
    case signIn
    case register
}

enum MainTab: Hashable {
    case dashboard
    case trends
    case health
    case alerts
    case profile
}

enum ActivityKind: String, CaseIterable {
    case walking = "Walking"
    case sitting = "Sitting"
    case standing = "Standing"
    case inactivity = "Inactivity"

    var icon: String {
        switch self {
        case .walking: "figure.walk"
        case .sitting: "chair.fill"
        case .standing: "figure.stand"
        case .inactivity: "figure.fall"
        }
    }

    var color: Color {
        switch self {
        case .walking: .green
        case .sitting: .gray
        case .standing: CareColors.deepBlue
        case .inactivity: .red
        }
    }

    var statusText: String {
        switch self {
        case .walking: "Active"
        case .sitting: "Sitting"
        case .standing: "Standing"
        case .inactivity: "Inactive"
        }
    }
}

struct MotionFeatureVector {
    let meanMagnitude: Double
    let standardDeviation: Double
    let magnitudeRange: Double
    let verticalMean: Double
}

struct LinearSVMActivityClassifier {
    private let weights: [ActivityKind: [Double]] = [
        .walking: [-2.10, 0.60, 7.20, 5.80, 0.20],
        .sitting: [1.40, -0.30, -5.60, -4.30, 0.40],
        .standing: [0.95, 0.20, -3.80, -2.90, 1.40],
        .inactivity: [1.95, -1.50, -6.20, -5.10, -0.20]
    ]

    func predict(_ features: MotionFeatureVector) -> (kind: ActivityKind, confidence: Double) {
        let vector = [1.0, features.meanMagnitude, features.standardDeviation, features.magnitudeRange, features.verticalMean]
        let scores = ActivityKind.allCases.map { kind in
            let score = zip(weights[kind, default: []], vector).map { $0 * $1 }.reduce(0, +)
            return (kind, score)
        }
        .sorted { $0.1 > $1.1 }

        guard let best = scores.first else {
            return (.inactivity, 0)
        }

        let second = scores.dropFirst().first?.1 ?? best.1
        let confidence = min(0.98, max(0.52, 0.52 + abs(best.1 - second) / 8.0))
        return (best.0, confidence)
    }
}

final class ActivityMonitor: ObservableObject {
    @Published var predictedActivity: ActivityKind = .inactivity
    @Published var confidence: Double = 0
    @Published var isMonitoring = false
    @Published var statusMessage = "Activity tracking paused"
    @Published var recordingStatus = "Waiting to sync"
    @Published var latestFeatures = MotionFeatureVector(meanMagnitude: 0, standardDeviation: 0, magnitudeRange: 0, verticalMean: 0)
    @Published var latestSample = SensorSamplePayload(x: 0, y: 0, z: 0)
    @Published var recordedWindowCount = 0

    private let motionManager = CMMotionManager()
    private let classifier = LinearSVMActivityClassifier()
    private var samples: [CMAcceleration] = []
    private var backendURLString = defaultBackendURL
    private var authToken: String?
    private var lastUploadTime = Date.distantPast
    private let windowSize = 24
    var onRecordSaved: (() -> Void)?

    func configureBackend(baseURL: String, token: String?) {
        backendURLString = baseURL
        authToken = token
        recordingStatus = token == nil ? "Waiting to sync" : "Syncing in the background"
    }

    func start() {
        guard motionManager.isAccelerometerAvailable else {
            statusMessage = "Motion sensor unavailable"
            isMonitoring = false
            return
        }

        motionManager.accelerometerUpdateInterval = 0.12
        samples.removeAll()
        isMonitoring = true
        statusMessage = "Getting activity ready"

        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }

            if error != nil {
                self.statusMessage = "Unable to read motion data"
                self.isMonitoring = false
                return
            }

            guard let acceleration = data?.acceleration else { return }
            self.addSample(acceleration)
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        isMonitoring = false
        statusMessage = "Activity tracking paused"
    }

    func toggle() {
        isMonitoring ? stop() : start()
    }

    private func addSample(_ sample: CMAcceleration) {
        latestSample = SensorSamplePayload(x: sample.x, y: sample.y, z: sample.z)
        samples.append(sample)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }

        guard samples.count == windowSize else {
            statusMessage = "Getting activity ready"
            return
        }

        let features = extractFeatures(from: samples)
        let prediction = classifier.predict(features)
        latestFeatures = features
        predictedActivity = prediction.kind
        confidence = prediction.confidence
        statusMessage = "Tracking activity"
        uploadWindowIfNeeded(features: features, prediction: prediction)
    }

    private func extractFeatures(from samples: [CMAcceleration]) -> MotionFeatureVector {
        let magnitudes = samples.map { sqrt(($0.x * $0.x) + ($0.y * $0.y) + ($0.z * $0.z)) }
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let variance = magnitudes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(magnitudes.count)
        let range = (magnitudes.max() ?? 0) - (magnitudes.min() ?? 0)
        let verticalMean = samples.map(\.z).reduce(0, +) / Double(samples.count)

        return MotionFeatureVector(
            meanMagnitude: mean,
            standardDeviation: sqrt(variance),
            magnitudeRange: range,
            verticalMean: verticalMean
        )
    }

    private func uploadWindowIfNeeded(features: MotionFeatureVector, prediction: (kind: ActivityKind, confidence: Double)) {
        guard let authToken else {
            recordingStatus = "Waiting to sync"
            return
        }

        guard Date().timeIntervalSince(lastUploadTime) >= 3 else {
            return
        }

        lastUploadTime = Date()
        let payload = SensorRecordPayload(
            recordedAt: Date().timeIntervalSince1970,
            activity: prediction.kind.rawValue,
            confidence: prediction.confidence,
            features: SensorFeaturePayload(
                meanMagnitude: features.meanMagnitude,
                standardDeviation: features.standardDeviation,
                magnitudeRange: features.magnitudeRange,
                verticalMean: features.verticalMean
            ),
            samples: samples.map { SensorSamplePayload(x: $0.x, y: $0.y, z: $0.z) }
        )

        Task {
            do {
                try await BackendClient(baseURLString: backendURLString).recordSensorWindow(token: authToken, record: payload)
                await MainActor.run {
                    recordedWindowCount += 1
                    recordingStatus = "Synced"
                    onRecordSaved?()
                }
            } catch {
                await MainActor.run {
                    recordingStatus = "Sync will retry"
                }
            }
        }
    }
}

struct SensorRecordPayload: Encodable {
    let recordedAt: TimeInterval
    let activity: String
    let confidence: Double
    let features: SensorFeaturePayload
    let samples: [SensorSamplePayload]
}

struct SensorFeaturePayload: Encodable {
    let meanMagnitude: Double
    let standardDeviation: Double
    let magnitudeRange: Double
    let verticalMean: Double
}

struct SensorSamplePayload: Encodable {
    let x: Double
    let y: Double
    let z: Double
}

@MainActor
final class ActivityDataStore: ObservableObject {
    @Published var records: [SensorRecord] = []
    @Published var loadState = "No activity records yet"
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    func refresh(baseURL: String, token: String?) async {
        guard let token else {
            records = []
            loadState = "Sign in to record activity"
            isLoading = false
            return
        }

        isLoading = true
        do {
            records = try await BackendClient(baseURLString: baseURL).fetchSensorRecords(token: token)
                .sorted { $0.recordedAt < $1.recordedAt }
            loadState = records.isEmpty ? "Start tracking to record activity" : "Updated"
            lastUpdated = Date()
        } catch {
            loadState = "Unable to load records. Check the backend URL."
        }
        isLoading = false
    }

    var latestRecord: SensorRecord? {
        records.sorted { $0.recordedAt < $1.recordedAt }.last
    }

    var totalSamples: Int {
        records.reduce(0) { $0 + $1.samples.count }
    }

    var averageConfidence: Double? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.confidence } / Double(records.count)
    }

    var latestActivity: ActivityKind {
        latestRecord?.activityKind ?? .inactivity
    }

    var activeRecordCount: Int {
        records.filter { $0.activity == ActivityKind.walking.rawValue || $0.activity == ActivityKind.standing.rawValue }.count
    }

    var inactivityRecordCount: Int {
        activityCounts[.inactivity, default: 0]
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "Not refreshed yet" }
        return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }

    var recentRecords: [SensorRecord] {
        Array(records.suffix(5).reversed())
    }

    var activityCounts: [ActivityKind: Int] {
        Dictionary(uniqueKeysWithValues: ActivityKind.allCases.map { kind in
            (kind, records.filter { $0.activity == kind.rawValue }.count)
        })
    }

    var alerts: [CareAlert] {
        guard let latestRecord else { return [] }
        var alerts: [CareAlert] = []

        if latestRecord.activity == ActivityKind.inactivity.rawValue {
            alerts.append(
                CareAlert(
                    category: "Activity",
                    icon: "exclamationmark",
                    title: "Inactivity detected",
                    message: "Your latest saved sensor window was marked inactive.",
                    time: latestRecord.recordedDate.formatted(date: .omitted, time: .shortened),
                    color: .orange
                )
            )
        }

        if latestRecord.confidence < 0.6 {
            alerts.append(
                CareAlert(
                    category: "Activity",
                    icon: "questionmark",
                    title: "Low-confidence reading",
                    message: "The latest saved activity reading may need more movement data.",
                    time: latestRecord.recordedDate.formatted(date: .omitted, time: .shortened),
                    color: .red
                )
            )
        }

        return alerts
    }

    func trendData(for range: TrendRange) -> [TrendData] {
        switch range {
        case .day:
            return aggregateRecords(component: .hour, labels: recentHourLabels)
        case .week:
            return aggregateRecords(component: .weekday, labels: recentWeekdayLabels)
        case .month:
            return aggregateRecords(component: .weekOfYear, labels: recentWeekLabels)
        }
    }

    private func aggregateRecords(component: Calendar.Component, labels: [(String, Int)]) -> [TrendData] {
        let calendar = Calendar.current
        let counts = Dictionary(grouping: records) { record in
            calendar.component(component, from: record.recordedDate)
        }
        .mapValues(\.count)

        return labels.map { label, value in
            TrendData(label: label, records: counts[value, default: 0])
        }
    }

    private var recentHourLabels: [(String, Int)] {
        let calendar = Calendar.current
        let now = Date()
        return stride(from: 5, through: 0, by: -1).map { offset in
            let date = calendar.date(byAdding: .hour, value: -offset, to: now) ?? now
            return (date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))), calendar.component(.hour, from: date))
        }
    }

    private var recentWeekdayLabels: [(String, Int)] {
        let calendar = Calendar.current
        let now = Date()
        return stride(from: 6, through: 0, by: -1).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            return (date.formatted(.dateTime.weekday(.abbreviated)), calendar.component(.weekday, from: date))
        }
    }

    private var recentWeekLabels: [(String, Int)] {
        let calendar = Calendar.current
        let now = Date()
        return stride(from: 3, through: 0, by: -1).map { offset in
            let date = calendar.date(byAdding: .weekOfYear, value: -offset, to: now) ?? now
            return ("W\(calendar.component(.weekOfYear, from: date))", calendar.component(.weekOfYear, from: date))
        }
    }
}

enum TrendRange: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }
}

private enum CareColors {
    static let navy = Color(red: 0.03, green: 0.15, blue: 0.34)
    static let deepBlue = Color(red: 0.04, green: 0.32, blue: 0.65)
    static let cyan = Color(red: 0.04, green: 0.70, blue: 0.73)
    static let teal = Color(red: 0.08, green: 0.66, blue: 0.62)
    static let page = Color(red: 0.95, green: 0.97, blue: 1.00)
    static let ink = Color(red: 0.04, green: 0.11, blue: 0.25)
    static let muted = Color(red: 0.43, green: 0.50, blue: 0.61)
}

struct OnboardingView: View {
    let onGetStarted: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CareColors.navy, CareColors.deepBlue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                PulseHeartLogo(size: 118)

                VStack(spacing: 8) {
                    Text("CarePulse AI")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Smart Activity. Smarter Health.")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.86))
                }

                Spacer()

                VStack(spacing: 14) {
                    Button(action: onGetStarted) {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                LinearGradient(
                                    colors: [CareColors.cyan, CareColors.teal],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.white)

                    Button(action: onSignIn) {
                        Text("Sign In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 30)

                Text("by WellnessAI Labs")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 18)
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var activityMonitor = ActivityMonitor()
    @StateObject private var activityData = ActivityDataStore()
    @State private var selectedTab: MainTab = .dashboard
    @State private var isMenuPresented = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                activityMonitor: activityMonitor,
                activityData: activityData,
                onOpenMenu: { isMenuPresented = true },
                onShowAlerts: { selectedTab = .alerts }
            )
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(MainTab.dashboard)

            TrendsView(activityData: activityData)
                .tabItem { Label("Trends", systemImage: "chart.bar.xaxis") }
                .tag(MainTab.trends)

            HealthMetricsView(activityMonitor: activityMonitor, activityData: activityData)
                .tabItem { Label("Health", systemImage: "heart.text.square.fill") }
                .tag(MainTab.health)

            AlertsView(activityData: activityData)
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .tag(MainTab.alerts)

            ProfileView(activityData: activityData)
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(MainTab.profile)
        }
        .tint(CareColors.deepBlue)
        .sheet(isPresented: $isMenuPresented) {
            MenuSheet(selectedTab: $selectedTab, isPresented: $isMenuPresented)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            activityMonitor.configureBackend(baseURL: session.backendURL, token: session.token)
            activityMonitor.onRecordSaved = {
                Task {
                    await activityData.refresh(baseURL: session.backendURL, token: session.token)
                }
            }
            activityMonitor.start()
            Task {
                await session.validateSavedSession()
                await activityData.refresh(baseURL: session.backendURL, token: session.token)
            }
        }
        .onChange(of: session.backendURL) { _, newValue in
            activityMonitor.configureBackend(baseURL: newValue, token: session.token)
            Task {
                await activityData.refresh(baseURL: newValue, token: session.token)
            }
        }
        .onDisappear {
            activityMonitor.stop()
        }
    }
}

struct DashboardView: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var activityData: ActivityDataStore
    let onOpenMenu: () -> Void
    let onShowAlerts: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ActivityRing(activity: displayActivity, confidence: displayConfidence)
                        .padding(.top, 8)

                    LiveMonitoringCard(activityMonitor: activityMonitor, activityData: activityData)

                    HStack(spacing: 12) {
                        StatCard(icon: "waveform.path.ecg", title: "Records", value: "\(activityData.records.count)", color: CareColors.deepBlue)
                        StatCard(icon: "sensor.tag.radiowaves.forward", title: "Samples", value: "\(activityData.totalSamples)", color: CareColors.cyan)
                        StatCard(icon: "checkmark.seal.fill", title: "Avg. Confidence", value: averageConfidenceText, color: CareColors.teal)
                    }

                    SectionHeader(title: "Saved Activity Status", trailing: displayActivity.statusText)

                    HStack(spacing: 10) {
                        ForEach(ActivityKind.allCases, id: \.self) { activity in
                            ActivityStatus(
                                icon: activity.icon,
                                title: activity.rawValue,
                                color: activity.color,
                                isActive: displayActivity == activity
                            )
                        }
                    }

                    SectionHeader(title: "Recent Records", trailing: activityData.lastUpdatedText)

                    if activityData.records.isEmpty {
                        EmptyStateView(
                            icon: "waveform.path.ecg",
                            title: "No saved records yet",
                            message: activityData.loadState
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(activityData.recentRecords) { record in
                                SensorRecordRow(record: record)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenMenu) {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowAlerts) {
                        Image(systemName: "bell.fill")
                    }
                }
            }
        }
    }

    private var averageConfidenceText: String {
        guard let averageConfidence = activityData.averageConfidence else {
            return "--"
        }
        return "\(Int(averageConfidence * 100))%"
    }

    private var displayActivity: ActivityKind {
        activityData.latestRecord?.activityKind ?? activityMonitor.predictedActivity
    }

    private var displayConfidence: Double {
        activityData.latestRecord?.confidence ?? activityMonitor.confidence
    }
}

struct AuthenticationView: View {
    @EnvironmentObject private var session: AppSession
    let mode: AuthRoute
    let onBack: () -> Void

    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showError = false
    @State private var isSubmitting = false
    @State private var connectionStatus = "Not tested"
    @State private var isTestingConnection = false

    private var isRegistering: Bool {
        mode == .register
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PulseHeartLogo(size: 92)
                        .padding(.top, 18)

                    VStack(spacing: 6) {
                        Text(isRegistering ? "Create Account" : "Welcome Back")
                            .font(.largeTitle.bold())
                            .foregroundStyle(CareColors.ink)

                        Text(isRegistering ? "Set up your CarePulse profile." : "Sign in to continue tracking your health.")
                            .font(.subheadline)
                            .foregroundStyle(CareColors.muted)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 14) {
                        if isRegistering {
                            AuthField(title: "Full Name", text: $fullName, systemImage: "person.fill")
                        }
                        AuthField(title: "Email", text: $email, systemImage: "envelope.fill", keyboard: .emailAddress)
                        SecureAuthField(title: "Password", text: $password)
                    }
                    .padding()
                    .background(CardBackground())

                    BackendConnectionPanel(
                        backendURL: $session.backendURL,
                        status: connectionStatus,
                        isTesting: isTestingConnection,
                        onTest: testConnection
                    )

                    if showError || session.authError != nil {
                        Text(session.authError ?? "Enter a valid email and password to continue.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: authenticate) {
                        Text(isSubmitting ? "Connecting..." : (isRegistering ? "Create Account" : "Sign In"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(LinearGradient(colors: [CareColors.cyan, CareColors.teal], startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.white)
                    .disabled(isSubmitting)

                    Button(action: onBack) {
                        Text("Back")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .overlay(Capsule().stroke(CareColors.deepBlue.opacity(0.24), lineWidth: 1))
                    }
                    .foregroundStyle(CareColors.deepBlue)
                }
                .padding(24)
            }
            .background(AppBackground())
            .navigationTitle(isRegistering ? "Register" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func authenticate() {
        let requiredNameIsReady = !isRegistering || !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emailIsReady = email.contains("@") && email.contains(".")
        let passwordIsReady = password.count >= 4

        guard requiredNameIsReady, emailIsReady, passwordIsReady else {
            showError = true
            return
        }

        showError = false
        isSubmitting = true
        Task {
            _ = await session.authenticate(
                mode: mode,
                name: fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            isSubmitting = false
        }
    }

    private func testConnection() {
        connectionStatus = "Checking server..."
        isTestingConnection = true

        Task {
            do {
                let health = try await BackendClient(baseURLString: session.backendURL).fetchHealth()
                connectionStatus = health.ok ? "Connected to \(health.service)" : "Server responded, but is not ready"
            } catch {
                connectionStatus = "Cannot reach server. Use your Mac's Wi-Fi IP, not localhost."
            }
            isTestingConnection = false
        }
    }
}

struct AuthField: View {
    let title: String
    @Binding var text: String
    let systemImage: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(CareColors.cyan)
                .frame(width: 22)
            TextField(title, text: $text)
                .textInputAutocapitalization(keyboard == .emailAddress || keyboard == .URL ? .never : .words)
                .keyboardType(keyboard)
                .autocorrectionDisabled(keyboard == .emailAddress || keyboard == .URL)
                .foregroundStyle(CareColors.ink)
                .tint(CareColors.deepBlue)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecureAuthField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(CareColors.cyan)
                .frame(width: 22)
            SecureField(title, text: $text)
                .foregroundStyle(CareColors.ink)
                .tint(CareColors.deepBlue)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct BackendConnectionPanel: View {
    @Binding var backendURL: String
    let status: String
    let isTesting: Bool
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Data Source", systemImage: "externaldrive.connected.to.line.below")
                .font(.headline)
                .foregroundStyle(CareColors.ink)

            AuthField(title: "Backend URL", text: $backendURL, systemImage: "link", keyboard: .URL)

            Text("On iPhone, use your Mac's Wi-Fi IP address, for example http://192.168.1.25:8765.")
                .font(.caption)
                .foregroundStyle(CareColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(status, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button(action: onTest) {
                    Label(isTesting ? "Testing" : "Test", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(CareColors.deepBlue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(isTesting || backendURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(CardBackground())
    }

    private var statusIcon: String {
        if status.localizedCaseInsensitiveContains("connected") {
            return "checkmark.circle.fill"
        }
        if status.localizedCaseInsensitiveContains("cannot") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        if status.localizedCaseInsensitiveContains("connected") {
            return CareColors.teal
        }
        if status.localizedCaseInsensitiveContains("cannot") {
            return .red
        }
        return CareColors.muted
    }
}

struct MenuSheet: View {
    @EnvironmentObject private var session: AppSession
    @Binding var selectedTab: MainTab
    @Binding var isPresented: Bool

    private let items: [(MainTab, String, String)] = [
        (.dashboard, "Dashboard", "house.fill"),
        (.trends, "Trends", "chart.bar.xaxis"),
        (.health, "Health", "heart.text.square.fill"),
        (.alerts, "Alerts", "bell.fill"),
        (.profile, "Profile", "person.fill")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        PulseHeartLogo(size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CarePulse AI")
                                .font(.headline)
                            Text("Connected health dashboard")
                                .font(.subheadline)
                                .foregroundStyle(CareColors.muted)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Navigate") {
                    ForEach(items, id: \.0) { item in
                        Button {
                            selectedTab = item.0
                            isPresented = false
                        } label: {
                            Label(item.1, systemImage: item.2)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        session.signOut()
                        isPresented = false
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct ActivityRing: View {
    let activity: ActivityKind
    let confidence: Double

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.cyan.opacity(0.18), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: 0.78)
                    .stroke(
                        LinearGradient(colors: [CareColors.deepBlue, CareColors.cyan, CareColors.teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Image(systemName: activity.icon)
                        .font(.title2)
                        .foregroundStyle(activity.color)
                    Text("Live Activity")
                        .font(.subheadline)
                    Text(activity.rawValue)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(CareColors.ink)
                        .minimumScaleFactor(0.58)
                        .lineLimit(1)
                    Text("\(Int(confidence * 100))% confidence")
                        .font(.headline)
                }
            }
            .frame(width: 220, height: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(CardBackground())
    }
}

struct LiveMonitoringCard: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var activityData: ActivityDataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Activity Tracking", systemImage: activityMonitor.isMonitoring ? "figure.walk.motion" : "pause.circle.fill")
                        .font(.headline)
                        .foregroundStyle(CareColors.ink)
                    Text(activityMonitor.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(CareColors.muted)
                }
                Spacer()
                Button(action: activityMonitor.toggle) {
                    Label(activityMonitor.isMonitoring ? "Pause" : "Resume", systemImage: activityMonitor.isMonitoring ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(activityMonitor.isMonitoring ? Color.orange : CareColors.teal)
                        .clipShape(Capsule())
                }
                .accessibilityLabel(activityMonitor.isMonitoring ? "Pause monitoring" : "Start monitoring")
            }

            Text("CarePulse keeps your current activity updated automatically while you use the app.")
                .font(.subheadline)
                .foregroundStyle(CareColors.muted)

            HStack(spacing: 10) {
                StatusPill(icon: "icloud.and.arrow.up", title: "Sync", value: activityMonitor.recordingStatus)
                StatusPill(icon: "clock.arrow.circlepath", title: "Data", value: activityData.isLoading ? "Refreshing" : activityData.loadState)
            }

            HStack(spacing: 10) {
                SensorValuePill(axis: "X", value: activityMonitor.latestSample.x)
                SensorValuePill(axis: "Y", value: activityMonitor.latestSample.y)
                SensorValuePill(axis: "Z", value: activityMonitor.latestSample.z)
            }
        }
        .padding()
        .background(CardBackground())
    }
}

struct StatusPill: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(CareColors.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CareColors.muted)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(CareColors.ink)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(CareColors.page)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SensorValuePill: View {
    let axis: String
    let value: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(axis)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CareColors.muted)
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.subheadline.bold())
                .foregroundStyle(CareColors.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(CareColors.page)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SensorRecordRow: View {
    let record: SensorRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.activityKind.icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(record.activityKind.color)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.activity)
                    .font(.headline)
                    .foregroundStyle(CareColors.ink)
                Text(record.recordedDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(CareColors.muted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(record.confidence * 100))%")
                    .font(.headline)
                    .foregroundStyle(CareColors.ink)
                Text("\(record.samples.count) samples")
                    .font(.caption2)
                    .foregroundStyle(CareColors.muted)
            }
        }
        .padding()
        .background(CardBackground())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(CareColors.cyan)
                .frame(width: 70, height: 70)
                .background(CareColors.page)
                .clipShape(Circle())

            Text(title)
                .font(.headline)
                .foregroundStyle(CareColors.ink)

            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(CareColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(CardBackground())
    }
}

struct TrendsView: View {
    @ObservedObject var activityData: ActivityDataStore
    @State private var range: TrendRange = .week

    private var chartData: [TrendData] {
        activityData.trendData(for: range)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("", selection: $range) {
                        ForEach(TrendRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)

                    if activityData.records.isEmpty {
                        EmptyStateView(
                            icon: "chart.bar.xaxis",
                            title: "No activity trends yet",
                            message: "Keep activity tracking on. Trends will appear after CarePulse records real sensor windows."
                        )
                    } else {
                        Chart(chartData) { item in
                            BarMark(
                                x: .value("Time", item.label),
                                y: .value("Recorded windows", item.records)
                            )
                            .foregroundStyle(CareColors.deepBlue)
                        }
                        .frame(height: 230)
                        .padding()
                        .background(CardBackground())

                        HStack(spacing: 12) {
                            InsightCard(icon: "waveform.path.ecg", title: "Records", value: "\(activityData.records.count)")
                            InsightCard(icon: "sensor.tag.radiowaves.forward", title: "Samples", value: "\(activityData.totalSamples)")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Activity Mix", trailing: activityData.lastUpdatedText)
                            ForEach(ActivityKind.allCases, id: \.self) { activity in
                                ActivityMixRow(
                                    activity: activity,
                                    count: activityData.activityCounts[activity, default: 0],
                                    total: max(activityData.records.count, 1)
                                )
                            }
                        }
                        .padding()
                        .background(CardBackground())
                    }
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("Activity Trends")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct HealthMetricsView: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var activityData: ActivityDataStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Recorded Activity")
                        .font(.title3.bold())

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        MetricTile(icon: savedActivity.icon, title: "Latest Saved", value: savedActivity.rawValue, note: latestRecordText, color: savedActivity.color)
                        MetricTile(icon: "checkmark.seal.fill", title: "Avg. Confidence", value: averageConfidenceText, note: "From saved records", color: CareColors.teal)
                        MetricTile(icon: "waveform.path.ecg", title: "Saved Records", value: "\(activityData.records.count)", note: activityData.loadState, color: CareColors.deepBlue)
                        MetricTile(icon: "sensor.tag.radiowaves.forward", title: "Sensor Samples", value: "\(activityData.totalSamples)", note: "From saved records", color: CareColors.cyan)
                    }

                    Text("Live Reading")
                        .font(.title3.bold())
                        .padding(.top, 6)

                    MetricTile(
                        icon: activityMonitor.predictedActivity.icon,
                        title: "Current Sensor Reading",
                        value: activityMonitor.predictedActivity.rawValue,
                        note: "\(Int(activityMonitor.confidence * 100))% confidence",
                        color: activityMonitor.predictedActivity.color
                    )

                    Text("Unavailable Metrics")
                        .font(.title3.bold())
                        .padding(.top, 6)

                    VStack(spacing: 12) {
                        UnrecordedMetricRow(icon: "heart.fill", title: "Heart Rate")
                        UnrecordedMetricRow(icon: "drop.fill", title: "Blood Glucose")
                        UnrecordedMetricRow(icon: "moon.fill", title: "Sleep")
                        UnrecordedMetricRow(icon: "flame.fill", title: "Calories")
                    }
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("Health Metrics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var savedActivity: ActivityKind {
        activityData.latestRecord?.activityKind ?? .inactivity
    }

    private var latestRecordText: String {
        guard let latestRecord = activityData.latestRecord else {
            return "No saved reading yet"
        }
        return latestRecord.recordedDate.formatted(date: .abbreviated, time: .shortened)
    }

    private var averageConfidenceText: String {
        guard let averageConfidence = activityData.averageConfidence else { return "--" }
        return "\(Int(averageConfidence * 100))%"
    }
}

struct AlertsView: View {
    @ObservedObject var activityData: ActivityDataStore
    @State private var filter = "All"
    @State private var showHistory = false

    private var visibleAlerts: [CareAlert] {
        filter == "All" ? activityData.alerts : activityData.alerts.filter { $0.category == filter }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $filter) {
                        Text("All").tag("All")
                        Text("Activity").tag("Activity")
                    }
                    .pickerStyle(.segmented)

                    if visibleAlerts.isEmpty {
                        EmptyStateView(
                            icon: "bell.slash",
                            title: "No recorded alerts",
                            message: "CarePulse will show alerts here only when they are based on real recorded activity."
                        )
                    } else {
                        ForEach(visibleAlerts) { alert in
                            AlertCard(icon: alert.icon, title: alert.title, message: alert.message, time: alert.time, color: alert.color)
                        }
                    }

                    Button(action: { showHistory = true }) {
                        Text("View History")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(LinearGradient(colors: [CareColors.cyan, CareColors.teal], startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(.top, 46)
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("Alerts & Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showHistory) {
                AlertHistoryView(alerts: activityData.alerts)
                    .presentationDetents([.medium])
            }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var session: AppSession
    @ObservedObject var activityData: ActivityDataStore
    @State private var connectionStatus = "Not tested"
    @State private var isTestingConnection = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    PulseHeartLogo(size: 96)
                    Text("CarePulse AI")
                        .font(.largeTitle.bold())
                    Text("Personalized activity tracking, health insights, and gentle recommendations.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(CareColors.muted)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account")
                            .font(.headline)
                        Label(session.userName.isEmpty ? "Signed in" : session.userName, systemImage: "person.fill")
                        Label(session.userEmail, systemImage: "envelope.fill")
                            .foregroundStyle(CareColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(CardBackground())

                    BackendConnectionPanel(
                        backendURL: $session.backendURL,
                        status: "\(connectionStatus) • \(activityData.lastUpdatedText)",
                        isTesting: isTestingConnection,
                        onTest: testConnection
                    )

                    HStack(spacing: 12) {
                        InsightCard(icon: "waveform.path.ecg", title: "Saved Records", value: "\(activityData.records.count)")
                        InsightCard(icon: "figure.walk.motion", title: "Active Windows", value: "\(activityData.activeRecordCount)")
                    }

                    Button(role: .destructive) {
                        session.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .overlay(Capsule().stroke(Color.red.opacity(0.28), lineWidth: 1))
                    }
                    .padding(.top, 10)
                }
                .padding(24)
            }
            .background(AppBackground())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func testConnection() {
        connectionStatus = "Checking server..."
        isTestingConnection = true

        Task {
            do {
                let health = try await BackendClient(baseURLString: session.backendURL).fetchHealth()
                connectionStatus = health.ok ? "Connected to \(health.service)" : "Server responded, but is not ready"
            } catch {
                connectionStatus = "Cannot reach server. Use your Mac's Wi-Fi IP, not localhost."
            }
            isTestingConnection = false
        }
    }
}

struct PulseHeartLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(LinearGradient(colors: [CareColors.deepBlue, CareColors.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

            PulseLine()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.88, height: size * 0.32)
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

struct PulseLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: mid))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.39, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.63, y: rect.maxY * 0.22))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: mid))
        path.addLine(to: CGPoint(x: rect.maxX, y: mid))
        return path
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(CareColors.ink)
            Text(title)
                .font(.caption)
                .foregroundStyle(CareColors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(CardBackground())
    }
}

struct ActivityStatus: View {
    let icon: String
    let title: String
    let color: Color
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isActive ? .white : color)
                .frame(width: 54, height: 44)
                .background(isActive ? color : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? CareColors.ink : CareColors.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SectionHeader: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(trailing)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(CareColors.teal)
                .clipShape(Capsule())
        }
    }
}

struct InsightCard: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(CareColors.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(CareColors.muted)
                Text(value)
                    .font(.title2.bold())
                    .foregroundStyle(CareColors.ink)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(CardBackground())
    }
}

struct ActivityMixRow: View {
    let activity: ActivityKind
    let count: Int
    let total: Int

    private var progress: Double {
        min(1, max(0, Double(count) / Double(total)))
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label(activity.rawValue, systemImage: activity.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CareColors.ink)
                Spacer()
                Text("\(count)")
                    .font(.subheadline.bold())
                    .foregroundStyle(CareColors.muted)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(CareColors.page)
                    Capsule()
                        .fill(activity.color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }
}

struct UnrecordedMetricRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(CareColors.muted)
                .frame(width: 38, height: 38)
                .background(CareColors.page)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(CareColors.ink)
                Text("Not connected to a sensor source yet")
                    .font(.subheadline)
                    .foregroundStyle(CareColors.muted)
            }

            Spacer()
        }
        .padding()
        .background(CardBackground())
    }
}

struct MetricTile: View {
    let icon: String
    let title: String
    let value: String
    let note: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(CareColors.ink)
            Text(value)
                .font(.title3.bold())
            Text(note)
                .font(.caption2)
                .foregroundStyle(CareColors.teal)
        }
        .frame(maxWidth: .infinity, minHeight: 126)
        .background(CardBackground())
    }
}

struct RecommendationRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(CareColors.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(CareColors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(CareColors.muted)
        }
        .padding()
        .background(CardBackground())
    }
}

struct AlertCard: View {
    let icon: String
    let title: String
    let message: String
    let time: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: icon)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(CareColors.muted)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(CareColors.ink)
            }
        }
        .padding()
        .background(CardBackground())
    }
}

struct AlertHistoryView: View {
    let alerts: [CareAlert]

    var body: some View {
        NavigationStack {
            List {
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(alert.title, systemImage: alert.icon)
                                .font(.headline)
                                .foregroundStyle(CareColors.ink)
                            Spacer()
                            Text(alert.time)
                                .font(.caption)
                                .foregroundStyle(CareColors.muted)
                        }
                        Text(alert.message)
                            .font(.subheadline)
                            .foregroundStyle(CareColors.muted)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Alert History")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct InsightsListView: View {
    private let insights = [
        ("Activity consistency", "Your strongest activity windows are late morning and early evening."),
        ("Step pace", "Weekly steps are trending 8% above your previous baseline."),
        ("Recovery", "Sleep and activity balance look steady for the last 7 days.")
    ]

    var body: some View {
        NavigationStack {
            List(insights, id: \.0) { insight in
                VStack(alignment: .leading, spacing: 5) {
                    Text(insight.0)
                        .font(.headline)
                    Text(insight.1)
                        .font(.subheadline)
                        .foregroundStyle(CareColors.muted)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RecommendationDetailView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PulseHeartLogo(size: 72)
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(CareColors.ink)
            Text(message)
                .font(.body)
                .foregroundStyle(CareColors.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(AppBackground())
        .navigationTitle("Recommendation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white)
            .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 8)
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [CareColors.page, Color.white], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct TrendData: Identifiable {
    let id = UUID()
    let label: String
    let records: Int
}

struct CareAlert: Identifiable {
    let id = UUID()
    let category: String
    let icon: String
    let title: String
    let message: String
    let time: String
    let color: Color
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppSession())
    }
}
