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

    /// The targets' faces as the context menu groups them: each visible person's in the
    /// order their faces come, then the unidentified ones. With the filter on one person,
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
        let onePhoto = selection.photos.count == 1
        var groups = people.map { person -> FaceMenu.Group in
            let faces = selection.faces(of: person)
            let ids = faces.map(\.id)
            return FaceMenu.Group(
                title: peopleIndex.name(person),
                person: person,
                name: peopleIndex.givenName(person),
                faces: ids,
                choices: choices(for: faces, in: selection, except: person).map { .init(person: $0.id, title: $0.displayName, faces: ids) },
                newPersonFaces: ids,
                keyPhoto: onePhoto ? ids.first : nil
            )
        }
        let unidentified = selection.unidentified
        if !unidentified.isEmpty {
            var seen: Set<MediaAssetID> = []
            let onePerPhoto = unidentified.filter { seen.insert($0.id.asset).inserted }
            groups.append(FaceMenu.Group(
                title: unidentified.count == 1 ? "Unidentified Face" : "Unidentified Faces",
                person: nil,
                name: nil,
                faces: unidentified.map(\.id),
                choices: choices(for: onePerPhoto, in: selection, except: nil).map { person in
                    .init(person: person.id, title: person.displayName, faces: selection.unidentifiedFacesToName(as: person.id))
                },
                newPersonFaces: onePerPhoto.map(\.id),
                keyPhoto: nil
            ))
        }
        return FaceMenu(groups: groups, flattensFirst: single != nil && people.first == single)
    }

    /// The `NSMenu` for the current targets; grid, filmstrip, loupe and compare all
    /// call this and nothing else.
    func makeMediaItemContextMenu() -> NSMenu? {
        let model = mediaItemMenuModel()
        guard !model.shareItems.isEmpty else { return nil }
        let mode = viewMode.rawValue
        OtosLog.ui.notice("op=ui.contextMenu.open count=\(model.shareItems.count, privacy: .public) mode=\(mode, privacy: .public)")
        return MediaItemContextMenu.make(model: model, icons: openWithApplicationIcons) { [weak self] command in
            self?.performMediaItemCommand(command)
        }
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
        case let .thisIs(faces, person):
            nameFaces(faces, as: person)
        case let .newPerson(faces):
            beginNewPerson(faces)
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
