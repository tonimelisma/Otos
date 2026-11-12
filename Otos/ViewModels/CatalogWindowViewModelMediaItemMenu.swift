import AppKit
import Foundation
import OSLog

/// Media context menu intents guide
///
/// The context menu on a tile or pane is the menu bar's File and Photo acts for the
/// item under the cursor. This file answers two questions at the moment the menu
/// opens: what the menu contains (`mediaItemMenuModel()`) and what each item does
/// (`performMediaItemCommand(_:)`), which maps every command onto the intent the
/// corresponding menu-bar item already calls.
///
/// The model is built synchronously because the menu is opening now. A right-click
/// on an unselected tile has just changed the selection, so the `@concurrent` Open With
/// build may not have landed; in that case the LaunchServices query runs here, on the
/// MainActor, once, under a signpost — a context-menu open is a one-off user action,
/// not layout, and Finder pays the same cost on every right-click.
extension CatalogWindowViewModel {
    func mediaItemMenuModel() -> MediaItemMenuModel {
        let targets = resolveCurrentTargetFileURLs()
        guard !targets.isEmpty else { return .empty }
        let openWith: OpenWithMenuModel
        if currentTargetFileURLs == targets, openWithMenuTask == nil {
            openWith = openWithMenu
        } else {
            let span = OtosSignpost.ui.beginInterval("OpenWithMenuSync")
            openWith = OpenWithMenuModel.make(targets: targets, workspace: workspace)
            OtosSignpost.ui.endInterval("OpenWithMenuSync", span)
            openWithMenuTask?.cancel()
            openWithMenuTask = nil
            currentTargetFileURLs = targets
            applyOpenWithMenu(openWith)
            OtosLog.ui.notice("op=ui.contextMenu.openWithSync count=\(targets.count, privacy: .public)")
        }
        var model = MediaItemMenuModel(
            openWith: openWith,
            shareItems: targets,
            canReveal: !targets.isEmpty,
            canTrash: canMoveTargetedMediaToTrash
        )
        model.faces = faceMenu()
        return model
    }

    /// The targets' faces as the photo menus and the Info pane offer them (DES-113): each
    /// visible person's in the order their faces come, then the unidentified ones — one
    /// group per face in one photo, and across several photos one group only when no photo
    /// holds more than one, so every act means the faces it names. In a person's photos,
    /// their group comes first and sits at the top level.
    func faceMenu() -> FaceMenu? {
        let selection = targetFaces
        guard !selection.faces.isEmpty else { return nil }
        let single = shownPerson?.id
        var people = selection.people
        if let single, let index = people.firstIndex(of: single) {
            people.remove(at: index)
            people.insert(single, at: 0)
        }
        let severalPhotos = selection.photos.count > 1
        var groups = people.map { person in
            personGroup(person, faces: selection.faces(of: person), in: selection, severalPhotos: severalPhotos, ownPhotos: single == person)
        }
        let unidentified = selection.unidentified
        if !severalPhotos {
            groups += unidentified.map { unidentifiedGroup([$0], in: selection, photoCount: nil) }
        } else if !unidentified.isEmpty, Set(unidentified.map(\.id.asset)).count == unidentified.count {
            groups.append(unidentifiedGroup(unidentified, in: selection, photoCount: unidentified.count))
        }
        return FaceMenu(groups: groups, flattensFirst: single != nil && people.first == single)
    }

    private func personGroup(
        _ person: PersonID,
        faces: [PhotoFace],
        in selection: SelectionFaces,
        severalPhotos: Bool,
        ownPhotos: Bool
    ) -> FaceMenu.Group {
        let ids = faces.map(\.id)
        let notAFace = FaceMenu.Action(title: FaceActTitle.notAFace, command: .notAFace(ids), faces: ids)
        guard let name = peopleIndex.givenName(person) else {
            // An unnamed person is named as a whole: the list merges them into the person
            // chosen, and the count is every photo of them.
            let list = likelyPeople(for: faces, in: selection) { peopleIndex.mergeRefusal(person, into: $0) == nil }
                .map { FaceMenu.Action(title: $0.displayName, command: .nameAs(person, $0.id), faces: ids) }
            var corrections = [notAFace]
            if ownPhotos {
                corrections.insert(FaceMenu.Action(title: FaceActTitle.notTheSamePerson, command: .notPerson(ids), faces: ids), at: 0)
            }
            return FaceMenu.Group(
                kind: .unnamed, person: person, faces: ids, tile: faces.first?.tile,
                photoCount: peopleIndex.summaries[person]?.photoCount ?? Set(ids.map(\.asset)).count,
                listTitle: FaceActTitle.nameThisPerson,
                list: list + [FaceMenu.Action(title: FaceActTitle.newName, command: .addName(person), faces: ids)],
                corrections: corrections
            )
        }
        let list = likelyPeople(for: faces, in: selection) { $0 != person && peopleIndex.moveRefusal(faces, to: $0) == nil }
            .map { FaceMenu.Action(title: $0.displayName, command: .giveTo(ids, $0.id), faces: ids) }
        var corrections = [
            FaceMenu.Action(title: FaceActTitle.notPerson(name), command: .notPerson(ids), faces: ids),
            notAFace,
        ]
        if !severalPhotos, let face = ids.first {
            corrections.append(FaceMenu.Action(title: FaceActTitle.makeKeyPhoto(name), command: .makeKeyPhoto(face, person), faces: [face]))
        }
        return FaceMenu.Group(
            kind: .named(name), person: person, faces: ids, tile: faces.first?.tile,
            photoCount: severalPhotos ? Set(ids.map(\.asset)).count : nil,
            listTitle: FaceActTitle.changeTo,
            list: list + [FaceMenu.Action(title: FaceActTitle.someoneElse, command: .someoneElse(ids), faces: ids)],
            corrections: corrections
        )
    }

    /// Unidentified faces, at most one per photo: `Assign to` gives each person, in each
    /// photo, the face most like them.
    private func unidentifiedGroup(_ faces: [PhotoFace], in selection: SelectionFaces, photoCount: Int?) -> FaceMenu.Group {
        let ids = faces.map(\.id)
        let list = likelyPeople(for: faces, in: selection) { peopleIndex.moveRefusal(faces, to: $0) == nil }
            .map { person in
                let given = faces.count == 1 ? ids : selection.unidentifiedFacesToName(as: person.id)
                return FaceMenu.Action(title: person.displayName, command: .giveTo(given, person.id), faces: given)
            }
        return FaceMenu.Group(
            kind: .unidentified, person: nil, faces: ids, tile: faces.first?.tile,
            photoCount: photoCount,
            listTitle: FaceActTitle.assignTo,
            list: list + [FaceMenu.Action(title: FaceActTitle.someoneElse, command: .someoneElse(ids), faces: ids)],
            corrections: [FaceMenu.Action(title: FaceActTitle.notAFace, command: .notAFace(ids), faces: ids)]
        )
    }

    /// The `NSMenu` for the current targets; grid, filmstrip, loupe and compare all
    /// call this and nothing else.
    func makeMediaItemContextMenu() -> NSMenu? {
        let model = mediaItemMenuModel()
        guard !model.shareItems.isEmpty else { return nil }
        let mode = viewMode.rawValue
        OtosLog.ui.notice("op=ui.contextMenu.open count=\(model.shareItems.count, privacy: .public) mode=\(mode, privacy: .public)")
        return MediaItemContextMenu.make(
            model: model,
            icons: openWithApplicationIcons,
            perform: { [weak self] command in self?.performMediaItemCommand(command) },
            outline: { [weak self] faces in self?.outlineFaces(faces) }
        )
    }

    func performMediaItemCommand(_ command: MediaItemCommand) {
        switch command {
        case .open:
            openTargetsInDefaultApplication()
        case let .openWith(application):
            openTargets(with: application)
        case .openWithOther:
            openTargetsWithChosenApplication()
        case .copy:
            copyCurrentTargets()
        case .share:
            shareCurrentTargets(origin: .contextMenu)
        case .revealInFinder:
            revealCurrentTargetsInFinder()
        case let .choice(choice):
            submitMediaChoice(choice, origin: .contextMenu)
        case .moveToTrash:
            moveTargetedMediaToTrash()
        case let .giveTo(faces, person):
            nameFaces(faces, as: person)
        case let .someoneElse(faces):
            beginNamingFaces(faces)
        case let .nameAs(person, named):
            askMerge(person, into: named)
        case let .addName(person):
            beginEditingPerson(person)
        case let .notPerson(faces):
            removeNames(faces)
        case let .notAFace(faces):
            markNotFaces(faces)
        case let .makeKeyPhoto(face, person):
            makeKeyPhoto(face, of: person)
        }
    }
}
