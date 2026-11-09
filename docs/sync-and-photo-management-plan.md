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

## Switching behaviour, in either direction

Behaviour is a setting on the link, not a decision made once. All behaviours share
the same ledger, so switching never re-uploads anything and never forgets what
was synced. The recommended route for a new library is: **Back up first**, let the
first big upload finish, then turn on **Keep in step** if you want it.

**Back up to Keep in step.** Turning it on never acts immediately. The app first
compares the phone with the ledger and shows a preview:

* *Deleted on the phone earlier, still on the server* (for example, years of
  deletions made while only backing up). These are **not** queued for removal.
  They are listed as "Already deleted on your phone: 412 files, 3.1 GB" with two
  choices, *Keep them* (the default) or *Remove from server*.
* *In a different folder than on the phone now* (moved before switching on). The
  app offers to move them on the server and shows exactly which. It does nothing
  until you confirm.
* After that, only changes made from now on are followed, with the usual
  safeguards (wait period, trash, caps).

If you did the first upload in Back up mode and have not tidied since, the preview
says "0 to move, 0 to remove", and switching on is one tap.

**Keep in step to Back up.** Always safe. It stops following moves and deletions.
Removals still waiting out their 7 days are cancelled, not carried out. Anything
already removed stays in the server's trash and in "Recently removed" with Restore.

**To or from Two-way** (folders only). Leaving Two-way stops bringing server
changes to the phone. Files already brought down stay on the phone.

A switch made while a run is going takes effect when that run finishes.

## What happens when I delete an album or folder on the phone?

On Android an album is a real folder, so deleting it deletes the photos inside it
(or sends them to the phone's trash).

| Link behaviour | On the server |
| --- | --- |
| **Back up** | Nothing. Every photo stays. |
| **Keep in step** | Nothing at first. Each photo is marked as gone. After the 7-day wait, and only if the safeguards hold, it is moved to the server's **trash**. A large album trips the "sudden drop" check (more than 10%, minimum 50), so the app **asks before removing anything**. |
| **Free up space** (an action in the app) | Nothing. The app deleted them on purpose and marked them "on server only". |

Things worth knowing:

* The server **folder** is never removed, only the files in it. An empty folder
  may be left behind.
* If the album comes back within the wait, for example restored from the phone's
  trash, the mark is cleared and nothing happens.
* Some apps "hide" an album instead of deleting it (for example by adding a
  `.nomedia` file). To the app, hidden photos look deleted. The wait, the preview,
  the trash and the sudden-drop check exist partly for this case.
* On iPhone, deleting an **album** does not delete its photos, which stay in the
  library. With album folders turned on, those photos would be *moved* on the
  server to the next album in your order or to `Camera Roll`, not deleted.

## Emptying the phone once photos are safe (Free up space)

This is a different goal from Keep in step, and the two must not be confused:

| Goal | Phone | Server |
| --- | --- | --- |
| **Free up space** | Photos are deleted from the phone | Photos stay |
| **Keep in step** | You tidy the phone | The server follows, including deletions |

If a plain delete in the Gallery meant "free up space" while Keep in step was on,
the server would delete the photo too. So the app never guesses. Free up space is
an **explicit action in the app**, which means the app knows it did it.

How it works (Android):

1. The app picks photos that are **verified** as safe: the server copy exists, is
   unchanged, and its fingerprint matches the phone's. Nothing is ever freed on
   trust alone.
2. You can choose how much to keep on the phone, for example "keep the last 30
   days" and "keep favourites", and you see the count and the space it would free
   before anything happens.
3. The phone's own system dialog asks once for the whole batch (Android 11 and
   later), so the app cannot delete photos behind your back.
4. Each freed photo is marked **on server only** in the ledger. It is never read
   as a deletion, never queued for removal, and never uploaded again.
5. Freed photos stay browsable in the app, because the Timeline comes from the
   server. Opening one streams it.

Using both together:

* Free up space is exempt from Keep in step, as above.
* A delete made **in the Gallery** is still a delete, and Keep in step would follow
  it (after the wait, into the trash). If your aim is only to empty the phone,
  leave the link on **Back up** and use Free up space. That is the safe pairing.
* The app says so on the Keep in step switch: "Deleting a photo on this phone will
  also remove it from your server."

iPhone is the same idea with PhotoKit: freed photos go to Recently Deleted for 30
days, behind the system confirmation.

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

Splitting by date is never the default, and it is never forced. The app *suggests*
it when a folder gets very large ("Camera has 18,000 files; split by year?").
Because identity does not depend on paths, switching it on, off or changing it
later is a **Reorganise**: the app shows exactly which files would move, then moves
them on the server. Nothing is uploaded again.

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

The earlier mock-ups (`docs/mockups/`) show the right look but are out of date:
they draw a Year/Month folder tree, which is no longer the default, and they have
no behaviour switch, preview or Needs attention yet.

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
   for folders, with preview and Needs attention. Also make big folders cheap:
   read folder listings off the screen thread and show them as they arrive.
2. **Android photos:** media library source, phone-folder layout, duplicate checks,
   Free up space, the media-change trigger.
3. **iPhone photos:** Photos library source, `Camera Roll` and album folders,
   background upload session, change tokens, limited-access handling.
4. **iPhone folders:** Files-app folders with saved bookmarks, Two-way.
5. **Tidying tools:** duplicate review, Reorganise (including optional splitting
   of big folders), Needs attention, the health summary.

Steps 2 to 4 need native Kotlin and Swift that cannot be built here. CI and a
real device are their first check, so each is kept small and lands on its own.

## Deliberately not included

* Anything that changes the phone's photos without you asking.
* Photo recognition or search by content.
* Editing photos.
* Treating Nextcloud albums as the organising tool. Folders are.

## Questions to settle before step 1

1. Is **Back up** the default behaviour for a new link, with **Keep in step** one
   tap away behind a clear explanation, and switchable back at any time?
2. Is the **7-day wait** right for removals, with the first batch asking you?
3. **Free up space** is in the first Android release, since it is what lets you
   empty the phone after backing up. (Proposed: yes.)
4. Should existing folder backups keep running as they are until you opt in to
   the new behaviours? (Proposed: yes.)
