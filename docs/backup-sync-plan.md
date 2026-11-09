# Backup that follows the phone: incremental sync, moves and deletes

Status: plan, not built. Written for review before any code.

## Goal

A backup pair can be set to **keep the server in step with this device**:

| Change on the device | Result on the server |
| --- | --- |
| New photo or file | Uploaded (today's behaviour) |
| Photo moved to another album or folder | The server copy is **moved** to the matching folder |
| Photo deleted | The server copy is **deleted into the server's trash**, after safeguards |
| Photo edited | The new version is uploaded; the old one is kept (today's behaviour) |
| Photo renamed | Treated as a new photo plus a deleted one (see "Limits") |

The device is the source of truth for files this app uploaded. Nothing flows from
the server back to the device.

Two modes per pair:

* **Add only** (today). Never moves or deletes. Stays the default for existing pairs.
* **Keep in step** (new). Uploads, moves and deletes, with the safeguards below.

Which pairs may use it: device folders (Android) and "All photos & videos".
Not iPhone Photos-album pairs: removing a photo from an album is not deleting it,
so following it would delete the wrong things.

## Why deletion is the risky part

A listing that comes back short looks exactly like "the user deleted everything".
Real causes: Android 14 "selected photos only" access, an unmounted SD card, a
revoked folder permission, a provider that is still loading, a bug. Every
safeguard below exists to tell these apart from a real deletion.

## How a run works

1. Take a **complete** inventory of the device and of the server folder. Any
   error aborts the whole run before anything is changed.
2. Compare with the **receipts** (what this app confirmed uploading) and sort
   every file into: new, unchanged, edited, or *gone* (has a receipt, no longer
   on the device).
3. **Moves**: pair each gone file with a new file that is the same photo.
4. **Uploads**: new and edited files, as today.
5. **Removals**: what is still gone, if every safeguard passes.

Order matters: moves, then uploads, then removals last. If a run stops half way,
the worst outcome is a file that is still on the server too long, never one that
was removed early.

## Recognising a move

A move looks like "one file gone, one new file". It is treated as a move only if:

1. the library id is the same (Android's photo id usually survives a move), or
2. name, size and modified time all match, and exactly one candidate exists.

If more than one candidate matches, nothing is moved: the old copy goes through
the normal removal safeguards and the new one is uploaded. The end state is the
same, only slower.

The server move never overwrites. It happens only if the server file still has
the revision recorded at upload and the destination does not exist.

## Safeguards for removals (all must hold)

1. **Trustworthy inventory.** Full access, not partial or limited. The root exists
   and is readable. The scan finished.
2. **Not a sudden drop.** If the device count falls by more than
   max(50, 10%) since the last good run, nothing is removed automatically; the
   user is asked.
3. **Grace period.** A file must be missing for at least 7 days and across at
   least two runs. It reappearing clears the mark. This also covers the phone's
   own "recently deleted" window.
4. **Only what we uploaded**, and only inside the pair's server folder. Folders
   are never removed.
5. **Server copy unchanged.** If its revision differs from the receipt (someone
   edited it on the server), it is kept and reported.
6. **Recoverable.** Removal uses the server's trash. If the server has no trash,
   removals are refused.
7. **Caps.** At most 200 removals in one run automatically; more needs approval.
8. **First time asks.** Turning the mode on shows what would be removed now. The
   first real batch needs a tap.
9. **Visible and undoable.** A "Recently removed from your server" list with
   Restore (the app already restores from the server's trash).

## Data and code changes

* Receipts gain `source_id` and `missing_since`. Added with `ALTER TABLE` only;
  receipts are never dropped, because losing them re-uploads everything.
* A new `removals` table records what was removed and when, for the list above.
* `SyncPlanner`: pure function from inventory, receipts, settings and the clock
  to a plan (uploads, moves, ready removals, blocked removals with the reason).
  Every safeguard is a unit test here.
* `SyncEngine` runs a plan: moves, uploads, removals.
* The backend gains `supportsTrash` (server capability) and uses the existing
  delete and move.
* UI: a switch with plain wording, a preview of what would change, a pending
  list, a recently removed list, and counts in the run summary.
* The README sentence "no delete, overwrite, MOVE" is rewritten to describe the
  two modes.

## Limits (stated in the app)

* A renamed file is not recognised as the same photo. It is uploaded as new and
  the old one is removed after the grace period.
* The iPhone keeps year folders only, so moving between albums changes nothing.
* The server is not watched. Deleting on the server does not delete on the
  device; the file is simply uploaded again on the next run.
* Edited photos keep both versions on the server.

## Order of work

1. **Dart only, testable here:** receipt migration, `SyncPlanner`, moves and
   removals for device-folder pairs, UI, tests.
2. **Android photo library** (native Kotlin): all photos and videos, album and
   year folders, covered-folder and already-on-server checks, permission level,
   trashed items, library ids.
3. **iPhone library** (native Swift): year folders, limited-access gate.
4. **Android change trigger** so a move is picked up soon after it happens.

Steps 2 to 4 are native code that cannot be built here; CI and a device are the
first real check.
