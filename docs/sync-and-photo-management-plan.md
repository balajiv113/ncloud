# Photos and folders on your phone, kept in step with your server

Status: plan for review. No code yet.

## The idea in one paragraph

Your server's folders are the library. Your phone has two kinds of things to keep
in step with it: **photos and videos**, and **ordinary folders**. They behave
differently on Android and on iPhone, so the app hides that behind one model: you
link *something on the phone* to *a folder on the server*, answer a few plain
questions, and the app does the rest. The same screens and the same words work on
both platforms. Only a thin layer underneath differs.

## What people want

1. Photos taken on the phone arrive on the server without thinking about it.
2. The server stays tidy: no duplicates, sensible folders, nothing in two places.
3. When I tidy up on the phone (move a photo to an album), the server follows.
4. I can empty the phone once photos are safe, and keep them on the server.
5. Cleaning up the server is easy, visible and recoverable, and never happens by surprise.
6. Folders such as Documents can stay the same on both sides.
7. I can see what is happening, and nothing disappears behind my back.
8. A new phone or a reinstall does not mean starting over.

## Three ideas that make this seamless

### 1. A link with a few plain settings, not modes

A **link** joins a *source on the phone* to a *folder on the server*. A link does
the same thing every time, with no behaviour to pick:

* **New photos and files** on the phone are uploaded.
* **A photo moved to another album or folder** on the phone is moved to the
  matching folder on the server. A move loses nothing: it is the same file in a new
  folder, so this is always on.
* **A photo deleted on the phone** stays on the server, always. Removing things
  from the server is a separate, visible step you take in the app (see "Cleaning
  up the server").

The only settings are about *when*, and one for folders:

| Setting | Answers | Default |
| --- | --- | --- |
| When it runs | Wi-Fi only, charging only, daily time | Wi-Fi only |
| **Bring server changes to this phone** (folders only) | Off / On | Off |

There is no "mode" to understand. Someone who only wants a backup changes nothing.
Someone who tidies albums on the phone gets their moves.

Sources a link can use:

| Source | Android | iPhone |
| --- | --- | --- |
| Photos and videos library | Yes | Yes |
| A device folder | Yes (system folder picker) | Yes (Files app: On My iPhone, iCloud Drive, other providers) |

### 2. Identity beats paths

The old way of deciding "have I uploaded this?" is the file's path. That breaks
the moment anything moves. Instead each item has an identity that survives moves
and renames:

* the phone's own stable id for it (Android's media id, iPhone's asset id), when
  it has one, and
* a **content fingerprint** (SHA-1 of the file), always.

The fingerprint is sent with the upload, and Nextcloud stores it. That gives:

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

* only the phone differs: apply it to the server if the settings allow,
* only the server differs: ignore it, or bring it down (folders, if switched on),
* both differ: a conflict. Nothing is overwritten. Both versions are kept and the
  copy is named after where it came from.

This is the same engine for photos and folders, which is why they feel alike.

## Cleaning up the server

The phone only ever **adds** to the server (and moves what it has already added).
Nothing is deleted from the server because of something done on the phone. That
removes the one risk a bug could never undo.

You still need to get rid of things, so the app makes it easy where you can see it:

* **Not on your phone any more.** The app knows which backed-up photos are no
  longer on the phone (the ledger remembers). It shows them as one view, under the
  link's card and in Smart albums: "412 photos, 3.1 GB". Select some or all and
  choose **Delete from server** (they go to the server's **trash**) or **Keep**
  (they stop being listed).
* **Drive and the Timeline** already let you select and delete. Deleted items go
  to the server's trash and can be restored from **Trash**.
* **Whole folders** (for example an album you no longer want) are deleted in Drive
  like any folder.

One thing the app cannot know: deleting in the Gallery **to free space** and
deleting because you **want it gone** look identical. So this list is built to be
safe to ignore:

* Nothing is ever pre-selected, and the default action is **Keep**.
* It says plainly what the photos are: "These are on your server and no longer on
  your phone. Deleting them from the server removes your only copy, apart from
  the server's trash."
* Photos freed with **Free up space** never appear here, because the app did that
  on purpose and marked them "on server only".
* For emptying the phone, Free up space is the recommended route, so the list
  stays short and meaningful.

Why this is enough: you decide what goes, with the photos in front of you, in one
batch. A scan that comes back short, an album that was hidden instead of deleted,
or a permission that changed can never cost you a photo, because no scan can
delete anything.

Automatic removal ("when I delete on the phone, remove it from the server") is
**left out of the first version on purpose**. It can be added later as a third
answer, with the safeguards below, if it turns out you want it:

1. full access to the phone's photos (not "selected photos only" or "limited"),
2. two scans in a row agree,
3. a sudden drop (more than 10%, minimum 50) makes it ask instead,
4. only files this phone uploaded, unchanged on the server,
5. the server has a trash,
6. at most 200 per run, and the first batch always asks.

The phone is never changed by the app, with two exceptions you ask for: *Free up
space*, and folders bringing server changes down.

## The first time after an update

Moves are followed from now on. Photos you moved on the phone *before* a link
followed moves may sit in a different server folder than on the phone. The first
run therefore shows a one-time preview: "38 photos are in a different folder than
on your phone. Move them to match?" with the exact list. Nothing moves until you
confirm. After that, moves just happen.

Settings can be changed at any time. They share one ledger, so changing them never
re-uploads anything and never forgets what was synced. A change made while a run
is going takes effect when that run finishes.

## What happens when I delete an album or folder on the phone?

On Android an album is a real folder, so deleting it deletes the photos inside it
(or sends them to the phone's trash).

* **Server:** nothing. Every photo stays, and the folder stays.
* The photos appear in **Not on your phone any more**, so you can remove them from
  the server when you are ready, or keep them.
* If you restore the album on the phone, they simply drop off that list.
* Some apps "hide" an album instead of deleting it. That looks like a deletion to
  the app, and it is harmless here, since nothing is removed.
* On iPhone, deleting an **album** does not delete its photos. With album folders
  on, they are *moved* on the server to the next album in your order, or to
  `Camera Roll`.

## Emptying the phone once photos are safe (Free up space)

Because deleting on the phone never deletes on the server, emptying the phone is
safe by design: delete in the Gallery, or use **Free up space** in the app, and
the server keeps everything. Free up space is the careful way to do it: it deletes
only photos it has **verified** on the server, and it shows you what it will do.

1. The app picks photos that are **verified** as safe: the server copy exists, is
   unchanged, and its fingerprint matches the phone's.
2. You choose how much to keep, for example "keep the last 30 days" and "keep
   favourites", and you see the count and the space it frees before anything
   happens.
3. The phone's own system dialog asks once for the whole batch (Android 11 and
   later), so the app cannot delete photos behind your back.
4. Each freed photo is marked **on server only**. It never appears in "Not on
   your phone any more", and it is never uploaded again.
5. Freed photos stay browsable in the app, because the Timeline comes from the
   server. Opening one streams it.

iPhone is the same idea with PhotoKit: freed photos go to Recently Deleted for 30
days, behind the system confirmation.

## Worked cases

**1. Photos and an album, backed up.** On Android, `Camera/` and `Trips/` are
folders. One photo-and-videos link backs up both as `Camera/` and `Trips/` on the
server. Later you move a photo from `Camera` to `Trips`. Next run it is recognised
(same photo, new folder) and **moved** on the server. Nothing is uploaded twice.

**2. Albums I want gone.** Delete the album on the phone: the server keeps
everything. When you want the server cleaned too, open **Not on your phone any
more**, select the photos, **Delete from server** (to trash). Or delete the folder
in Drive.

**3. A folder link and a photo link cover the same photos.** Say a folder link
backs up `WhatsApp Images`, and the photo link also sees them.
* The setup screen says so: "WhatsApp Images is already backed up by another
  link and is skipped here."
* Even if both see a file, it is uploaded **once**: the fingerprint is already on
  the server, so the second link records it as backed up and moves on.
* If you later stop one link, the photos stay on the server and the other link
  keeps tracking them.

**4. The same on iPhone.**
* *Back up:* one Photos link puts everything in `Camera Roll/`, plus a folder for
  each album you chose. A photo in several albums is stored once, under the first
  album in your order. Live Photos keep their video with them.
* *Moves:* with album folders on, moving a photo between albums moves it on the
  server too. Without them, there is nothing to move.
* *Deleting on the phone:* it stays on the server and shows in **Not on your phone
  any more**, just like Android. Deleting an album does not delete photos.
* *Folders:* a Files-app folder (iCloud Drive, On My iPhone, others) is a folder
  link exactly like on Android.
* *Free up space:* uses the same verification and the iPhone's confirmation. Photos
  go to Recently Deleted for 30 days.
* *Differences you will see:* iPhone shows "waiting for iOS" while the system
  decides when background work runs, and "limited access" instead of Android's
  "selected photos only".

## Keeping photos tidy

**Where photos go on the server.** No dates in folder names unless you ask for
them. The server mirrors how the phone already groups photos:

| | Android | iPhone |
| --- | --- | --- |
| Default | **Phone folders as they are**: `Camera/`, `Screenshots/`, `WhatsApp Images/` | **`Camera Roll/`** for everything, plus an optional folder for each album you choose |
| Optional | Split big folders by year or by year and month | Same |

On Android a photo already lives in exactly one folder, so this is the layout you
already know. On iPhone photos are not in folders and one photo can be in several
albums. So albums are optional "album folders" with a priority order, and each
photo is stored once, under the first album in your order that holds it. Anything
in no chosen album goes to `Camera Roll/`.

Splitting by date is never the default and is never forced. The app *suggests* it
when a folder gets very large ("Camera has 18,000 files; split by year?"). Because
identity does not depend on paths, switching it on, off or changing it later is a
**Reorganise**: the app shows exactly which files would move, then moves them on
the server. Nothing is uploaded again.

**Big folders must stay cheap**, since they are now the normal case:

* Browsing photos never depends on folders. The Timeline is indexed by date.
* A run skips parts of the server that have not changed, using folder revisions,
  so a big folder is not re-read every time.
* Drive reads big folders off the screen thread and fills in as it goes, so
  opening `Camera` with 20,000 files does not freeze the app.

Other things that keep the library clean:

* **Live Photos, RAW+JPEG and edited photos** stay together as one item with
  several parts (the still, its video, the edited version).
* **Screenshots and screen recordings** can go to their own folder by rule.
* **Duplicate review** finds duplicates already on the server by fingerprint and
  lets you keep one and trash the rest.
* **Needs attention** is one list for everything that wants a decision:
  conflicts, photos no longer on your phone, items that could not be read, duplicates.

## One screen, one vocabulary

Settings has one place, **Sync**. It shows:

* a card for **Photos and videos** (one per phone library), and a card for each
  **Folder**;
* on every card: what it is linked to, "12,431 of 12,460 backed up", the last run,
  and a status (running, waiting for Wi-Fi, needs attention);
* a small progress ring in the Timeline's top bar only while something runs.

Adding a link is the same few steps everywhere: **What** (library or folder),
**Where** on the server, then the plain questions above, then **When**. Before
anything runs there is always a **preview**: how many would upload and their size,
how many are already on the server, any duplicates, and what, if anything, would
be moved or removed.

The earlier mock-ups (`docs/mockups/`) show the right look but are out of date:
they draw a Year/Month folder tree, which is no longer the default, and they have
none of the settings above, the preview or Needs attention yet.

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

Each step ships something usable, and the risky native work comes after the logic
it depends on is proven.

1. **Foundations (Dart, fully testable here):** ledger, three-way planner, safety
   policy, executor, fingerprints and checksummed uploads. Move today's Android
   folder backups onto it, which already gives the move and delete settings for
   folders, with preview, Needs attention and the "Not on your phone any more" view. Also make big folders cheap: read
   folder listings off the screen thread and show them as they arrive.
2. **Android photos:** media library source, phone-folder layout, duplicate checks,
   Free up space, the media-change trigger.
3. **iPhone photos:** Photos library source, `Camera Roll` and album folders,
   background upload session, change tokens, limited-access handling.
4. **iPhone folders:** Files-app folders with saved bookmarks, bringing server
   changes down.
5. **Tidying tools:** duplicate review, Reorganise (including optional splitting
   of big folders), Needs attention, the health summary.

Steps 2 to 4 need native Kotlin and Swift that cannot be built here. CI and a real
device are their first check, so each is kept small and lands on its own.

## Deliberately not included

* Anything that changes the phone's photos without you asking.
* Photo recognition or search by content.
* Editing photos.
* Treating Nextcloud albums as the organising tool. Folders are.

## Questions to settle before step 1

1. Is **add-only plus moves** right for the first version, with removal handled in
   the app through **Not on your phone any more**, and automatic removal left for
   later?
2. **Free up space** is in the first Android release, since it is what lets you
   empty the phone after backing up. (Proposed: yes.)
3. Existing folder backups get moves too, since a move loses nothing. The first
   time, they show the one-time "move them to match?" preview and wait for your
   tap. (Proposed: yes.)
