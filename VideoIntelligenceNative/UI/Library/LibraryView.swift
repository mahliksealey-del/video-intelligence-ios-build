import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingFiles = false
    @State private var showingURL = false
    @State private var showingSettings = false
    @State private var photoItem: PhotosPickerItem?
    @State private var search = ""
    @State private var filter: MediaFilter = .all

    enum MediaFilter: String, CaseIterable, Identifiable { case all = "All", video = "Videos", audio = "Audio", transcribed = "Transcripts"; var id: String { rawValue } }

    private var visibleItems: [MediaLibraryItem] {
        library.items.filter { item in
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)) &&
            (filter == .all || filter == .video && item.kind == .video || filter == .audio && item.kind == .audio || filter == .transcribed && item.transcriptRelativePath != nil)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleItems.isEmpty { emptyState } else { List { ForEach(visibleItems) { item in NavigationLink { MediaReviewView(itemID: item.id) } label: { LibraryRow(item: item) } } } }
            }
            .navigationTitle("Video Intelligence")
            .searchable(text: $search, prompt: "Search your library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showingFiles = true } label: { Label("Choose from Files", systemImage: "folder") }
                        PhotosPicker(selection: $photoItem, matching: .videos) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
                        Button { showingURL = true } label: { Label("Download Direct URL", systemImage: "link") }
                    } label: { Image(systemName: "plus.circle.fill") }.accessibilityLabel("Import media")
                }
            }
            .safeAreaInset(edge: .top) { Picker("Filter", selection: $filter) { ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6).background(.bar) }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await library.importFile(url) } }
                else if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
            }
            .onChange(of: photoItem) { item in guard let item else { return }; Task { if let data = try? await item.loadTransferable(type: Data.self) { await library.importPhotoData(data) } else { library.errorMessage = "The selected video could not be copied from Photos." }; photoItem = nil } }
            .sheet(isPresented: $showingURL) { URLImportView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("Import or Processing Error", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) { Button("OK") { library.errorMessage = nil } } message: { Text(library.errorMessage ?? "Unknown error") }
        }
        .tint(Color(red: 0.12, green: 0.48, blue: 0.29))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.film").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(search.isEmpty ? "Your local media library" : "No matches").font(.title2.weight(.semibold))
            Text(search.isEmpty ? "Import a video or audio file. Media and transcripts stay on this iPhone." : "Try another search or filter.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            if search.isEmpty { Button("Import from Files") { showingFiles = true }.buttonStyle(.borderedProminent) }
        }.padding(32)
    }
}

private struct LibraryRow: View {
    let item: MediaLibraryItem
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind == .video ? "video.fill" : "waveform").font(.title2).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(2)
                Text("\(item.kind.rawValue.capitalized) · \(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) · \(item.importedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                if item.status == .transcribing || item.status == .extractingAudio { ProgressView(value: item.progress) }
                else { Text(item.status == .transcribed ? "\(item.segmentCount) segments" : item.status.rawValue.capitalized).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary) }
            }
        }.padding(.vertical, 5)
    }
}
