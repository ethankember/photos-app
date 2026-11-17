import CloudCore
import Contacts
import Persistence
import SwiftUI

/// A recognised person's face in a circle (from the server's face recognition).
struct PersonFaceView: View {
    let personID: String
    let session: LibrarySession
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(Circle())
            .task(id: personID) { image = await session.personFace(personID) }
            .accessibilityHidden(true)
    }
}

extension CloudPerson {
    /// The name, or "Add Name" for someone not named yet.
    var displayName: String { name.isEmpty ? String(localized: "Add Name") : name }
}

/// Named people first (alphabetically), then the rest in the server's order.
func orderedPeople(_ people: [CloudPerson]) -> [CloudPerson] {
    people.filter { !$0.name.isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        + people.filter(\.name.isEmpty)
}

/// Collections › People: a row of faces.
struct PeopleRow: View {
    let people: [CloudPerson]
    let session: LibrarySession

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(orderedPeople(people).prefix(30)) { person in
                    NavigationLink(value: CollectionRoute.person(person)) {
                        VStack(spacing: 6) {
                            PersonFaceView(personID: person.id, session: session, size: 84)
                            Text(person.displayName)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 88)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
    }
}

/// People › : everyone, three to a row. ··· › Show People from Archive (remembered; also in Collections) adds
/// people seen only in archived photos, and Show People from Hidden (Face ID, this visit only)
/// those seen only in the Hidden album: Immich's people list only counts the Library.
struct PeopleScreen: View {
    let session: LibrarySession
    let initial: [CloudPerson]?
    let bottomInset: CGFloat
    /// The Library's people, and the Archive's when shown.
    @State private var people: [CloudPerson]?
    /// The Hidden album's, kept apart so they go the moment it locks.
    @State private var hiddenPeople: [CloudPerson] = []
    @State private var error: String?
    /// Finding the Archive's or Hidden's people failed (shown, not just an unchanged list).
    @State private var scanError: String?
    @AppStorage(PhotosSettings.peopleFromArchive) private var fromArchive = false
    @State private var fromHidden = false
    @State private var alert: String?

    private var vault: HiddenVault { session.hiddenVault }

    private var shown: [CloudPerson]? {
        guard let people else { return nil }
        return fromHidden ? LibrarySession.merged([people, hiddenPeople]) : people
    }

    private struct LoadKey: Hashable {
        var version: Int
        var archive: Bool
    }

    var body: some View {
        ScrollView {
            if let scanError {
                Label(scanError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            if let people = shown, !people.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 20) {
                    ForEach(orderedPeople(people)) { person in
                        NavigationLink(value: CollectionRoute.person(person)) {
                            VStack(spacing: 6) {
                                PersonFaceView(personID: person.id, session: session, size: 100)
                                Text(person.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset + 20)
            } else if shown == nil, error == nil {
                ProgressView().padding(.top, 80)
            } else {
                ContentUnavailableView("No People", systemImage: "person.2.crop.square.stack",
                                       description: Text(error ?? String(localized: "People appear here when face recognition is turned on for your Cloud server.")))
                    .padding(.top, 60)
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $fromArchive) { Label("Show People from Archive", systemImage: "archivebox") }
                    Toggle(isOn: Binding(get: { fromHidden }, set: { setFromHidden($0) })) {
                        Label("Show People from Hidden", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task(id: LoadKey(version: session.peopleVersion, archive: fromArchive)) {
            await load()
        }
        .task(id: fromHidden) {
            await loadHidden()
        }
        // Hidden locks when the app goes to the background (or on leaving People): its people
        // go at once, not on the next load.
        .onChange(of: vault.state) { _, state in
            guard state != .unlocked else { return }
            hiddenPeople = []
            fromHidden = false
        }
    }

    private func load() async {
        if people == nil { people = initial }
        let library: [CloudPerson]
        do {
            library = try await session.people()
        } catch {
            guard !Task.isCancelled else { return }
            if people == nil { self.error = (error as? CloudError)?.message ?? error.localizedDescription }
            return
        }
        var archive: [CloudPerson] = []
        var failure: String?
        if fromArchive {
            do {
                archive = try await session.people(in: .archive)
            } catch {
                failure = String(localized: "Couldn't find the Archive's people: \((error as? CloudError)?.message ?? error.localizedDescription)")
            }
        }
        guard !Task.isCancelled else { return }
        people = LibrarySession.merged([library, archive])
        error = nil
        scanError = failure
    }

    private func loadHidden() async {
        guard fromHidden, vault.state == .unlocked else {
            hiddenPeople = []
            return
        }
        do {
            let found = try await session.people(in: .locked)
            guard !Task.isCancelled, fromHidden, vault.state == .unlocked else { return }
            hiddenPeople = found
        } catch {
            guard !Task.isCancelled else { return }
            scanError = String(localized: "Couldn't find the Hidden album's people: \((error as? CloudError)?.message ?? error.localizedDescription)")
        }
    }

    /// Hidden needs the Hidden album unlocked (Face ID, with its PIN already on this iPhone).
    /// Collections locks it again when People closes (not when a person opens from here).
    private func setFromHidden(_ show: Bool) {
        guard show else {
            fromHidden = false
            if session.peopleScreenUnlockedHidden {
                session.peopleScreenUnlockedHidden = false
                Task { await vault.lock() }
            }
            return
        }
        guard vault.state != .unlocked else {
            fromHidden = true
            return
        }
        guard vault.hasStoredPin else {
            alert = String(localized: "Open Hidden in Albums first to set it up on this iPhone.")
            return
        }
        Task {
            if await vault.unlock() {
                session.peopleScreenUnlockedHidden = true
                fromHidden = true
            } else {
                alert = vault.errorMessage ?? String(localized: "The Hidden album is still locked.")
                await vault.lock()
            }
        }
    }
}

/// One person's photos, with naming (typed, or from a contact), merging other people into
/// them, and ··· › Show Archived / Show Hidden (Hidden needs Face ID, and locks again on leaving).
struct PersonScreen: View {
    @State var person: CloudPerson
    let session: LibrarySession
    let bottomInset: CGFloat
    @State private var items: [TimelineItem]?
    @State private var error: String?
    @State private var naming = false
    @State private var draftName = ""
    @State private var showsArchived = false
    @State private var showsHidden = false
    /// This page unlocked the Hidden album, so leaving it locks it again (not when it was
    /// already open, e.g. from a photo in the Hidden album).
    @State private var unlockedHere = false
    @State private var merging = false
    @State private var alert: String?
    @State private var reload = 0
    /// Someone seen only in the Archive or Hidden has no Library photos: the page turns those on
    /// by itself, once each (Hidden only when it's already unlocked; it never asks for Face ID).
    @State private var widened: Set<CloudVisibility> = []

    private var vault: HiddenVault { session.hiddenVault }

    private struct LoadKey: Hashable {
        var archived: Bool
        var hidden: Bool
        var reload: Int
    }

    var body: some View {
        CollectionGridScreen(title: person.displayName, items: items ?? [], session: session, bottomInset: bottomInset,
                             isLoading: items == nil && error == nil, emptyMessage: error)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button {
                                draftName = person.name
                                naming = true
                            } label: { Label(person.name.isEmpty ? "Add Name" : "Rename", systemImage: "pencil") }
                            Button { nameFromContact() } label: { Label("Name from Contacts", systemImage: "person.crop.circle") }
                            Button { merging = true } label: { Label("Merge with Others…", systemImage: "person.2.badge.plus") }
                        }
                        Section {
                            Toggle(isOn: $showsArchived) { Label("Show Archived", systemImage: "archivebox") }
                            Toggle(isOn: Binding(get: { showsHidden }, set: { setShowsHidden($0) })) {
                                Label("Show Hidden", systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .alert(person.name.isEmpty ? "Add Name" : "Rename", isPresented: $naming) {
                TextField("Name", text: $draftName)
                    .textContentType(.name)
                Button("Cancel", role: .cancel) {}
                Button("Done") { rename(to: draftName, birthDate: nil) }
            }
            .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $merging) {
                MergePeopleSheet(person: person, session: session) {
                    Task { await refreshPerson() }
                }
            }
            .task(id: LoadKey(archived: showsArchived, hidden: showsHidden, reload: reload)) {
                await load()
            }
            // Hidden locks when the app goes to the background (or elsewhere): its photos go too.
            .onChange(of: vault.state) { _, state in
                guard state != .unlocked, showsHidden else { return }
                showsHidden = false
                unlockedHere = false
            }
            .onDisappear {
                if unlockedHere {
                    unlockedHere = false
                    Task { await vault.lock() }
                }
            }
    }

    private func load() async {
        var visibilities: [CloudVisibility] = [.timeline]
        if showsArchived { visibilities.append(.archive) }
        if showsHidden, vault.state == .unlocked { visibilities.append(.locked) }
        do {
            let loaded = try await session.personItems(person.id, in: visibilities)
            guard !Task.isCancelled else { return }
            if loaded.isEmpty, !showsArchived, !widened.contains(.archive) {
                widened.insert(.archive)
                showsArchived = true
                return
            }
            if loaded.isEmpty, !showsHidden, vault.state == .unlocked, !widened.contains(.locked) {
                widened.insert(.locked)
                showsHidden = true
                return
            }
            items = loaded
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? CloudError)?.message ?? error.localizedDescription
            items = []
        }
    }

    /// Hidden photos need the Hidden album unlocked (Face ID, with its PIN already on this iPhone).
    private func setShowsHidden(_ show: Bool) {
        guard show else {
            showsHidden = false
            if unlockedHere {
                unlockedHere = false
                Task { await vault.lock() }
            }
            return
        }
        guard vault.state != .unlocked else {
            showsHidden = true
            return
        }
        guard vault.hasStoredPin else {
            alert = String(localized: "Open Hidden in Albums first to set it up on this iPhone.")
            return
        }
        Task {
            if await vault.unlock() {
                unlockedHere = true
                showsHidden = true
            } else {
                alert = vault.errorMessage ?? String(localized: "The Hidden album is still locked.")
                await vault.lock()
            }
        }
    }

    /// After a merge: the name may have changed (taken from a merged person) and there are more photos.
    private func refreshPerson() async {
        if let updated = try? await session.person(id: person.id) { person = updated }
        reload += 1
    }

    private func rename(to name: String, birthDate: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do { person = try await session.updatePerson(id: person.id, name: trimmed, birthDate: birthDate) } catch {
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }

    /// The contact's name, and birthday when it has one with a year, go to the server; the
    /// link to the contact is remembered on this iPhone.
    private func nameFromContact() {
        let personID = person.id
        ContactPicker.present { contact in
            guard let contact else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            var birthDate: String?
            if contact.isKeyAvailable(CNContactBirthdayKey), let birthday = contact.birthday,
               let year = birthday.year, let month = birthday.month, let day = birthday.day {
                birthDate = String(format: "%04d-%02d-%02d", year, month, day)
            }
            PersonContacts.link(personID: personID, contactID: contact.identifier)
            rename(to: name, birthDate: birthDate)
        }
    }
}

/// Person › Merge with Others…: choose the people who are really this person. Their photos
/// become this person's; it keeps its name and birthday (taking the first chosen one's when it
/// has none). Immich can't undo a merge, so it's confirmed first.
struct MergePeopleSheet: View {
    let person: CloudPerson
    let session: LibrarySession
    let onMerged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [CloudPerson]?
    /// In the order chosen (the server takes a missing name from the first).
    @State private var chosen: [String] = []
    @State private var query = ""
    @State private var confirming = false
    @State private var isMerging = false
    @State private var error: String?

    private var candidates: [CloudPerson] {
        let others = orderedPeople((people ?? []).filter { $0.id != person.id })
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return others }
        return others.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    private var confirmTitle: String {
        person.name.isEmpty
            ? String(localized: "Merge \(chosen.count) with this person?")
            : String(localized: "Merge \(chosen.count) into \(person.name)?")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(person.name.isEmpty
                         ? "Choose the people who are also this person. Their photos will be this person's."
                         : "Choose the people who are also \(person.name). Their photos will be \(person.name)'s.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }
                    if people == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if candidates.isEmpty {
                        ContentUnavailableView("No People", systemImage: "person.2.crop.square.stack")
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 20) {
                            ForEach(candidates) { other in
                                candidate(other)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Names")
            .navigationTitle("Merge People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMerging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isMerging {
                        ProgressView()
                    } else {
                        Button("Merge") { confirming = true }
                            .disabled(chosen.isEmpty)
                    }
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button("Merge", role: .destructive) { merge() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their photos and faces move to this person. This can't be undone.")
            }
            .interactiveDismissDisabled(isMerging)
            .task { await loadPeople() }
        }
    }

    private func candidate(_ other: CloudPerson) -> some View {
        let isChosen = chosen.contains(other.id)
        return Button {
            if isChosen { chosen.removeAll { $0 == other.id } } else { chosen.append(other.id) }
        } label: {
            VStack(spacing: 6) {
                PersonFaceView(personID: other.id, session: session, size: 92)
                    .overlay {
                        if isChosen {
                            Circle().strokeBorder(.tint, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white, .tint)
                        }
                    }
                Text(other.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(other.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMerging)
        .accessibilityLabel(Text(other.displayName))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func loadPeople() async {
        do {
            people = try await session.listedPeople()
        } catch {
            people = []
            self.error = (error as? CloudError)?.message ?? error.localizedDescription
        }
    }

    private func merge() {
        let others = chosen
        isMerging = true
        error = nil
        Task {
            do {
                try await session.mergePeople(into: person.id, from: others)
                onMerged()
                dismiss()
            } catch {
                // Some may have merged: show what's left.
                self.error = (error as? CloudError)?.message ?? error.localizedDescription
                isMerging = false
                chosen = []
                onMerged()
                await loadPeople()
            }
        }
    }
}

/// Which contact each recognised person was named from (kept on this iPhone only; the
/// server has no field for it).
enum PersonContacts {
    private static let key = "people.contacts"

    static func link(personID: String, contactID: String) {
        var links = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        links[personID] = contactID
        UserDefaults.standard.set(links, forKey: key)
    }

    static func contactID(for personID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[personID]
    }
}
