# 1307scout vision worker

Reads FRC match video and saves estimates for each robot to Supabase. The Team Database shows
them in a Vision section, and the Match Flags page uses them to tell which unscouted matches are
covered and where scouts and vision disagree. Vision numbers are estimates. No rating uses them.

The worker runs on a team laptop (built for the laptop RTX 4070, 8 GB) and never on the website.

## How it works

1. **Scoreboard (Phase 1).** About twice a second, the worker reads the red score, blue score
   and clock off the stream overlay. The countdown gives the exact start of auto and teleop.
   The scores become a clean second-by-second timeline that never goes down. The final score
   is checked against the official one. This needs no trained model.
2. **Robots (Phase 2).** At 10 frames a second, frames that match the event's calibrated wide
   shot go through a YOLO bumper detector with ByteTrack. Close-ups and replays are skipped.
   Each bumper's floor point is mapped onto the field. Bumper numbers are read with EasyOCR
   about once a second per robot. Only the three teams on that alliance are possible, so a
   partial read still picks the right one.
3. **Who's who.** Broken tracks are joined when a robot could have driven from one to the
   next. Each joined track takes the team its number reads point to. A track never read is
   assigned only when exactly one team of that color is left.
4. **Numbers.** These come from the field positions. Every rise in an alliance's score is split
   between its robots, weighted by whether each was in its own alliance zone just before. The
   split is then scaled to the official FUEL points: the score minus per-robot TOWER points and
   foul points. Only the split comes from video.

What ends up in `vision_robots.data` (labels in `js/vision.js`, explained on `ratings.html`):

| Key | Meaning |
|---|---|
| `fuel_est`, `fuel_share` | Estimated FUEL scored, and its share of the alliance's |
| `auto_left_zone` | Crossed its alliance-zone line during auto |
| `auto_distance_ft`, `distance_ft` | Distance driven in auto, and in the whole match |
| `own_zone_s`, `neutral_zone_s`, `opp_zone_s` | Seconds tracked in each zone |
| `still_s`, `longest_still_s` | Seconds stopped in teleop before endgame, total and longest |
| `contacts` | Separate close contacts with an opponent |
| `visible_share`, `id_share` | Share of the match tracked, and share identified by number |

`confidence` is the share tracked, discounted by up to half when the robot was never read by
number. The website treats anything under 0.5 as low confidence.

## Setup (once)

For a step-by-step version with a check after each step and fixes for common problems, see
[SETUP.md](SETUP.md).

1. Install Python 3.11 and the NVIDIA driver (already on the team laptop).
2. From this folder, make a virtual environment and install PyTorch with CUDA, then the rest:
   ```
   python -m venv .venv
   .venv\Scripts\activate
   pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
   pip install -r requirements.txt
   ```
   Check the GPU is used: `python -c "import torch; print(torch.cuda.is_available())"` should print True.
3. Copy `.env.example` to `.env` and fill in the Supabase URL, the service role key and the
   TBA key. **The service role key skips all row-level security.** Keep it on this laptop.
4. Run `SQL/rebuild_all.sql` so the `vision_matches` and `vision_robots` tables exist.
5. Confirm the 2026 score field names match `rsvision/games/2026.json`:
   `python run.py keys --event 2026nhrr`. The per-robot TOWER keys and `foulPoints` should be there.
   Also check the field sizes in that file against the 2026 field drawings, as noted at its top.

## Each event

1. Link the event to its TBA key in the Staff Portal and let it sync.
2. Download the match videos TBA lists: `python run.py download --event 2026nhrr`.
3. Calibrate once per event, from a video with a clear wide shot:
   ```
   python run.py calibrate --event 2026nhrr --video work\videos\2026nhrr\qm1.mp4 --at 60
   ```
   Draw boxes around the red score, blue score and clock. Then click the floor landmarks it
   names: field corners, the center line and the zone lines. Skip any you can't see, with at
   least 4. Press `y` if the magenta outline sits on the field. If the broadcast changes its
   wide shot partway through an event, calibrate again.
4. Process: `python run.py run --event 2026nhrr` for every played qualification match, or
   `--matches qm12,qm13` for some. Add `--scoreboard-only` for Phase 1 alone, `--no-upload` to
   test, and `--debug` to keep every read in `work\debug\`.

Re-running a match replaces its saved rows.

## Training the bumper model (Phase 2)

There's no model in the repo. Until there is, `run` reads only the scoreboard.

1. Save frames to label: `python run.py frames --video work\videos\2026nhrr\qm1.mp4 --every 2`.
   Take them from several events and matches. Leave out close-ups.
2. Label them in Roboflow or CVAT with two box classes, `red_bumper` and `blue_bumper`. Draw
   one box per visible bumper side. Public FRC bumper datasets on Roboflow Universe can give
   a head start. 300 to 500 labeled frames is a reasonable first goal.
3. Export in YOLO format, then train:
   `python run.py train --data path\to\data.yaml`. Batch 6 at 1280 px fits in 8 GB.
4. Copy `work\train\bumpers\weights\best.pt` to `models\bumpers.pt`.

Bumpers look the same every season, so the model carries over. The game-specific parts are
the field zones, scoring rules and timing in `rsvision/games/<season>.json`. Copy the file to
the new season's number each January and update it.

## Checking accuracy

Before trusting a new model or event, compare a few matches by hand:

- **Scoreboard read.** The Match Flags page flags any match where the read final score is off
  from the official score, with or without foul points. Matches whose video ends before the
  buzzer aren't checked (`matches_official` is null).
- **Who's who.** Run with `--debug` and check the identities in the JSON for a match you watched.
- **Agreement with scouts.** Match Flags lists every match where vision and a scout disagree on
  FUEL, leaving the starting zone, or a stopped robot. A model that's often wrong shows up there.

## Tests

`python -m unittest` from this folder runs the tests for the timeline, identity and metrics
logic. They need only numpy.

## Limits

- Live streams aren't read yet. Use the match videos TBA lists, or a recording cut to one match.
- The field mapping assumes a flat floor. A robot up on the TOWER maps a little off.
- Robots blocking each other, or long close-ups, lower the share tracked and the confidence.
- Foul points the scoreboard adds can be credited as FUEL in the split, though the official
  total is corrected for them.
- Videos are for the team's own scouting. Don't republish them.
