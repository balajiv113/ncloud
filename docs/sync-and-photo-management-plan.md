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
5. If I do want deletions to follow, that is my choice, and it is recoverable.
6. Folders such as Documents can stay the same on both sides.
7. I can see what is happening, and nothing disappears behind my back.
8. A new phone or a reinstall does not mean starting over.

## Three ideas that make this seamless

### 1. A link with a few plain settings, not modes

A **link** joins a *source on the phone* to a *folder on the server*. Each link has
the same few settings, each a plain question with plain answers:

| Setting | Answers | Default |
| --- | --- | --- |
| **New photos on my phone** | Always uploaded | (fixed) |
| **When I move a photo on my phone** | Move it on the server too / Leave the server alone | Move it |
| **When I delete a photo on my phone** | **Keep it on the server** / **Ask me first** / **Remove it from the server** (to trash) | Keep it |
| **Bring server changes to this phone** (folders only) | Off / On | Off |
| When it runs | Wi-Fi only, charging only, daily time | Wi-Fi only |

That is all. There is no "mode" to understand. Someone who only wants a backup
changes nothing. Someone who tidies on the phone gets their moves. Someone who
wants deletions to follow picks one answer.

Moving is safe to follow by default: a move loses nothing, because the file is the
same file in a new folder. Deleting is the only risky one, so its default is the
safe answer and the others are explicit.

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

## Deleting, with no timers

When a photo is deleted on the phone, the setting decides:

* **Keep it on the server.** Nothing happens. Ever.
* **Ask me first.** The photo appears in a list, "Deleted on your phone: 14
  photos, 52 MB", with **Remove from server** and **Keep**. You decide in one tap,
  in a batch. Nothing waits on a clock.
* **Remove it from the server.** The photo goes to the server's **trash**, so it
  can be restored from there.

The server's trash is the undo. It is why no waiting period is needed.

Behind the scenes, so that a faulty scan is never mistaken for a deletion, a
removal only goes ahead when all of these hold:

1. The scan of the phone was complete and had **full access** (not Android's
   "selected photos only", not iPhone's "limited").
2. **Two scans in a row** agree the photo is gone. This is invisible and takes a
   run or two, not days.
3. The count has not suddenly collapsed (more than 10%, minimum 50). If it has,
   the app switches to asking, whatever the setting.
4. This phone put it there (the ledger says so) and it is inside the link's folder.
5. The server copy is unchanged since it was uploaded.
6. The server has a **trash**. If not, "Remove it from the server" is refused.
7. At most 200 removals per run. More are asked about.
8. The first removals after choosing the setting ask first.

Everything removed is listed under **Recently removed from your server** with a
Restore button.

The phone is never changed by the app, with two exceptions you ask for: *Free up
space*, and folders bringing server changes down.

## Switching settings

Settings can be changed at any time, in any direction. They share one ledger, so
changing them never re-uploads anything and never forgets what was synced. The
suggested route for a new library: leave the defaults, let the first big upload
finish, change what you want later.

Choosing **Ask me first** or **Remove it from the server** never acts at once. The
app first shows a preview:

* *Deleted on the phone earlier, still on the server* (for example, years of
  deletions made while only backing up). These are **not** queued for removal.
  They are listed ("412 files, 3.1 GB") with *Keep them* as the default and
  *Remove from server* as the other choice.
* After that, only deletions from now on are followed.

Choosing **Move it** shows the photos that sit in a different folder than on the
phone and offers to move them, with the exact list. Nothing moves until you
confirm.

Going back to **Keep it on the server** is always safe: it simply stops following
deletions. Anything already removed stays in the trash and in Recently removed.

A change made while a run is going takes effect when that run finishes.

## What happens when I delete an album or folder on the phone?

On Android an album is a real folder, so deleting it deletes the photos inside it
(or sends them to the phone's trash).

| "When I delete a photo" is | On the server |
| --- | --- |
| **Keep it** | Nothing. Every photo stays. |
| **Ask me first** | They appear in the "Deleted on your phone" list for you to approve. |
| **Remove it** | After two scans agree and the checks pass, they go to the trash. A large album trips the "sudden drop" check, so the app **asks** first. |
| **Free up space** (an action in the app) | Nothing. The app deleted them on purpose. |

* The server **folder** is never removed, only the files in it.
* Some apps "hide" an album instead of deleting it (for example with a `.nomedia`
  file). To the app, hidden photos look deleted. The asking, the trash and the
  sudden-drop check exist partly for this.
* On iPhone, deleting an **album** does not delete its photos. With album folders
  on, they are *moved* on the server to the next album in your order or to
  `Camera Roll`.

## Emptying the phone once photos are safe (Free up space)

This is a different goal from removing deletions from the server:

| Goal | Phone | Server |
| --- | --- | --- |
| **Free up space** | Photos are deleted from the phone | Photos stay |
| **Remove it from the server** | You delete on the phone | The server follows |

If a plain delete in the Gallery meant "free up space" while *Remove it from the
server* was on, the server would delete the photo too. So the app never guesses.
Free up space is an **explicit action in the app**, which means the app knows it
did it.

1. The app picks photos that are **verified** as safe: the server copy exists, is
   unchanged, and its fingerprint matches the phone's.
2. You choose how much to keep, for example "keep the last 30 days" and "keep
   favourites", and you see the count and the space it frees before anything
   happens.
3. The phone's own system dialog asks once for the whole batch (Android 11 and
   later), so the app cannot delete photos behind your back.
4. Each freed photo is marked **on server only**. It is never read as a deletion,
   never queued for removal, and never uploaded again.
5. Freed photos stay browsable in the app, because the Timeline comes from the
   server. Opening one streams it.

To empty the phone and keep everything on the server, leave *When I delete* on
**Keep it** and use Free up space. If you set it to *Remove it*, the app says so
on the setting: "Deleting a photo on this phone will also remove it from your
server."

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
  conflicts, deletions waiting for you, items that could not be read, duplicates.

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
   folders, with preview and Needs attention. Also make big folders cheap: read
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

1. Are plain settings (no named modes) right, with **Move it** on and **Keep it on
   the server** as the delete default?
2. Should the **first removals always ask**, even if you chose "Remove it"?
3. **Free up space** is in the first Android release, since it is what lets you
   empty the phone after backing up. (Proposed: yes.)
4. Existing folder backups keep running exactly as they are until you opt in.
   (Proposed: yes; their move setting starts as "Leave the server alone".)
