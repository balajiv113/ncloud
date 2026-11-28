# Immich parity

This is a working checklist for the first milestone, **core library**: browsing,
organizing, and sharing photos and videos from a Nextcloud server and the phone.
Admin tooling, multi-user management, and server-side machine learning are out
of scope for this milestone.

Status key: **Yes** = in the app today, **Partial** = some of it works, **No** =
not started, **Verify** = present in code but not confirmed on a device.

| Area | Immich feature | ncloud status | Notes |
|---|---|---|---|
| Timeline | Date-grouped photo and video grid | Yes | Uses Memories day index when installed |
| Timeline | Fast scrubbing by date | Yes | Right-edge scrubber |
| Timeline | Memories ("on this day") | Partial | Shows covers per year; video covers can lack previews |
| Library | Favorites | Yes | |
| Library | Albums (user-created) | Partial | Server albums and smart albums; verify create/edit |
| Library | Shared albums | Partial | Nextcloud shares |
| Library | Archive | Verify | |
| Library | Trash / recently deleted | Yes | Server trash |
| Library | Duplicate detection | No | |
| Library | Tags | No | |
| Search | Search by name and date | Partial | Searches loaded items only |
| Search | Smart / ML search, OCR | No | Needs server-side ML |
| Map | Photos with GPS on a map | Yes | OpenStreetMap tiles are opt-in |
| People | Face groups | Partial | Uses Memories Recognize; no renaming |
| Sharing | Public share links | Yes | Nextcloud link shares |
| Sharing | Partner sharing | No | |
| Backup | Automatic phone backup | Yes | Android and iOS |
| Backup | Backup status and retries | Yes | |
| Phone | Show phone-only photos in the timeline | Yes | Read-only until backed up |
| Viewer | Photo and video viewer | Yes | Live Photos and motion photos |
| Viewer | Edit (crop, rotate) | No | |
| Multi-user | Partner and admin management | Out of scope | Nextcloud handles accounts |
| Web | Web client | No | |
| Infra | Self-hosted server | Out of scope | ncloud is a client for Nextcloud |

## Next steps

1. Verify the **Verify** and **Partial** rows on a device, and record gaps as issues.
2. Pick the first **No** row to build, starting with the highest-value item.
3. Track progress here; update the table in the same change as the feature.
