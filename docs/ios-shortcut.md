# Optional: Apple Shortcut upload

A second way to send photos, using the built-in Shortcuts app instead of Safari.

> **Status: not tested on a device.** The server endpoint is covered by automated tests, but this
> recipe has not been run on an iPhone. Action names vary slightly between iOS versions. Confirm the
> points under [What to check](#what-to-check) before relying on it.

## How it differs from the Safari page

| | Safari page | Shortcut |
|---|---|---|
| Resume after interruption | Yes, from where it stopped | **No.** A failed file is sent again from the start |
| Progress display | Per file and overall | None while running; a summary at the end |
| Skips photos already backed up without sending them | Yes | Yes, with the *Generate Hash* steps below |
| Can run from the Share Sheet / Home Screen | Home Screen | Both |
| Select everything at once | No (swipe-select in the picker) | Yes, with *Find Photos* ([below](#select-all-back-up-everything-without-picking)) |
| Can prove the whole library is backed up | No | No |
| Deletes anything from the iPhone | Never | Never (do **not** add a delete action) |

## Get the two values you need

1. Pair the iPhone with the Safari page first.
2. On that page open **Use with Apple Shortcuts (optional)**. It shows:
   - **Upload address**, like `http://192.168.4.152:8787/api/v1/files`
   - **Authorization header value**, starting with `Bearer `

Keep the second value private. If the PC's address changes, update the address in the Shortcut.

## Build the Shortcut

Shortcuts app → **+** → name it *Back Up Photos*. Add these actions in order:

1. **Select Photos**
   - Turn on **Select Multiple**.
2. **Repeat with Each** (input: *Photos*). Inside the loop:
   1. **Get Details of Files** → *Name* from *Repeat Item*. (On some versions: tap the *Repeat Item*
      variable and choose *Name*.)
   2. **Get Details of Files** → *File Extension* from *Repeat Item*.
   3. **Text**: `[Name].[File Extension]` (insert the two variables with a dot between them).
   4. **URL Encode** the *Text*.
   5. **Text**: your upload address followed by `?filename=` and the *URL Encoded Text*, for example
      `http://192.168.4.152:8787/api/v1/files?filename=[URL Encoded Text]`
   6. *Skip check (recommended).* Add these three actions, then put steps 7 to 9 inside the **If**:
      - **Generate Hash** of *Repeat Item*, type **SHA256**.
      - **Get Contents of URL**: your upload address followed by `/` and the *Hash*, for example
        `http://192.168.4.152:8787/api/v1/files/[Hash]`. Method **GET**, same `Authorization` header.
      - **Get Dictionary Value** for key `status`, then **If** *Dictionary Value* **is not** `stored`.

      The PC answers `stored` when it already holds exactly that file, and the upload is skipped.
   7. **Get Contents of URL** (input: the Text from step 5)
      - Method: **POST**
      - Headers: add `Authorization` with your *Authorization header value*
      - Request Body: **File**, and choose *Repeat Item* as the file
   8. **Get Dictionary Value** → *Value* for key `status` in *Contents of URL*.
   9. **If** *Dictionary Value* **is not** `verified`
      - **If** *Dictionary Value* **is not** `duplicate`
        - **Add to Variable** `Failed` ← the Text from step 3
      - **End If**
   10. **End If** (twice if you added the skip check)
3. **End Repeat**
4. **Count** *Items* in `Failed`.
5. **If** *Count* **is greater than** `0`
   - **Show Alert**: `Some files were NOT backed up:` followed by the `Failed` variable.
6. **Otherwise**
   - **Show Notification**: `All selected files were stored and verified on the PC. Complete photo library coverage has not been verified.`
7. **End If**

Optional: in the Shortcut's details turn on **Show in Share Sheet** and accept *Images and Media*; then
replace step 1 with *Shortcut Input*.

## Select all: back up everything without picking

Safari cannot select your whole library, but a Shortcut can ask Photos for it. Change **step 1** of the
recipe above; everything else stays the same.

Replace **Select Photos** with **Find Photos** and set it up as one of these:

| Goal | Find Photos settings |
|---|---|
| **Everything** | No filters. Turn **Limit** off. |
| **Everything recent** (recommended for routine use) | Add filter *Date Taken* **is in the last** `30` `days`. Limit off. |
| **Videos only / photos only** | Add filter *Media Type* **is** *Video* (or *Image*). |

Then point **Repeat with Each** at *Photos* from Find Photos.

To choose each time, put a **Choose from Menu** action first with the items *Pick photos*,
*Last 30 days* and *Everything*, and place **Select Photos** or the matching **Find Photos** under each.
Set a variable `Chosen` in every branch and repeat over `Chosen`.

Things to know before running *Everything*:

- **Add the skip check (step 6).** With it, each photo is hashed on the iPhone and only new ones are
  sent. Without it, every run sends every file again (nothing is stored twice, but the time is spent).
  Even with it, hashing thousands of items takes a while, so *Everything recent* is still the quicker
  routine choice.
- **It is slow and cannot resume.** A library of thousands of items can take hours; keep the iPhone
  plugged in, on Wi-Fi, with the Shortcut on screen. If it stops, run it again: with the skip check,
  finished files are not sent a second time.
- **Test with a date filter first.** Whether Shortcuts copes with a very large *Find Photos* result
  depends on the iPhone's memory and iOS version, and has not been tried.
- **iCloud-only originals** must be downloaded by iOS during the run; ones that cannot be fetched end
  up in the *Failed* alert.
- This is still "everything Shortcuts returned", not proof of the whole library. The dashboard keeps
  saying library coverage has not been verified, and that remains true.

## What the server answers

Success (HTTP 200):

```json
{ "uploadId": "…", "status": "verified", "sha256": "…", "endToEndVerified": false, "path": "C:\\…\\IMG_0001.HEIC" }
```

`status` is `verified` (stored, re-read and hashed) or `duplicate` (identical content already stored).
Anything else, including an error such as `{ "error": "insufficient_space", "message": "…" }`, means
the file is **not** backed up. Failures also appear on the PC dashboard under *Failed uploads*.

## What to check

Send three or four items once and look in the backup folder and dashboard:

- [ ] Do HEIC photos arrive as `.heic` with the original size, or as converted `.jpeg`?
      Shortcuts may convert when passing photos between actions. If so, the Shortcut is not an
      original-quality path on your iOS version; use the Safari page with *Choose from Files*.
- [ ] Do videos keep their original size and resolution?
- [ ] Skip check: run the Shortcut twice on the same photos. The second run should finish quickly and
      the dashboard should show no new transfers. If everything is sent again, *Generate Hash* is
      hashing something other than the file that gets uploaded on your iOS version; the check is then
      harmless but useless.
- [ ] Live Photos: expect the still only. If a `.mov` also arrives, both parts were provided.
- [ ] Does a large video (1 GB+) complete? If the server answers `length_required`, Shortcuts streamed
      the file without declaring its size, which this endpoint does not accept.
- [ ] Turn Wi-Fi off mid-run: the alert must list the unsent files, and the dashboard must not show
      them as verified.
