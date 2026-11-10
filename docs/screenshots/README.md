# Screenshots of the web client

The client in `ui/` as implemented, on every screen of the [design](../design/README.md) that has a page, taken on 10 November 2026 from version 3.0.0-dev.6. They are named like the boards in `docs/design/screens`: `NN-<screen>-<width>-<theme>.png`, at 1440 px and 390 px wide, light and dark, full page. Board 02 is split by state (`02-states-no-results`, `02-states-offline`, `02-states-forbidden`); boards 00 and 01 (foundations, components) have no page of their own.

The registry is seeded through the API by `ui/e2e/seed.ts`, so every date reads "just now" and the download chart has a single day. The tokens and webhook secrets in the pictures belong to a throwaway server and database that are deleted after the run.

| # | Screen | State |
| --- | --- | --- |
| 02 | States | no search results, offline banner, 403 for a reader on /admin |
| 03 | Package list | anonymous visitor, sorted by downloads |
| 04 | Package page, README | administrator and uploader, long README with tables |
| 05 | Package page, Versions | retracted version selected, Actions menu open |
| 06 | Package page, Install | discontinued with a replacement, copy confirmation |
| 07 | Package page, Stats | 30-day chart, downloads per version |
| 08 | Login | wrong password |
| 09 | Not found | "Did you mean" suggestion |
| 10 | Account | token just created |
| 11 | Admin, Overview | failed deliveries |
| 12 | Admin, Users | every role, one disabled |
| 13 | Admin, Packages |  |
| 14 | Admin, Package | retracted version, two uploaders |
| 15 | Admin, Audit log | first row expanded |
| 16 | Admin, Webhooks | one enabled, one paused with failed deliveries |
| 17 | Admin, Webhook | delivery payload open |
| 18 | Admin, Settings |  |

## Regenerating

In `ui/`, with Docker and the Dart SDK (see the "End-to-end test" section of [ui/README.md](../../ui/README.md)):

```sh
npm run screenshots                     # writes /tmp/unpub-screens
cp /tmp/unpub-screens/*.png ../docs/screenshots/
cp /tmp/unpub-screens/03-package-list-1440-light.png ../assets/screenshot.png
```

`UNPUB_SCREENSHOT_DIR` changes the output directory. It also gets an `index.html` with every screen side by side and filters by theme and width, which is not committed.
