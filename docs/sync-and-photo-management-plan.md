# Photos, videos and folders: phone to server, nothing touched on the phone

Status: step 1 is built for device-folder backups. The rest is still a plan.

| Built (device-folder backups, Android and iPhone albums) | Not built yet |
| --- | --- |
| Fingerprints sent with every upload; the server verifies and stores them | Moves for backups made before fingerprints (needs the one-time preview) |
| A file already on the server is recognised, never uploaded twice | Counting "removed from your server" (needs a server scan) |
| Moves and copies on the device are followed on the server | |
| Back up again (card menu) | iPhone Photos library source and Files folders |
| No per-file server listing; receipts read in groups; newest first | Duplicate review, Reorganise, Needs attention list |
| One bad file no longer ends a run; retries, circuit breaker, Try again | |
| Live count, percent, time left and a list of problems on each card | |
| Android "also when new photos arrive": a WorkManager media-change trigger, set again after each run | Verified on a device (the trigger itself has only been written, not run) |
| Remove from this phone, one album or folder at a time: verified against the server, batches of 200, phone's trash | Verified on a device (Kotlin and Swift written, not compiled; the checks and batching are Dart and tested) |
| iPhone album folders: albums in priority order inside Camera Roll, each photo stored once, moves followed | Verified on a device (the combining is Dart and tested; the native calls it uses already existed) |
| A preview (dry run) before the first backup, and from the card menu at any time | |
| Android "All photos & videos" source: flat album folders, permissions, limited access, covered folders skipped | Verified on a device (the Kotlin has only been written, not compiled) |
| iPhone "Camera Roll": the whole library as one album | Verified on a device (the Swift has only been written, not compiled) |

## The idea in one paragraph

Photos, videos and folders on the phone are copied to your server, and the phone is
never touched by the sync. The only thing that removes anything from the phone is
you tapping **Remove from this phone** in the app. A delete done in the phone's own
Gallery or Files app has exactly the same effect on the server as that button:
none. Getting rid of things on the server is something you do there, in the app, in
Drive, Timeline or Smart albums. The same screens and the same words work on
Android and iPhone; only a thin layer underneath differs.

## What people want

1. Photos, videos and folders reach the server without thinking about it.
2. The server stays tidy: no duplicates, sensible folders, nothing in two places.
3. When I move a photo to another album on the phone, the server follows.
4. I can empty the phone once things are safe, and the server keeps them.
5. Nothing on either side is ever deleted by surprise.
6. A new phone or a reinstall does not mean starting over.

## Four rules

1. **One direction.** Phone to server. Nothing is brought back to the phone.
2. **The sync never changes the phone.** It only reads.
3. **Deleting on the phone never deletes on the server.** Whether you use the app's
   *Remove from this phone* or the system Gallery or Files app, the server keeps it.
4. **Deleting on the server is your decision, made in the app.** The server's trash
   keeps it recoverable, and a photo you removed is not uploaded again.

## What a link does

A **link** joins a *source on the phone* to a *folder on the server*. Sources:

| Source | Android | iPhone |
| --- | --- | --- |
| Photos and videos library | Yes | Yes |
| A folder ("Drive" files such as Documents) | Yes (system folder picker) | Yes (Files app: On My iPhone, iCloud Drive, other providers) |

A link does the same thing every time, with nothing to choose:

| On the phone | On the server |
| --- | --- |
| New photo, video or file | Uploaded |
| Moved to another album or folder | **Moved** to the matching folder |
| Edited | The server copy gets a **new version** (see questions) |
| Deleted (by any means) | Nothing |

The only setting is *when* it runs: Wi-Fi only, charging only, a daily time.

Moving is always followed because a move loses nothing: it is the same file in a
new folder.

## Identity beats paths

Deciding "have I uploaded this?" by path breaks the moment anything moves. Each item
instead has an identity that survives moves and renames:

* the phone's own stable id (Android's media id, iPhone's asset id), when it has
  one, and
* a **content fingerprint** (SHA-1 of the file), always.

The fingerprint is sent with the upload and Nextcloud stores it. That gives:

* **No duplicates.** A file whose fingerprint is already on the server is recorded
  as backed up, never uploaded twice, whatever it is called.
* **Safe moves.** A moved file is the same fingerprint in a different place.
* **A rebuildable memory.** The app keeps a ledger of what it synced. If it is lost
  (new phone, reinstall) it is rebuilt by matching the phone's fingerprints with the
  server's. Re-linking shows "0 to upload", not 12,000.

## What each run decides

Each run compares the phone now, the server now, and the ledger. Every item falls
into one of these, and only the first four ever cause an action:

| Case | Action |
| --- | --- |
| New on the phone | Upload (or record it, if its fingerprint is already on the server) |
| Moved on the phone | Move on the server (never overwrites; only if the server copy is unchanged) |
| Edited on the phone | New version on the server (see questions) |
| Missing on the server, still on the phone | **Not uploaded again.** Counted as "Removed from your server" (see below) |
| Gone from the phone | Nothing |
| Unchanged | Nothing |

Order in a run: moves first, then uploads. Nothing in a run deletes anything.

## How a move is recognised

A move looks like "one file gone, one file new". The app turns that into "same
file, new place" only when it can show it is the same file. In order of strength:

1. **The fingerprint.** For every new file the app computes its SHA-1 before
   deciding anything. If it equals the fingerprint stored for a file that has gone
   missing from the phone, it is the same file. Name, date and folder do not matter,
   so a move plus a rename is still recognised. This is the proof.
2. **The phone's own id.** iPhone's asset id never changes. Android's media id
   usually survives a move. It is a quick pointer to the candidate, and the
   fingerprint still confirms it. (Android folder-picker ids are made from the path,
   so they change on a move and are not used.)
3. **Name, size and modified time all equal, and only one candidate.** Used only for
   backups made before fingerprints were stored, because those files cannot be hashed
   once they are gone. It is weaker, so such moves are listed in the one-time preview
   instead of happening on their own.

Fingerprints are cheap to have: the app hashes a file while it uploads it and stores
the result, and a new file is hashed once before it is uploaded. Hashing runs at
hundreds of megabytes a second.

**Moved or copied?** If the old file is still on the phone, nothing moved. It is a
copy, and it is recorded as already backed up under the same fingerprint, so it is
neither uploaded again nor moved on the server.

**When the server move happens** (all must hold):

* the file is confirmed as the same one, as above;
* the server copy is still the one this app uploaded (same revision);
* the destination does not already exist (a move never overwrites);
* the destination follows the link's folder layout.

If any of these fail, nothing moves and the item is listed under Needs attention.
When the evidence is unclear, for example two files that both match, the app does
nothing rather than guess. The worst case is a file that stays where it was.

A wrong move is also easy to undo: it is the same file in another folder, so moving
it back loses nothing.

## Removing from the phone (in the app)

This is the only thing that ever deletes on the phone, and it is always your tap.

* **Where:** a *Remove from this phone* button on a photo and on a selection, and
  **Remove from this phone…** in a backup card's menu, which works one album or
  folder at a time.
* **One album or folder at a time.** You pick `Screenshots` or `Trips`, and the list
  shows each one's photo count and size. It is a unit you already understand, small
  enough to check, and a very large library is never deleted in one go. There is no
  "delete everything" button.
* **Only verified items are offered.** Just before deleting, every item in the album
  is checked against the server by size and fingerprint, not from memory. What
  cannot be proven (not backed up yet, changed since, removed from the server) stays,
  and is listed.
* **You see the result first:** "412 photos, 3.1 GB, are safely on your server; 6
  are not, so they stay." Optional keeps ("keep the last 30 days", "keep
  favourites") and arbitrary Android folders are not in the first version.
* **Batches, with the phone asking each time.** A big album is done in batches of a
  few hundred, each with the phone's own confirmation and a progress count. You can
  stop between batches, and what is done is done. Each batch is verified again.
* **Trash, not permanent.** Android 11 and later moves them to its trash; iPhone
  moves them to Recently Deleted. Both keep them for 30 days, so a mistake can be
  undone on the phone. The app cannot delete behind your back.
* **iPhone albums are not folders.** Deleting a photo removes it from the whole
  library, so a photo in two albums leaves both. The summary says how many photos
  are also in other albums. The album itself stays, empty.
* **The server is never touched,** and the backup never undoes a removal.
* **Photos, videos and folder files** all work the same. For a folder link the app
  deletes the verified local files in the folder you granted.
* Removed items stay **browsable in the app**, because the Timeline comes from the
  server. Opening one streams it.

Deleting in the system Gallery or Files app is the same as this for the server: it
keeps everything. The only difference is that the app did not verify first, which
is fine, because the server is never affected.

## Removing from the server (in the app)

You decide what goes, with the items in front of you:

* **Drive, Timeline and Smart albums** already let you select and **Delete**. Items
  go to the server's **trash** and can be restored from **Trash**.
* **A whole folder**, for example an album you no longer want, is deleted in Drive
  like any folder.

If something you removed from the server is still on the phone, the next run would
normally upload it again. It does not: an item that was uploaded and later went
missing from the server is treated as removed on purpose. The link's card says so
("38 removed from your server") with **Back up again** for the case where that was
not what you meant, for example after restoring the server from an old backup.

## Worked cases

**1. Photos and an album, backed up.** On Android `Camera/` and `Trips/` are real
folders. One photo link backs up both as `Camera/` and `Trips/`. You move a photo
from `Camera` to `Trips` on the phone; the next run recognises it (same photo, new
folder) and **moves** it on the server. Nothing is uploaded twice.

**2. Albums I want gone.** Delete the album on the phone, in the Gallery or by
*Remove from this phone*: the server keeps everything. If you also want it off the
server, delete those photos or the folder in Drive. It goes to trash and is not
uploaded again.

**3. A folder link and a photo link cover the same photos.** Say a folder link backs
up `WhatsApp Images` and the photo link also sees them. Setup says "WhatsApp Images
is already backed up by another link and is skipped here". Even if both see a file
it is uploaded **once**: its fingerprint is already on the server, so the second
link records it and moves on. Stopping one link leaves the photos where they are.

**4. The same on iPhone.**
* *Photos:* one Photos link puts everything in `Camera Roll/`, plus a folder for each
  album you choose. A photo in several albums is stored once, under the first album
  in your order. Live Photos keep their video with them.
* *Moves:* with album folders on, moving a photo between albums moves it on the
  server too.
* *Deleting:* on the phone, never touches the server. Deleting an album does not
  delete its photos.
* *Folders:* a Files-app folder (iCloud Drive, On My iPhone, others) is a folder link
  exactly like on Android.
* *Remove from this phone:* the same verification and the iPhone's confirmation.
* *Differences you will see:* "waiting for iOS" while the system decides when
  background work runs, and "limited access" instead of Android's "selected photos
  only".

## Keeping photos tidy

**Where photos go on the server.** No dates in folder names unless you ask for them.
The server mirrors how the phone already groups photos:

| | Android | iPhone |
| --- | --- | --- |
| Default | **Phone folders as they are**: `Camera/`, `Screenshots/`, `WhatsApp Images/` | **`Camera Roll/`** for everything, plus an optional folder for each album you choose |
| Optional | Split big folders by year or by year and month | Same |

Splitting by date is never the default and is never forced. The app *suggests* it
when a folder gets very large ("Camera has 18,000 files; split by year?"). Because
identity does not depend on paths, changing the layout later is a **Reorganise**:
the app shows exactly which files would move, then moves them on the server. Nothing
is uploaded again.

**Big folders must stay cheap**, since they are now the normal case:

* Browsing photos never depends on folders. The Timeline is indexed by date.
* A run skips parts of the server that have not changed, using folder revisions.
* Drive reads big folders off the screen thread and fills in as it goes, so opening
  `Camera` with 20,000 files does not freeze the app.

Other things that keep the library clean:

* **Live Photos, RAW+JPEG and edited photos** stay together as one item with several
  parts (the still, its video, the edited version).
* **Screenshots and screen recordings** can go to their own folder by rule.
* **Duplicate review** finds duplicates already on the server by fingerprint and lets
  you keep one and trash the rest.
* **Needs attention** is one list for what wants a decision: conflicts, items removed
  from the server, items that could not be read, duplicates.

## One screen, one vocabulary

Settings has one place, **Sync**. It shows a card for **Photos and videos** and a
card for each **Folder**. Every card shows what it is linked to, "12,431 of 12,460
backed up", the last run and a status (running, waiting for Wi-Fi, needs attention),
and has **Free up space**. A small progress ring appears in the Timeline's top bar
only while something runs.

Adding a link is the same few steps everywhere: **What** (library or folder),
**Where** on the server, **When**. Before anything runs there is always a
**preview**: how many would upload and their size, how many are already on the
server, any duplicates, and any moves.

The first time after an update, photos you moved on the phone *before* moves were
followed may sit in a different server folder. The first run shows "38 photos are in
a different folder than on your phone. Move them to match?" with the exact list.
Nothing moves until you confirm.

The earlier mock-ups (`docs/mockups/`) show the right look but are out of date: they
draw a Year/Month folder tree and have no Free up space, preview or Needs attention.

## How it runs on each phone

| | Android | iPhone |
| --- | --- | --- |
| Photo source | Media library (MediaStore) | Photos library (PhotoKit) |
| Folder source | System folder picker (SAF) | Files app picker with saved bookmarks |
| Notices a change quickly | A media-change trigger wakes the app | A Photos change observer while it runs; otherwise a scheduled task |
| Runs in the background | Scheduled work plus a foreground service for long uploads | A background upload session that continues after the app is suspended, plus iOS-scheduled tasks |
| What it cannot promise | Little | iOS decides when background work runs. The app shows "waiting for iOS" instead of pretending to be instant. |
| Reading changes cheaply | Library generation numbers | Persistent change tokens |

Uploads are **resumable** (chunked for large videos), carry the fingerprint and the
original capture time, and never overwrite a different file. Skipping unchanged parts
of the server uses its folder revisions, so a 100,000-photo library is not rescanned
every time.

## How the code is organised

* **Core (shared Dart):** the ledger, snapshots, the planner (phone, ledger and
  server to a list of uploads and moves), the executor, fingerprinting, and the
  verification used by Remove from this phone. All pure and unit-tested.
* **Device adapters** behind one interface that states what each can do (stable ids,
  change feed, can read, can delete, trust level): Android media library, Android
  folder, iPhone Photos, iPhone Files folder. Deleting is a separate call used only
  by Remove from this phone.
* **Server adapter:** WebDAV with its capabilities (trash, checksums, chunked
  upload) and the Memories hints.
* **Storage:** the ledger in SQLite with additive migrations only. Losing it must
  never be the way data is lost, so it is rebuildable as described above.

## Order of work

Each step ships something usable, and the risky native work comes after the logic it
depends on is proven.

1. **Foundations (Dart, fully testable here):** ledger, planner, executor,
   fingerprints and checksummed uploads. Move today's Android folder backups onto it,
   which already gives moves, the "removed from your server" handling and the preview
   for folders. Also make big folders cheap: read folder listings off the screen
   thread and show them as they arrive.
2. **Android photos and Remove from this phone:** media library source, phone-folder
   layout, duplicate checks, verified removal with the system dialog, the
   media-change trigger.
3. **iPhone photos:** Photos library source, `Camera Roll` and album folders,
   background upload session, change tokens, limited-access handling, verified
   removal.
4. **iPhone folders:** Files-app folders with saved bookmarks.
5. **Tidying tools:** duplicate review, Reorganise (including optional splitting of
   big folders), Needs attention, the health summary.

Steps 2 to 4 need native Kotlin and Swift that cannot be built here. CI and a real
device are their first check, so each is kept small and lands on its own.

## Deliberately not included

* Anything that changes the phone without your tap on Remove from this phone.
* Anything that brings files from the server to the phone.
* Any automatic deletion on the server.
* Photo recognition or search by content.
* Editing photos.
* Treating Nextcloud albums as the organising tool. Folders are.

## Questions to settle before step 1

1. **Edited files.** The server copy gets a **new version** of the same file
   (Nextcloud keeps the old version, restorable). If the server copy was changed on
   the server in the meantime, both are kept. (Settled.)
2. **Removed from the server, still on the phone.** Treated as removed on purpose
   and not uploaded again, with **Back up again** on the card. (Settled.)
3. **Free up space** is in the next release, not the first one, and works by album
   or folder as described above. (Settled.)
4. Existing folder backups follow moves too, since today a moved file is uploaded
   again and leaves a duplicate. The first run shows the one-time "move them to
   match?" preview and waits for your tap. (Settled.)

All questions are settled.
