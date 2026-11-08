# Vision worker: step-by-step setup

This guide takes the team laptop from nothing installed to processed matches showing on the
website. [README.md](README.md) explains how the worker works. This file is the hands-on version,
with a check after each step and fixes for common problems.

Plan on about an hour for Parts 1 to 4. That includes a few gigabytes of downloads.
Training the bumper model in Part 7 is a separate, longer job.

All commands are for **PowerShell** on Windows. Open it from the Start menu, or use the terminal
in VS Code. Lines starting with `#` are notes and don't need to be typed.

---

## Part 1: Install the tools (once per laptop)

### 1.1 Check the NVIDIA driver

```
nvidia-smi
```

**Expect:** a table naming the *NVIDIA GeForce RTX 4070 Laptop GPU* with a driver version. A
"CUDA Version" of 12.4 or higher is needed.

**If it's not found or the version is older:** install the latest Game Ready or Studio driver
from nvidia.com, or through the NVIDIA app. Then restart and check again.

### 1.2 Install Python 3.11

The worker is tested on Python 3.11. Newer versions may not have matching PyTorch builds yet.

1. Download **Python 3.11** (64-bit Windows installer) from python.org.
2. On the first screen of the installer, tick **Add python.exe to PATH**. Then choose Install Now.
3. Close and reopen PowerShell, then check:
   ```
   py -3.11 --version
   ```
   **Expect:** `Python 3.11.x`.
4. Install Deno. The video downloader needs it to get full-quality YouTube video:
   ```
   winget install DenoLand.Deno
   ```
   Close and reopen PowerShell afterwards.

### 1.3 Get the code

If the website repo is already on the laptop, skip this. Otherwise install Git from git-scm.com,
then run:

```
cd $HOME\Documents
git clone https://github.com/1307Robosaints/1307Robosaints.github.io.git
```

Everything else in this guide runs from the repo's `vision` folder:

```
cd "$HOME\Documents\1307Robosaints.github.io\vision"
```

Change the path if the repo lives somewhere else.

---

## Part 2: Make the Python environment (once per laptop)

The worker gets its own virtual environment, a private copy of Python in `vision\.venv`. Its
packages can't clash with anything else on the laptop. Git ignores the folder.

### 2.1 Create and turn on the environment

Make sure you're in the `vision` folder first (step 1.3). Run `ls` and check that you see
`requirements.txt` and `run.py`.

```
py -3.11 -m venv .venv
.venv\Scripts\Activate.ps1
```

**Expect:** the prompt now starts with `(.venv)`. You need that before every worker command.

**If PowerShell says running scripts is disabled:** allow scripts for your own account, once,
then try again:

```
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### 2.2 Install PyTorch with GPU support

Install PyTorch **first and separately**. The plain `pip install torch` gets a CPU-only build,
and the worker would then be far too slow.

```
python -m pip install --upgrade pip
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
```

This is about 2.5 GB. Check that it can see the GPU:

```
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

**Expect:** `True NVIDIA GeForce RTX 4070 Laptop GPU`.

**If it prints False or errors:** you probably have the CPU build. Remove it and install again
from the CUDA link above:

```
pip uninstall -y torch torchvision
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
```

If it's still False, recheck the driver in step 1.1.

### 2.3 Install the rest

```
pip install -r requirements.txt
```

This installs Ultralytics YOLO, EasyOCR, OpenCV, yt-dlp, NumPy and Requests.

**Check that PyTorch survived.** Some packages can replace the GPU build with the CPU build.
Run the check from 2.2 again. If it now prints False, repeat the fix in 2.2.

### 2.4 Download the text-reading models

EasyOCR downloads its reading models (about 100 MB) the first time it runs. Do that now, while
you have good internet, instead of at an event:

```
python -c "import easyocr; easyocr.Reader(['en'], gpu=True); print('OCR ready')"
```

**Expect:** some download progress, then `OCR ready`. The models are saved under
`$HOME\.EasyOCR` and aren't downloaded again.

### 2.5 Run the tests

```
python -m unittest
```

**Expect:** `Ran 15 tests` and `OK`. These cover the clock, score timeline, identity and stats
logic. They don't touch the GPU, video or database.

---

## Part 3: Connect to the database (once per laptop)

### 3.1 Make sure the database has the vision tables

The `vision_matches` and `vision_robots` tables come from section 8j of `SQL/rebuild_all.sql`.
If it hasn't been run since the vision update, a staff member runs it:

1. Open the Supabase dashboard for the 1307scout project.
2. Open the **SQL Editor** and paste in the whole of `SQL/rebuild_all.sql`.
3. Click **Run**. It's safe to run on the existing database. The check at the end should list
   `vision_matches`, `vision_robots` and `match_flag_reviews`.

### 3.2 Collect the keys

You need three values:

| Value | Where to find it |
|---|---|
| Supabase URL | Supabase dashboard, **Project Settings > API** (or **Data API**). It looks like `https://abcd1234.supabase.co`. If the dashboard shows it ending in `/rest/v1/`, that works too. |
| Service role key | Same area, under **API Keys**. Use the `service_role` secret key, not the `anon` public key. You may need to click **Reveal**. |
| TBA read key | Sign in at thebluealliance.com, open **Account**, and add a **Read API Key**. The key `official-sync` uses works too. |

> **The service role key is a master key.** It skips every row-level security rule, so anyone
> with it can read, change or delete all team data. Keep it only in `vision\.env` on this laptop.
> Never paste it into the website code, a chat, a screenshot or a commit. If it leaks, rotate it
> in the Supabase dashboard and update `.env`.

### 3.3 Create the .env file

```
Copy-Item .env.example .env
notepad .env
```

Fill in the three lines, with no quotes or spaces around the `=`:

```
SUPABASE_URL=https://abcd1234.supabase.co
SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOi...
TBA_API_KEY=AbCdEf123...
```

Save and close. `.env` is in `.gitignore`. Run `git status` and confirm it isn't listed, as a
check.

### 3.4 Test the connection

Pick an event that has already synced in the Staff Portal, and use its TBA key:

```
python run.py keys --event 2026nhrr
```

`2026nhrr` is an example. Use the TBA key of an event that has played matches. If it says
`No event has TBA key ...`, that event isn't linked yet. Pick another, or link it in the Staff Portal.

**Expect:** a block of JSON, the red alliance's score breakdown for `qm1`.

| Message | Meaning |
|---|---|
| `SUPABASE_URL isn't set` | `.env` is missing, misnamed (for example `.env.txt`), or a line is blank. |
| `No event has TBA key ...` | The event isn't linked yet. See step 5.1. |
| `qm1 hasn't synced` | The event is linked but no results have synced. Sync it in the Staff Portal, or try `--match qm2`. |
| An HTTP 401 error | The service role key is wrong or has a typo. |

---

## Part 4: Check the 2026 game settings (once per season)

The worker's game rules live in `rsvision\games\2026.json`. Two parts need checking by hand.

### 4.1 Score field names

In the JSON from step 3.4, look for these keys:

- `autoTowerRobot1`, `autoTowerRobot2`, `autoTowerRobot3`, with values like `None` or `Level1`
- `endGameTowerRobot1` to `endGameTowerRobot3`, with `None`, `Level1`, `Level2` or `Level3`
- `foulPoints`, a number

The key names show up even if nobody climbed, but to see the level spellings you need a match
where robots did. `keys` shows qm1's red alliance unless you add `--match`, and climbs are rare,
so `None` everywhere is normal. To see real values, try
`python run.py keys --event 2026arc --match qm13` (an endgame `Level2`) or `--match qm14`
(an auto `Level1`).

If a name differs, change it under `breakdown_keys` in the game file. Do the same under
`tower_points` if the level values are spelled differently. The Match Flags page uses the same
names. Tell whoever maintains the website if they changed, so `flags.html` gets updated too.

### 4.2 Field sizes

The field length, width and alliance-zone depth in the game file are approximate. Check them
against the 2026 field drawings in the game manual, under Arena:

| Setting | Means | Current value |
|---|---|---|
| `length_in` | Driver station wall to driver station wall, in inches | 651.2 |
| `width_in` | Side wall to side wall, in inches | 317.7 |
| `alliance_zone_depth_in` | Alliance wall to the alliance zone line | 158.6 |

Edit the numbers if they're off. Then delete the `_verify` line, so the next person knows
they were checked. Zone times and the "left starting zone" check depend on these.

---

## Part 5: First event, start to finish

Run through this once with a past event to learn the steps. After that, Part 6 is the short
version.

Turn the environment on in each new PowerShell window:

```
cd "$HOME\Documents\1307Robosaints.github.io\vision"
.venv\Scripts\Activate.ps1
```

Keep the laptop **plugged in**. On battery, the laptop GPU runs much slower.

### 5.1 Link the event

In the Staff Portal, open the event and fill in **TBA event key** (for example `2026nhrr`).
Sync it, and check that results show on Matches or the Team Database.

### 5.2 Download the videos

```
python run.py download --event 2026nhrr
```

This downloads every played qualification match with a video on TBA, to
`work\videos\2026nhrr\qm1.mp4` and so on. Expect around 50 to 150 MB per match at 1080p.
Matches without a video yet say so and are skipped. Run the command again later to fetch them.

To fetch only some: `--matches qm1,qm2,qm3`.

**Your own recording works too.** Cut it to one match, starting a little before auto, and save it
as `work\videos\<event>\<match>.mp4`. The worker uses a file that's already there and doesn't
download one.

### 5.3 Find a good frame for calibration

Open a downloaded video in any player. Find a moment where:

- the main **wide shot** of the whole field is showing, not a close-up or replay
- the **scoreboard overlay** with both scores and the clock is visible
- as many field **corners and floor lines** as possible are visible

Note how many seconds into the video it is. Late teleop or endgame works best: the scores are three
digits by then, so you can size the score boxes to fit (step 5.4).

### 5.4 Calibrate

```
python run.py calibrate --event 2026nhrr --video work\videos\2026nhrr\qm1.mp4 --at 60
```

Use your number of seconds for `--at`. Windows open one after another.

**Scoreboard boxes (3 windows).** For the red score, then the blue score, then the clock:

1. Drag a box around **the digits**, with a little margin. Leave out team numbers and labels: any
   digit inside the box is read as part of the score. The box stays fixed for the whole event, so
   make it wide enough for a **three-digit score** and for the clock at `2:20`. This is easiest on
   a late-match frame where the scores are already in the hundreds.
2. Press **Enter** or **Space** to accept. Press **c** to cancel the whole calibration.

Each accepted box stays drawn in yellow.

**Field landmarks (up to 10 windows).** Each window title names one point, such as
*Corner: red wall, scoring-table side*:

1. Click exactly where that point meets the **floor**. Use the carpet corner or the tape line.
   Don't click the top of a wall, the HUB or a robot.
2. Press **s** to skip a point you can't see.
3. Press **q** to finish early once you've clicked at least 4.

"Scoring-table side" is the long side of the field nearest the scoring table. The red wall is
the red alliance's driver station wall. Clicked points turn green.

For the best result, click **at least 4 points spread across the field**, not all in a line.
For example, use both corners at one end plus both ends of the far zone line. More points help.

**The check.** A final window draws, in magenta, the field outline, both zone lines and the center
line, worked out from your clicks:

- Press **y** if the lines sit on the real ones, within about a robot's width.
- Press any other key to throw it away. Then run calibrate again with more or better-placed
  points.

**Expect:** `Saved work\calib\2026nhrr.json`. A copy of the frame is saved next to it, and the
worker uses it to recognize the wide shot.

Calibrate again if the broadcast's camera or overlay changes partway through the event. Also
calibrate again at every new event, since each venue's camera is different.

### 5.5 Test one match without uploading

```
python run.py run --event 2026nhrr --matches qm1 --no-upload --debug
```

Until there's a bumper model (Part 7), this only reads the scoreboard. **Expect:**

```
qm1:
  partial: 0 robots - Scoreboard only: no bumper model yet.
Finished: 1 processed, 0 failed.
```

Open `work\debug\2026nhrr_qm1.json`. The console also prints the read and official final
scores. In the file's `match` section, check:

- `final_red` and `final_blue` match the official score, or the official score minus that
  alliance's foul points (the overlay usually adds fouls only after the match)
- `matches_official` is `true`. It's `null` when the video ends before the match does: many
  broadcast videos are cut a few seconds early, so the last points are missing. That's fine.
- `score_timeline` climbs through the match and never goes down

| Problem | Likely fix |
|---|---|
| "Couldn't read the match clock" | The clock box is off. Calibrate again with a tighter box around just the clock digits. |
| Final scores are wrong or missing | Same fix for the score boxes. Also check the video is 720p or better. |
| `matches_official` is false but the scores look right | The official result may have changed after a review. Sync the event and run again. |
| Scores read 0 or stop changing while the clock runs | Watch the video at that point. If the broadcast scoreboard itself is wrong, the read is right and the flag is correct: that match's vision data can't be trusted. |

### 5.6 Process the event

```
python run.py run --event 2026nhrr
```

This processes every played qualification match and uploads the results. Re-running a match
replaces its old rows, so it's always safe to run again. One bad video doesn't stop the rest.
The summary line counts how many failed.

Robots whose bumper numbers read clearly teach the worker how they look. When the run finishes,
it goes back over the matches with unidentified robots and matches them by look. It prints
lines such as `qm4: 3 -> 5 robots`.

Later in the event, after more matches have been run, this redoes who's who for every match
with everything learned since. It doesn't need the videos and takes seconds:

```
python run.py identify --event 2026nhrr
```

### 5.7 Check the website

- **Match Flags** shows a *Vision scoreboard read is off* flag for any match whose read final
  score didn't match the official one.
- With a bumper model, **Team Database** shows a Vision section for each team. Match Flags then
  counts vision-covered robots in its coverage tiles.

---

## Part 6: Each competition (short version)

```
cd "$HOME\Documents\1307Robosaints.github.io\vision"
.venv\Scripts\Activate.ps1
# 1. Link the event in the Staff Portal and sync it.
python run.py download --event <tba key>
python run.py calibrate --event <tba key> --video work\videos\<tba key>\qm1.mp4 --at 60
python run.py run --event <tba key>
```

During the event, run `download` and then `run` again every so often. TBA usually posts match
videos within a few minutes to an hour. To avoid redoing finished matches, name the new ones,
for example `--matches qm31,qm32,qm33`. Then run `python run.py identify --event <tba key>`,
so earlier matches pick up the robot looks learned from the new ones.

**At the start of each season:** robot looks are kept per season in
`work\appearance\<season>.npz`, so the first event of a new season starts fresh on its own.
Check what's been learned with `python run.py appearances --season 2027`. Old seasons' files,
and old `work\tracks\` folders, can be deleted. After retraining the bumper model mid-season,
run the event again from video, then `python run.py appearances --season <year> --rebuild`.

Before leaving for an event:

- Bring the charger.
- Test the laptop's internet at the venue, or on a phone hotspot, early. Each video is a
  download.
- If the venue's internet is poor, download videos in the evening at the hotel and process them
  then.

---

## Part 7: Train the bumper model (Phase 2, once, improved over time)

Robot tracking needs a model that finds red and blue bumpers in video. Bumpers look the same
every season, so one good model keeps working.

### 7.1 Collect frames

```
python run.py frames --video work\videos\2026nhrr\qm1.mp4 --every 2
```

This saves one frame every 2 seconds to `work\dataset\images`, named after the event and match
(for example `2026nhrr_qm1_00120.jpg`). Do this for **8 to 15 matches from at least 3 different
events**. Different venues, lighting and camera angles make the model hold up anywhere.

**With many events downloaded**, this takes 2 random matches from every event folder, one frame
every 5 seconds:

```
Get-ChildItem work\videos -Directory | ForEach-Object {
  Get-ChildItem $_.FullName -Filter *.mp4 | Get-Random -Count 2 | ForEach-Object {
    python run.py frames --video $_.FullName --every 5
  }
}
```

Don't extract every match. A full district is over a thousand videos, far more frames than
anyone can label, and matches from the same event look alike.

Then go through the folder and delete close-ups, replays, crowd shots and frames with no
robots. Aim for **300 to 500** good wide-shot frames.

### 7.2 Draft the labels automatically

The laptop can draw a first pass of boxes, so people fix boxes instead of drawing every one.
It uses Grounding DINO, a model that finds objects from a text description, with no training.

Install it once, with the environment on:

```
pip install "transformers>=4.45,<5"
```

Then:

```
python run.py prelabel --preview work\prelabel-preview
```

- The first run downloads the model, about 1 GB. After that it takes about a second a frame.
- It writes a label file for each frame to `work\dataset\labels`, plus `work\dataset\data.yaml`.
- Frames where it found no robots get no label file and are listed in
  `work\dataset_no_robots.txt`. Most are results screens, title cards or close-ups. Delete them
  from `work\dataset\images`.
- `--preview` saves copies with the boxes drawn, so you can skim them in Explorer first.
- Label files that already exist are kept, so hand fixes aren't lost. Add `--overwrite` to
  replace them.

**What to expect:** it boxes roughly half the robots, and almost every box it draws is a real
robot with the right color. Expect to add the boxes it missed, and to delete the odd box on a
field structure, ball rack or person. It does worst on side-angle shots and picture-in-picture
views. `--conf 0.1` finds more robots but also more junk.

**Once you have a first model** (7.4 and 7.5), use it to draft the next batch instead. It's
much better than Grounding DINO at this:

```
python run.py prelabel --model models\bumpers.pt --overwrite
```

Only use `--overwrite` on new frames that haven't been reviewed yet, or run it on a separate
folder with `--images`.

### 7.3 Review them

Roboflow is the easiest option, and its free plan is enough. CVAT also works.

1. Make a free Roboflow account and create an **Object Detection** project.
2. Create two classes, spelled exactly `red_bumper` and `blue_bumper`.
3. Upload the **whole `work\dataset` folder** (images, labels and `data.yaml` together).
   Roboflow reads the label files and shows the drafted boxes. Check that the boxes appear
   on a few frames before going on.
4. Go through each frame. **Each robot gets one box around its bumpers**: the whole ring of
   bumper fabric you can see, including the number, not mechanisms sticking out past it.
   Label it red or blue.
   - Fix boxes that are too loose or tight, delete wrong ones, and add missed robots.
   - Box partly hidden robots too, as long as you can tell it's a robot.
   - Don't box one robot twice (once per bumper side). The tracker treats two boxes seen at
     the same moment as two different robots.
5. Generate a dataset version with the default **train/valid split**, around 80/20. Export it in
   **YOLOv8** or **YOLO11** format and download the zip.

Roboflow Universe also has public FRC bumper datasets. Most label each bumper side separately,
which doesn't match the one-box-per-robot rule above, so check before adding one.

### 7.4 Train

Unzip the export somewhere outside the repo, for example `$HOME\Documents\bumpers-data`. Then:

```
python run.py train --data $HOME\Documents\bumpers-data\data.yaml
```

- The first run downloads the `yolo11s.pt` starting model, about 20 MB.
- Expect roughly an hour or more for 100 passes over 400 frames. Keep the laptop plugged in
  and well ventilated.
- **If it stops with "CUDA out of memory":** close other GPU apps, then add `--batch 4`.

**If it can't find the images:** open `data.yaml` and make the `train:` and `val:` paths
correct, or give a `path:` line with the full folder.

When it finishes, check `work\train\bumpers\results.png`. The `mAP50` curve should level off
above about 0.8. Lower than that usually means more or better-labeled frames are needed.

### 7.5 Install the model

```
Copy-Item work\train\bumpers\weights\best.pt models\bumpers.pt
```

`models\*.pt` is in `.gitignore`. Back the model up somewhere safe, such as the team's shared
drive, since it isn't in the repo.

### 7.6 Test the full pipeline

```
python run.py run --event 2026nhrr --matches qm1 --no-upload --debug
```

**Expect:** `ok: 6 robots`, or `partial` with a note such as "Identified 5 of 6 robots".

Then check the debug JSON against a match you've watched:

- Each team number appears with the right alliance.
- `confidence` is mostly above 0.5.
- `auto_left_zone` matches what you saw.
- Robots that sat dead show a large `longest_still_s`.

If identities are often wrong or missing, label more frames where the bumper numbers are
readable. Once a few matches look right, run the whole event without `--no-upload`. After the
next event, check how often Match Flags shows *Vision disagrees*. It's the best measure of how
the model does in real use.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `(.venv)` is missing from the prompt | Run `.venv\Scripts\Activate.ps1` from the `vision` folder. |
| `Could not open requirements file` | You're not in the `vision` folder. `cd` into it (step 1.3) and run the command again. |
| `ModuleNotFoundError` for cv2, easyocr or ultralytics | The environment isn't on, or step 2.3 didn't finish. Turn it on and run `pip install -r requirements.txt`. |
| `No supported JavaScript runtime could be found` while downloading | Deno isn't installed (step 1.2). Videos may still download, but YouTube can serve lower quality or fail without it. |
| Everything is very slow | `torch.cuda.is_available()` is False (see 2.2), or the laptop is on battery. |
| `No calibration for ...` | Run step 5.4 for that event. |
| `Missing reference frame ...` | The `work` folder was moved or deleted. Calibrate again. |
| Download fails with an HTTP or sign-in error | YouTube changes often. Update yt-dlp with `pip install -U yt-dlp` and try again. |
| `no video: none on TBA yet` | TBA has no video linked yet. Wait, or supply your own recording (step 5.2). |
| Many matches flagged *Vision scoreboard read is off* | The overlay may have moved, or the stream switched layouts. Calibrate again from a later match. |
| `No game file for 2027` | Copy `rsvision\games\2026.json` to `2027.json` and update it for the new game. |

## Files the worker keeps on the laptop

None of these are committed. Back up `models` and `work\calib` if you want to keep them.

| Path | Holds |
|---|---|
| `.env` | The keys. Secret. |
| `.venv\` | The Python environment. It can be deleted and rebuilt with Part 2. |
| `models\bumpers.pt` | The trained bumper model. |
| `work\videos\` | Downloaded match videos. Safe to delete after processing. |
| `work\calib\` | One calibration and reference frame per event. |
| `work\dataset\`, `work\train\` | Training frames and training runs. |
| `work\debug\` | Debug output from `--debug` runs. |
| `work\tracks\` | Each processed match's robot tracks, so `identify` can redo who's who without video. |
| `work\appearance\` | Each team's robot looks, one file per season. |
