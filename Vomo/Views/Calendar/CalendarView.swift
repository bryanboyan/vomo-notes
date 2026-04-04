import SwiftUI

struct CalendarView: View {
    @Environment(VaultManager.self) var vault
    @Binding var navigationPath: [VaultFile]
    @State private var selectedMonth = Date()
    @State private var diaryIndex: DiaryIndex = DiaryIndex()
    @State private var selectedDate: Date?
    @State private var swipeOffset: CGFloat = 0
    @State private var slideDirection: SlideDirection = .none

    private enum SlideDirection { case none, left, right }

    private let calendar = Calendar.current
    private let dayColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            calendarGrid
            Spacer()

            if let date = selectedDate, let file = diaryIndex.file(for: date) {
                selectedNotePreview(file: file)
            }
        }
        .navigationTitle("Calendar")
        .task {
            await rebuildIndex()
        }
        .onChange(of: vault.files.count) { _, _ in
            Task { await rebuildIndex() }
        }
    }

    // MARK: - Month Navigation

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation { shiftMonth(-1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .foregroundStyle(Color.obsidianPurple)
            }

            Spacer()

            Text(monthYearString)
                .font(.title3.bold())

            Spacer()

            Button {
                withAnimation { shiftMonth(1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .foregroundStyle(Color.obsidianPurple)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedMonth)
    }

    private func shiftMonth(_ delta: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: delta, to: selectedMonth) {
            selectedMonth = newMonth
        }
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        LazyVGrid(columns: dayColumns, spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
                    .frame(height: 24)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let days = daysInMonth()
        return LazyVGrid(columns: dayColumns, spacing: 4) {
            ForEach(days, id: \.self) { date in
                if let date {
                    dayCell(date: date)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
        .padding(.horizontal, 8)
        .id(selectedMonth)
        .transition(.asymmetric(
            insertion: .move(edge: slideDirection == .left ? .trailing : .leading),
            removal: .move(edge: slideDirection == .left ? .leading : .trailing)
        ))
        .offset(x: swipeOffset)
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    swipeOffset = value.translation.width
                }
                .onEnded { value in
                    let screenWidth = UIScreen.main.bounds.width
                    let threshold = screenWidth * 0.15
                    let predicted = value.predictedEndTranslation.width
                    if value.translation.width < -threshold || predicted < -threshold * 1.5 {
                        slideDirection = .left
                        withAnimation(.easeInOut(duration: 0.25)) {
                            swipeOffset = 0
                            shiftMonth(1)
                        }
                    } else if value.translation.width > threshold || predicted > threshold * 1.5 {
                        slideDirection = .right
                        withAnimation(.easeInOut(duration: 0.25)) {
                            swipeOffset = 0
                            shiftMonth(-1)
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            swipeOffset = 0
                        }
                    }
                }
        )
        .clipped()
    }

    private func dayCell(date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let hasNote = diaryIndex.file(for: date) != nil
        let isToday = calendar.isDateInToday(date)
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedDate = date
            }
            // Auto-navigate if note exists
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.subheadline)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(
                        isSelected ? .white :
                        isToday ? Color.obsidianPurple :
                        .primary
                    )

                Circle()
                    .fill(hasNote ? Color.obsidianPurple : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.obsidianPurple.clipShape(RoundedRectangle(cornerRadius: 8)) :
                nil
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Note Preview

    private func selectedNotePreview(file: VaultFile) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                vault.markAsRecent(file)
                navigationPath.append(file)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Color.obsidianPurple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        if !file.contentSnippet.isEmpty {
                            Text(file.contentSnippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
            }
            .buttonStyle(.plain)
            .background(Color.cardBackground)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Calendar Math

    private func daysInMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: selectedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        return days
    }

    private func rebuildIndex() async {
        let files = vault.files
        let newIndex = await Task.detached(priority: .userInitiated) {
            DiaryIndex(files: files)
        }.value
        diaryIndex = newIndex
    }
}

// MARK: - Diary Index

struct DiaryIndex {
    private var dateToFile: [String: VaultFile] = [:]

    init() {}

    init(files: [VaultFile]) {
        // Try to auto-detect diary folders
        let diaryFolderNames = Set(["daily notes", "diary", "journal", "daily", "dailies"])

        for file in files {
            // Check if in a diary-like folder
            let folderName = file.folderPath.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
            let inDiaryFolder = diaryFolderNames.contains(folderName)

            // Try to extract date from filename
            if let date = extractDate(from: file.title) {
                let key = dateKey(date)
                // Prefer files in diary folders over random matches
                if dateToFile[key] == nil || inDiaryFolder {
                    dateToFile[key] = file
                }
            }
        }
    }

    func file(for date: Date) -> VaultFile? {
        dateToFile[dateKey(date)]
    }

    var totalEntries: Int { dateToFile.count }

    private func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Extract a date from a filename. Supports:
    /// - "2026-03-22" (exact)
    /// - "2026-03-22 Friday" (date prefix)
    /// - "Daily 2026-03-22" (date suffix)
    /// - "2026-03-22_meeting" (date with separator)
    private func extractDate(from title: String) -> Date? {
        // Look for YYYY-MM-DD pattern anywhere in the title
        guard let match = title.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let dateString = String(title[match])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }
}
