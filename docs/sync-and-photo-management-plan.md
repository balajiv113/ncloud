# Photos and folders on your phone, kept in step with your server

Status: plan for review. No code yet. This replaces `backup-sync-plan.md`.

## The idea in one paragraph

Your server's folders are the library. Your phone has two kinds of things to keep
in step with it: **photos and videos**, and **ordinary folders**. They behave
differently on Android and on iPhone, so the app hides that behind one model:
you link *something on the phone* to *a folder on the server*, choose how closely
they follow each other, and the app does the rest. The same screens and the same
words work on both platforms. Only a thin layer underneath differs.

## What people want

1. Photos taken on the phone arrive on the server without thinking about it.
2. The server stays tidy: no duplicates, sensible folders, nothing in two places.
3. When I tidy up on the phone (move a photo to an album, delete a bad shot),
   the server follows.
4. Folders such as Documents stay the same on both sides, in either direction.
5. I can see what is happening, and nothing disappears behind my back.
6. A new phone, a reinstall or a second phone does not mean starting over.

## Three ideas that make this seamless

### 1. One link, three behaviours

A **link** joins a *source on the phone* to a *folder on the server*.

| Behaviour | New on phone | Moved or renamed on phone | Deleted on phone | Changed on server |
| --- | --- | --- | --- | --- |
| **Back up** | Uploaded | Left as is | Kept on server | Ignored |
| **Keep in step** | Uploaded | Moved on server | Removed from server (to trash) | Ignored |
| **Two-way** (folders only) | Uploaded | Moved on server | Removed on server | Brought to the phone |

"Back up" is the safe default. "Keep in step" is what you asked for with photos.
"Two-way" is for ordinary folders such as Documents.

Sources a link can use:

| Source | Android | iPhone |
| --- | --- | --- |
| Photos and videos library | Yes | Yes |
| A device folder | Yes (picked with the system folder picker) | Yes (picked in the Files app: On My iPhone, iCloud Drive, other providers) |

### 2. Identity beats paths

The old way of deciding "have I uploaded this?" is the file's path. That breaks
the moment anything moves. Instead each item has an identity that survives moves
and renames:

* the phone's own stable id for it (Android's media id, iPhone's asset id), when
  it has one, and
* a **content fingerprint** (SHA-1 of the file), always.

The fingerprint is sent with the upload, and Nextcloud stores it. That gives
three things for free:

* **No duplicates.** A photo whose fingerprint is already in the destination is
  recorded as backed up, never uploaded twice, whatever it is called.
* **Safe moves.** A moved file is the same fingerprint in a different place.
* **A rebuildable memory.** The app keeps a ledger of what it has synced. If the
  ledger is lost (new phone, reinstall), it is rebuilt by matching the phone's
  fingerprints with the server's. Re-linking shows "0 to upload", not 12,000.

### 3. Compare three things, not two

Every run compares **the phone now**, **the server now**, and **the ledger** (what
both agreed last time). Any difference from the ledger is a change on exactly one
side, so the app knows what happened instead of guessing:

* only the phone differs: apply the phone's change to the server (if the
  behaviour allows it),
* only the server differs: ignore it, or bring it to the phone (two-way only),
* both differ: a conflict. Nothing is overwritten. Both versions are kept and the
  copy is named after its origin.

This is the same engine for photos and folders, which is why they feel alike.

## Keeping photos tidy

**Where photos go on the server** is a choice with plain names:

| Organise by | Example | Notes |
| --- | --- | --- |
| **Phone folders, then year** | `Camera/2024/IMG_1.jpg` | Default on Android. Recognisable, and no folder grows huge. |
| **Year** | `2024/IMG_1.jpg` | Default on iPhone, where photos are not in folders. |
| Year and month | `2024/05/IMG_1.jpg` | For people who prefer it. |
| Phone folders only | `Camera/IMG_1.jpg` | Simple, but big folders. |

Because identity does not depend on paths, the layout can be **changed later**:
the app offers "Reorganise", shows exactly which files would move, and moves them
on the server. Nothing is uploaded again.

On iPhone an album is not a folder, and one photo can be in several albums. So
albums are optional "album folders" with a priority order, and each photo is
stored once, under the first album in your order that holds it.

Other things that keep the library clean:

* **Live Photos, RAW+JPEG and edited photos** stay together as one item with
  several parts (the still, its video, the edited version).
* **Screenshots and screen recordings** can go to their own folder by rule.
* **Duplicate review** finds duplicates already on the server by fingerprint and
  lets you keep one and trash the rest.
* **Free up space** deletes the phone copy of photos whose server copy has been
  verified by fingerprint. The system shows its own confirmation. Never automatic.
* **Needs attention** is one list for everything that wants a decision:
  conflicts, blocked removals, items that could not be read, duplicates.

## Deleting safely

Deleting is the one action that cannot be undone by fixing a bug later, so it is
the most guarded. Removing something from the server happens only when all of
these hold:

1. The scan of the phone was complete and had **full access** (not Android's
   "selected photos only", not iPhone's "limited"). A short listing must never
   look like a mass deletion.
2. The count did not suddenly drop (more than 10%, minimum 50). If it did, the
   app asks first.
3. The item has been gone for **at least 7 days** across at least two runs. This
   also covers the phone's own "recently deleted" window.
4. This phone put it there (the ledger says so), and it is inside the link's
   folder.
5. The server copy is unchanged since it was uploaded.
6. The server has a **trash**, so it can be restored. If not, deleting is
   refused.
7. At most 200 removals per run on their own. More waits for approval.
8. The first removals after switching on always ask.

Everything removed is listed under "Recently removed from your server" with a
Restore button.

The phone is never changed by the app, with two exceptions you ask for: *Free up
space*, and Two-way folders bringing files down.

## One screen, one vocabulary

Settings has one place, **Sync**. It shows:

* a card for **Photos and videos** (one per phone library), and cards for each
  **Folder**;
* on every card: what it is linked to, the behaviour, "12,431 of 12,460 backed
  up", the last run, and a status (running, waiting for Wi-Fi, needs attention);
* a small progress ring in the Timeline's top bar only while something runs.

Adding a link is the same four steps everywhere: **What** (library or folder),
**Where** on the server, **How closely** (Back up, Keep in step, Two-way), then
**Organise and when** (for photos). Before anything runs there is always a
**preview**: how many would upload and their size, how many are already on the
server, any duplicates, and what, if anything, would be removed.

The earlier mock-ups (`docs/mockups/`) still show the right look. They need
updating for the behaviour switch, the preview and Needs attention.

## How it runs on each phone

| | Android | iPhone |
| --- | --- | --- |
| Photo source | Media library (MediaStore) | Photos library (PhotoKit) |
| Folder source | System folder picker (SAF) | Files app picker with saved bookmarks |
| Notices a change quickly | A media-change trigger wakes the app | A Photos change observer while it runs; otherwise a scheduled task |
| Runs in the background | Scheduled work plus a foreground service for long uploads | A background upload session that continues after the app is suspended, plus iOS-scheduled tasks |
| What it cannot promise | Little | iOS decides when background work runs. The app shows "waiting for iOS" instead of pretending to be instant. |
| Reading changes cheaply | Library generation numbers | Persistent change tokens |

Uploads are **resumable** (chunked for large videos), carry the fingerprint and
the original capture time, and never overwrite. Skipping unchanged parts of the
server uses its folder revisions, so a 100,000-photo library is not rescanned
every time.

## How the code is organised

* **Core (shared Dart):** the ledger, snapshots, the three-way planner, the
  safety policy, the executor, and fingerprinting. All pure and unit-tested.
* **Device adapters** behind one interface that also states what each can do
  (stable ids, change feed, can read, can write, can delete, trust level):
  Android media library, Android folder, iPhone Photos, iPhone Files folder.
* **Server adapter:** WebDAV with its capabilities (trash, checksums, chunked
  upload) and the Memories hints.
* **Storage:** the ledger in SQLite with additive migrations only. Losing it must
  never be the way data is lost, so it is rebuildable as described above.

## Order of work

Each step ships something usable, and the risky native work comes after the
logic it depends on is proven.

1. **Foundations (Dart, fully testable here):** ledger, three-way planner, safety
   policy, executor, fingerprints and checksummed uploads. Move today's Android
   folder backups onto it, which already gives Back up, Keep in step and Two-way
   for folders, with preview and Needs attention.
2. **Android photos:** media library source, organising choices, duplicate checks,
   Free up space, the media-change trigger.
3. **iPhone photos:** Photos library source, year and album folders, background
   upload session, change tokens, limited-access handling.
4. **iPhone folders:** Files-app folders with saved bookmarks, Two-way.
5. **Tidying tools:** duplicate review, Reorganise, Needs attention, the health
   summary.

Steps 2 to 4 need native Kotlin and Swift that cannot be built here. CI and a
real device are their first check, so each is kept small and lands on its own.

## Deliberately not included

* Anything that changes the phone's photos without you asking.
* Photo recognition or search by content.
* Editing photos.
* Treating Nextcloud albums as the organising tool. Folders are.

## Questions to settle before step 1

1. Is **Back up** the default behaviour for a new link, with **Keep in step** one
   tap away behind a clear explanation?
2. Is the **7-day wait** right for removals, with the first batch asking you?
3. Should **Free up space** be in the first Android release or wait?
4. Should existing folder backups keep running as they are until you opt in to
   the new behaviours? (Proposed: yes.)
