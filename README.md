# RBBScan

Scan the passcodes on 1050 Ingress **RARE Battle Beacon** cards with an iPhone. Each passcode, with its photo, goes to a server on the Mac mini, where you review it. A second device shows a live dashboard, because you can't watch the scanning phone's screen while you hold it over the cards.

```
iPhone app (camera + on-device Apple Vision OCR)
   │  confirmed passcode + label/card/frame JPEGs, 1 s heartbeat + preview
   ▼
Mac mini server (FastAPI + SQLite), on its Tailscale address, port 8787
   ├─ /       review page: photo, passcode, seen ×N, verify, edit, CSV export
   └─ /live   second-device dashboard: counter, NEW/DUPLICATE, camera preview, beeps
```

> **Built for RARE Battle Beacon cards only.** Recognition is tuned to these cards: 16 characters of `A–Z 0–9`, dark on a white strip, beside the Battle Beacon description text. Passcodes from other Ingress cards, promotions or events may have a different length, character set or layout, and this app will skip them or misread them. To adapt it, change:
>
> * the format rules in `PasscodeCore/Sources/PasscodeCore/Passcode.swift` and `server/rbbscan/passcode.py`; keep the two in step;
> * the printed card text in `CardTextFilter.swift`;
> * the light-label check in `LabelFilter.swift`;
> * the AI check's instructions in `server/rbbscan/verifier.py`.

## How a passcode is recognised

* A passcode is **16 characters of `A–Z 0–9`**, printed dark on a white strip.
* Each camera frame goes through Vision OCR. A read is dropped if:
  * it doesn't have the passcode shape;
  * it lies within 4 edits of the card's printed description text, any 16-letter run of which OCR would otherwise take for a passcode, or of the sleeve's "FOR INVENTORY TRACKING ONLY";
  * it is clearly white-on-dark text.
* **Cards lying sideways or upside down:** the recognizer detects which way the text runs and, after two frames agree, hands Vision the frame already turned upright, which reads far more reliably. The saved passcode and card crops are straightened to the text's exact angle (from Vision's corner points), so the code reads level even on a tilted card; the whole photo is turned to the nearest upright quarter.
* Reads of one card across frames are grouped together, and each character is decided by a vote. A read shifted by a stray character (the card edge read as `I`) joins its card but stays out of the vote.
  * A code is confirmed once every position has a clear winner.
  * A code that stays ambiguous is still confirmed after 5 reads or 1 s, so no card is lost. Its unclear positions are flagged and shown in red, so you check them against the photo.
* **Look-alike characters are the same passcode** (Ingress accepts them interchangeably): `O = 0 = Q`, `I = 1 = L`, `S = 5`. `D` stays distinct.
* **Duplicate detection:** a code within 4 edits (substitutions, insertions or deletions) of a known one counts as the same card. Real codes differ by about 11 edits, while OCR slips such as 6/G or a dropped character are exactly that close. The card is then flagged "needs review" with every reading listed.
* **Feedback:** a new code plays a double high beep (plus a haptic) on the phone and on `/live`. A duplicate plays a single low tone and shows **seen ×N**.

On a 51 s sample recording, all 40 visible cards are found, with no false or doubled entries. Replayed turned sideways or upside down (`videoscan --rotate 90|180|270`), 39 of 40 are found with no false entries; the miss is a card that passes the camera in half a second.

## Run the server (Mac mini)

```sh
./run_server.sh          # binds to this Mac's Tailscale IP, port 8787; Ctrl-C to stop
```

* The database and images go to `./data`.
* You can override `RBB_HOST`, `RBB_PORT`, `RBB_DATA_DIR` and `RBB_TARGET_TOTAL` (default 1050).
* Requires `uv` and Tailscale.
* Pages:
  * `http://<tailscale-ip>:8787/` is the review page. Click a photo to open the viewer: switch between the passcode crop, the card and the whole photo; ⟲ ⟳ (or R) turn the photos upright and remember it for that passcode; scroll, pinch or double-click to zoom and drag to move; ←/→ step through passcodes and V verifies.
  * `http://<tailscale-ip>:8787/live` is the live dashboard. Open it on an iPad, phone or Mac and tap once to enable sound. Over plain HTTP the browser can't keep the screen awake, so set that device's Auto-Lock to *Never*.

### Groups (one per stack of 20 cards)

Scan the cards a stack at a time. Before each new stack, press **Next group ▸** on `/live` or on the review page. Every passcode first seen after that belongs to the new group; seeing a card again doesn't move it.

* `/live` shows **Group N · X / 20**. A rising chime plays when the stack is complete, and a low double buzz when it goes over 20.
* The review page lists every group:
  * **green** means exactly 20;
  * **red, "N extra"**, means misreads to delete;
  * **amber, "N missing"**, means cards that weren't scanned.

  Click a group to show only its passcodes. The viewer's ←/→ then steps through just that group.
* Pressing Next group on a group that is still empty does nothing, so a double click can't create empty groups. When the database is emptied, numbering starts again at group 1.
* The stack size is `RBB_GROUP_SIZE` (default 20). The CSV export includes each passcode's group.

### AI check (run it after every card is scanned)

The server can ask an OpenAI vision model to re-read the passcodes' label photos. Nothing is sent until you start it. Start the server one of two ways:

```sh
RBB_AI_READER=codex ./run_server.sh        # through the Codex CLI, on the ChatGPT plan `codex login` uses
OPENAI_API_KEY=sk-... ./run_server.sh      # through the API, billed to the key
```

* **Codex:** each matrix is one read-only `codex exec` run, about 20 s, using the model in `~/.codex/config.toml`.
* **API:** the model is gpt-6.1-sol.
* **Either way,** `RBB_AI_MODEL` picks a different model.

Then, on the review page, press **AI check low-confidence**: this checks the passcodes flagged for review or with characters the scanner was unsure of. Press **AI check all** to check everything else as well. The same from a terminal:

```sh
curl -X POST 'http://<tailscale-ip>:8787/api/ai-check?scope=low_confidence'
curl -X POST 'http://<tailscale-ip>:8787/api/ai-check?scope=all'
```

* **Passcode matrix:** the label photos go to the model as a numbered matrix, six per request with three requests at a time. The model returns one reading per numbered cell. An answer that skips or repeats a cell fails that matrix, and its rows are marked failed so the next run retries them.
* **Progress:** the header shows progress, plus counts of same, corrected, differs, unreadable and removed.
* **Changes:** each row shows what the AI did, and "Removed by the AI check" lists the rows it deleted, with their photos.

For each passcode, what happens depends on what the model reads:

* **Not a passcode** (sleeve or description text): the row is removed. Its label photo is kept in `GET /api/removed`.
* **Another card's code:** the row was a misread of that card, so its sightings merge into it.
* **The same code** under the look-alike rule: the row is marked confirmed and leaves the review list.
* **A close variant:** the row takes the model's code and is flagged for review, with the scanner's reading kept as a variant.
* **A far-off code**, probably a neighbouring card's label: the row is flagged for review and nothing else changes.
* **Unreadable:** the row is flagged for review.

Verified rows are never touched. `POST /api/passcodes/{id}/ai-check` re-checks one row, for example after rotating its photo.

## Install the iPhone app

```sh
cd ios
xcodegen generate                 # regenerates RBBScan.xcodeproj from project.yml
open RBBScan.xcodeproj            # select your iPhone, then Run
```

* Signing: put your Apple developer team and a bundle ID prefix of your own in `ios/Config/Local.xcconfig` (git-ignored), then run `xcodegen generate` again:
  ```
  DEVELOPMENT_TEAM = ABCDE12345
  RBB_BUNDLE_ID_PREFIX = com.yourname
  ```
  Without it the app is `com.example.rbbscan` with no team, which builds for the simulator but can't be signed for a phone.
* On first launch the app asks for the server address (⚙︎ Server), for example `http://<tailscale-ip>:8787`.
* The iPhone needs Developer Mode on (Settings › Privacy & Security), and Tailscale must be running on it.
* The server address can be changed later in the same place, with a *Test connection* button.
* Scans are saved on the phone before they upload, so a Tailscale drop or an app restart loses nothing. The "N saved/uploading" badge clears once the Mac has them.
* Command-line builds need an unlocked login keychain, or codesign fails with `errSecInternalComponent`:
  ```sh
  security unlock-keychain ~/Library/Keychains/login.keychain-db
  xcodebuild -project ios/RBBScan.xcodeproj -scheme RBBScan -destination 'generic/platform=iOS' -allowProvisioningUpdates build
  ```

## Tests

The test suites, their fixtures and the sample recording contain real passcodes, so they are not in this repository; they live only on the machine that scanned the cards. With them in place:

Swift build products must live outside `~/Documents`, because codesign rejects the extended attributes that files there carry.

```sh
B=~/Library/Caches/RBBScan
(cd PasscodeCore && swift test --scratch-path $B/PasscodeCore-build)            # recognition core
(cd server && uv run pytest)                                                     # server API, live state, AI check
OPENAI_API_KEY=sk-... uv run --directory server pytest tests/test_ai.py -k openai   # one real matrix of fixtures/labels
RBB_TEST_CODEX=1 uv run --directory server pytest tests/test_codex.py -k real      # the same through Codex
xcodebuild -project ios/RBBScan.xcodeproj -scheme RBBScan \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath $B/ios-derived test   # app logic

# Regression against the sample recording (exit 1 on any missing/extra code):
(cd tools/videoscan && swift build -c release --scratch-path $B/videoscan-build)
$B/videoscan-build/release/videoscan IMG_1101.MOV --expect fixtures/img_1101_expected.txt   # your recording + its codes, one per line
$B/videoscan-build/release/videoscan IMG_1101.MOV --rotate 90 --dump /tmp/crops    # cards lying sideways
# Same, posing as the iPhone against a running server:
$B/videoscan-build/release/videoscan IMG_1101.MOV --post http://<tailscale-ip>:8787
```

## Layout

| Path | What |
|---|---|
| `PasscodeCore/` | Swift package shared by the app and `videoscan`: passcode rules, OCR recogniser, card-text and label filters, multi-frame tracker, near-match registry, JPEG snapshots, HTTP client |
| `ios/` | SwiftUI app: camera, upload queue, beeps, heartbeat (XcodeGen `project.yml`, signing in `Config/`) |
| `server/` | FastAPI app (`rbbscan/`), pages (`static/`), pytest suite |
| `tools/videoscan/` | Replays a video through the app's recognition pipeline |

## License

MIT, see [LICENSE](LICENSE). Not affiliated with or endorsed by Niantic; Ingress is a trademark of Niantic, Inc.
